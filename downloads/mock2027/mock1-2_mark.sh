#!/bin/bash
# 2027 지방대회 대비 모의고사 1회 제2과제 채점 스크립트
# 실행 위치: 서울 리전 CloudShell
# 사용법: bash mock1-2_mark.sh <비번호>
# 주의: 3-6 항목은 stop-dev-instances를 실제로 실행해 dev 인스턴스를 중지합니다.
NO="$1"
if [ -z "$NO" ]; then
  echo "사용법: bash mock1-2_mark.sh <비번호>"
  exit 1
fi
export AWS_DEFAULT_REGION=ap-northeast-2
export AWS_PAGER=""
TK="--region ap-northeast-1"

TOTAL=0
MAX=0
res() {
  local id="$1" pt="$2" desc="$3" ok="$4" shown="$5"
  MAX=$(awk -v a="$MAX" -v b="$pt" 'BEGIN{print a+b}')
  local mark="X"
  if [ "$ok" = "1" ]; then
    TOTAL=$(awk -v a="$TOTAL" -v b="$pt" 'BEGIN{print a+b}')
    mark="O"
  fi
  printf "[%s] %-4s (%s점) %s\n" "$mark" "$id" "$pt" "$desc"
  printf "       확인값: %s\n" "$(printf '%s' "$shown" | tr '\n\t' '  ' | tr -s ' ' | cut -c1-160)"
}
q() { aws "$@" --output text 2>/dev/null; }
is() { [ "$1" = "$2" ] && echo 1 || echo 0; }
has() { printf '%s' "$1" | grep -Eq -- "$2" && echo 1 || echo 0; }
has_all() { local s="$1"; shift; for w in "$@"; do printf '%s' "$s" | grep -Fq -- "$w" || { echo 0; return; }; done; echo 1; }
norm() { printf '%s' "$1" | tr '\t\n' '  ' | tr -s ' ' | sed 's/^ //;s/ $//'; }
ACCT=$(q sts get-caller-identity --query Account)

echo "=================================================="
echo " 2027 지방 모의고사 1회 제2과제 채점 결과"
echo " 계정: $ACCT / 비번호: $NO"
echo " 시각: $(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S KST')"
echo "=================================================="

echo "## 1. Static website with CDN"
B="cafe-web-$NO"
A=$(q s3api get-public-access-block --bucket "$B" --query "PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]")
res 1-1 1.5 "퍼블릭 액세스 차단 4개" "$(is "$(norm "$A")" "True True True True")" "$A"
C=$(curl -s -m 10 -o /dev/null -w "%{http_code}" "https://$B.s3.ap-northeast-2.amazonaws.com/index.html")
res 1-2 1.5 "S3 직접 접근 → 403" "$(is "$C" 403)" "$C"
CF=$(q cloudfront list-distributions --query "DistributionList.Items[?contains(Origins.Items[0].DomainName,'$B.s3')].Id" | awk '{print $1}')
CFD=$(q cloudfront get-distribution --id "${CF:-none}" --query "Distribution.DomainName")
A=$(q cloudfront get-distribution-config --id "${CF:-none}" --query "DistributionConfig.[Origins.Items[0].OriginAccessControlId,DefaultRootObject,DefaultCacheBehavior.ViewerProtocolPolicy,PriceClass]")
set -- $A
OAC="$1"; ROOT="$2"; VPP="$3"; PC="$4"
OK=0; [ -n "$OAC" ] && [ "$OAC" != "None" ] && [ "$(norm "$A" | wc -w)" = 4 ] && OK=1
res 1-3 2 "OAC 사용" "$OK" "dist=$CF oac=$OAC"
OK=0; [ "$ROOT" = index.html ] && [ "$VPP" = redirect-to-https ] && OK=1
res 1-4 1.5 "Root object index.html, HTTPS Redirect" "$OK" "$ROOT $VPP"
R=$(curl -s -m 10 "https://$CFD/")
res 1-5 2 "CloudFront 페이지 출력" "$(has "$R" 'SkillsCafe Menu v1')" "$R"
R=$(curl -s -m 10 -w " HTTP%{http_code}" "https://$CFD/nothing-$RANDOM")
OK=0; [ "$(has "$R" 'Oops')" = 1 ] && [ "$(has "$R" 'HTTP404$')" = 1 ] && OK=1
res 1-6 1.5 "없는 경로 → error.html, 404" "$OK" "$R"
res 1-7 1 "Price class All" "$(is "$PC" PriceClass_All)" "$PC"
A=$(q cloudfront get-distribution-config --id "${CF:-none}" --query "DistributionConfig.WebACLId")
res 1-8 1.5 "WAF cafe-web-acl 연결" "$(has "$A" '/cafe-web-acl/')" "$A"
ACL=$(q wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 --query "WebACLs[?Name=='cafe-web-acl'].Id")
A=$(q wafv2 get-web-acl --scope CLOUDFRONT --region us-east-1 --name cafe-web-acl --id "${ACL:-none}" --query "WebACL.Rules[].[Name,Statement.RateBasedStatement.Limit,Statement.ManagedRuleGroupStatement.Name]")
OK=0; [ "$(has "$A" 'cafe-rate-limit[[:space:]]+100')" = 1 ] && [ "$(has_all "$A" AWSManagedRulesCommonRuleSet)" = 1 ] && OK=1
res 1-9 1.5 "Rate 100 + CommonRuleSet" "$OK" "$A"

echo "## 2. Serverless workflow"
A=$(q dynamodb describe-table --table-name cafe-order-status --query "Table.KeySchema[].AttributeName")
res 2-1 1.5 "Table key order_id" "$(is "$A" order_id)" "$A"
A=$(q lambda get-function-configuration --function-name cafe-make-coffee --query Runtime)
res 2-2 1.5 "Lambda python3.12" "$(is "$A" python3.12)" "$A"
SM=$(q stepfunctions list-state-machines --query "stateMachines[?name=='cafe-order-flow'].stateMachineArn")
A=$(q stepfunctions describe-state-machine --state-machine-arn "${SM:-none}" --query "[type,loggingConfiguration.level]")
set -- $A
res 2-3 1.5 "Standard" "$(is "$1" STANDARD)" "$1"
res 2-4 1.5 "로그 ALL" "$(is "$2" ALL)" "$2"
A=$(q stepfunctions describe-state-machine --state-machine-arn "${SM:-none}" --query definition | grep -c 'arn:aws:states:::dynamodb:putItem')
res 2-5 2 "DynamoDB 서비스 통합 putItem" "$([ "${A:-0}" -ge 1 ] && echo 1 || echo 0)" "count=$A"
run_sfn() {
  local ex st
  ex=$(q stepfunctions start-execution --state-machine-arn "${SM:-none}" --input "$1" --query executionArn)
  for i in $(seq 1 15); do
    st=$(q stepfunctions describe-execution --execution-arn "${ex:-none}" --query status)
    [ "$st" != "RUNNING" ] && break
    sleep 2
  done
  q stepfunctions describe-execution --execution-arn "${ex:-none}" --query "[status,output]"
}
ID1="mark-$NO-$(date +%s)-1"; ID2="mark-$NO-$(date +%s)-2"
R=$(run_sfn "{\"order_id\":\"$ID1\",\"menu\":\"latte\",\"qty\":2}")
OK=0; [ "$(has "$R" '^SUCCEEDED')" = 1 ] && [ "$(printf '%s' "$R" | cut -f2 | jq -r '.status' 2>/dev/null)" = DONE ] && [ "$(printf '%s' "$R" | cut -f2 | jq -r '.order_id' 2>/dev/null)" = "$ID1" ] && OK=1
res 2-6 2 "정상 주문 → DONE" "$OK" "$R"
R=$(run_sfn "{\"order_id\":\"$ID2\",\"menu\":\"mocha\",\"qty\":30}")
OK=0; [ "$(has "$R" '^SUCCEEDED')" = 1 ] && [ "$(printf '%s' "$R" | cut -f2 | jq -r '.status' 2>/dev/null)" = REJECTED ] && [ "$(printf '%s' "$R" | cut -f2 | jq -r '.order_id' 2>/dev/null)" = "$ID2" ] && OK=1
res 2-7 2 "거절 주문 → REJECTED" "$OK" "$R"
A=$(q dynamodb get-item --table-name cafe-order-status --key "{\"order_id\":{\"S\":\"$ID2\"}}" --query "Item.status.S")
res 2-8 1 "DynamoDB 기록 REJECTED" "$(is "$A" REJECTED)" "$A"

echo "## 3. Event-driven automation (도쿄)"
A=$(q scheduler get-schedule --name stop-dev-schedule $TK --query "[ScheduleExpression,ScheduleExpressionTimezone,Target.Arn]")
OK=0; [ "$(has "$A" '^cron\(0 22 \* \* \? \*\)[[:space:]]+Asia/Seoul[[:space:]]+arn:aws:lambda:ap-northeast-1:[0-9]+:function:stop-dev-instances$')" = 1 ] && OK=1
res 3-1 2 "Scheduler 매일 22:00 Asia/Seoul" "$OK" "$A"
A=$(q events describe-rule --name ec2-stopped-rule $TK --query EventPattern)
OK=0; [ "$(has_all "$A" 'EC2 Instance State-change Notification' '"stopped"')" = 1 ] && ! printf '%s' "$A" | grep -q '"running"' && OK=1
res 3-2 2 "Rule 패턴 stopped" "$OK" "$A"
A=$(q events list-targets-by-rule --rule ec2-stopped-rule $TK --query "Targets[].Arn")
res 3-3 1 "Rule 대상 ec2-state-topic" "$(has "$A" ':ec2-state-topic$')" "$A"
A=$(q lambda get-function-configuration --function-name stop-dev-instances $TK --query Runtime)
res 3-4 1 "Lambda python3.12" "$(is "$A" python3.12)" "$A"
ROLE=$(q lambda get-function-configuration --function-name stop-dev-instances $TK --query Role | awk -F/ '{print $NF}')
DOCS=""
for p in $(q iam list-role-policies --role-name "${ROLE:-none}" --query PolicyNames); do
  DOCS="$DOCS $(aws iam get-role-policy --role-name "$ROLE" --policy-name "$p" --query PolicyDocument --output json 2>/dev/null)"
done
for arn in $(q iam list-attached-role-policies --role-name "${ROLE:-none}" --query "AttachedPolicies[].PolicyArn"); do
  v=$(q iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId)
  DOCS="$DOCS $(aws iam get-policy-version --policy-arn "$arn" --version-id "$v" --query PolicyVersion.Document --output json 2>/dev/null)"
done
OK=0; printf '%s' "$DOCS" | tr -d ' \n' | grep -Eq '"(ec2|aws):ResourceTag/Env":"dev"' && OK=1
res 3-5 2 "StopInstances 태그 조건 Env=dev" "$OK" "role=$ROLE"
ids() { q ec2 describe-instances $TK --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].InstanceId"; }
DEV=$(ids dev-web-1,dev-web-2); PROD=$(ids prod-web-1)
aws lambda invoke --function-name stop-dev-instances $TK /tmp/mock1_stop.json >/dev/null 2>&1
INV=$(cat /tmp/mock1_stop.json 2>/dev/null)
sleep 45
S=$(q ec2 describe-instances $TK --filters Name=tag:Name,Values=dev-web-1,dev-web-2,prod-web-1 --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value,State.Name]" | sort)
D=$(printf '%s\n' "$S" | grep -E '^dev-web-[12][[:space:]]+(stopping|stopped)$' | wc -l)
P=$(printf '%s\n' "$S" | grep -Ec '^prod-web-1[[:space:]]+running$')
OK=0; [ "$D" = 2 ] && [ "$P" = 1 ] && [ -n "$DEV" ] && [ -n "$PROD" ] && OK=1
res 3-6 4 "invoke 후 dev만 중지, prod 유지" "$OK" "invoke=$INV / $S"

echo "## 4. Conditional IAM policy"
S3B="cafe-share-$NO"
A=$(aws s3api get-bucket-policy --bucket "$S3B" --query Policy --output text 2>/dev/null | jq -c '[.Statement[] | select(.Effect=="Deny") | .Condition]' 2>/dev/null)
res 4-1 2 "HTTPS 강제 (SecureTransport false Deny)" "$(has "$A" '"aws:SecureTransport":"false"')" "$A"
A=$(aws iam get-role --role-name intern-role --query "Role.AssumeRolePolicyDocument.Statement[].Principal" --output json 2>/dev/null | tr -d ' \n')
res 4-2 1.5 "Trust policy 계정 root" "$(has "$A" "arn:aws:iam::$ACCT:root")" "$A"
A=$( (q iam list-attached-role-policies --role-name intern-role --query "AttachedPolicies[].PolicyName"; q iam list-role-policies --role-name intern-role --query PolicyNames) | tr '\t' '\n' | grep -v '^$' | sort | tr '\n' ' ')
res 4-3 1.5 "정책은 intern-policy 하나" "$(is "$(norm "$A")" intern-policy)" "$A"
C=$(aws sts assume-role --role-arn "arn:aws:iam::$ACCT:role/intern-role" --role-session-name mark --query Credentials --output json 2>/dev/null)
echo "mock-test" > /tmp/mock1_a.txt
as_intern() {
  AWS_ACCESS_KEY_ID=$(printf '%s' "$C" | jq -r .AccessKeyId) \
  AWS_SECRET_ACCESS_KEY=$(printf '%s' "$C" | jq -r .SecretAccessKey) \
  AWS_SESSION_TOKEN=$(printf '%s' "$C" | jq -r .SessionToken) \
  aws "$@" 2>&1
}
denied() { printf '%s' "$1" | grep -Eq 'AccessDenied|Access Denied|Forbidden' && echo 1 || echo 0; }
if [ -z "$C" ]; then
  for t in 4-4 4-5 4-6 4-7; do res $t 1.5 "intern-role assume 실패" 0 "assume-role error"; done
else
  R=$(as_intern s3 cp /tmp/mock1_a.txt "s3://$S3B/intern/a.txt" --sse aws:kms)
  res 4-4 1.5 "intern/ + SSE-KMS 업로드 성공" "$(has "$R" 'upload:')" "$R"
  R=$(as_intern s3 cp /tmp/mock1_a.txt "s3://$S3B/intern/b.txt")
  res 4-5 1.5 "암호화 헤더 없음 → 거부" "$(denied "$R")" "$R"
  R=$(as_intern s3 cp /tmp/mock1_a.txt "s3://$S3B/admin/a.txt" --sse aws:kms)
  res 4-6 1.5 "admin/ 업로드 → 거부" "$(denied "$R")" "$R"
  R=$(as_intern s3 rm "s3://$S3B/intern/a.txt")
  res 4-7 1.5 "삭제 → 거부" "$(denied "$R")" "$R"
fi

echo "=================================================="
echo "TOTAL SCORE: $TOTAL / $MAX"
echo "=================================================="
