#!/bin/bash
# 2027 지방대회 대비 모의고사 2회 제2과제 채점 스크립트
# 실행 위치: iac-bastion (ec2-user, AdministratorAccess, terraform·jq 설치)
# 사용법: bash mock2-2_mark.sh <비번호>
# 주의: 1번 문항을 위해 terraform destroy/apply를 실행하고,
#       4번 문항을 위해 /ops/web/message 값을 잠시 바꾼 뒤 원래 값으로 되돌립니다.
NO="$1"
if [ -z "$NO" ]; then
  echo "사용법: bash mock2-2_mark.sh <비번호>"
  exit 1
fi
export AWS_DEFAULT_REGION=ap-northeast-2
export AWS_PAGER=""
TK="--region ap-northeast-1"
IAC_DIR=/home/ec2-user/iac

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

echo "=================================================="
echo " 2027 지방 모의고사 2회 제2과제 채점 결과"
echo " 계정: $(q sts get-caller-identity --query Account) / 비번호: $NO"
echo " 시각: $(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S KST')"
echo "=================================================="

echo "## 1. Infrastructure as Code (terraform destroy → apply 실행 중, 5분 안팎 소요)"
APPLY=1
if [ -d "$IAC_DIR" ] && command -v terraform >/dev/null; then
  ( cd "$IAC_DIR" && terraform init -input=false -no-color >/tmp/mock2_tf.log 2>&1 \
    && terraform destroy -auto-approve -input=false -no-color >>/tmp/mock2_tf.log 2>&1 \
    && terraform apply -auto-approve -input=false -no-color >>/tmp/mock2_tf.log 2>&1 )
  APPLY=$?
fi
res 1-1 3 "init → destroy → apply 무인 성공" "$([ "$APPLY" = 0 ] && echo 1 || echo 0)" "exit=$APPLY $(grep -E 'Apply complete|Error' /tmp/mock2_tf.log 2>/dev/null | tail -2)"
A=$(q s3api head-object --bucket "iac-tfstate-$NO" --key iac/terraform.tfstate --query ContentLength)
V=$(q s3api get-bucket-versioning --bucket "iac-tfstate-$NO" --query Status)
OK=0; [ "$(has "$A" '^[0-9]+$')" = 1 ] && [ "$V" = Enabled ] && OK=1
res 1-2 2 "S3 backend state + 버전 관리" "$OK" "size=$A versioning=$V"
A=$(q ec2 describe-vpcs --filters Name=tag:Name,Values=iac-vpc --query "Vpcs[].[CidrBlock,Tags[?Key=='Project']|[0].Value]")
res 1-3 1.5 "default_tags Project=KoreaSkills" "$(has "$A" 'KoreaSkills$')" "$A"
S=$(q ec2 describe-subnets --filters Name=tag:Name,Values=iac-pub-a,iac-pub-c --query "Subnets[].[Tags[?Key=='Name']|[0].Value,CidrBlock,AvailabilityZone]" | tr -s '\t ' ' ' | sort)
E="iac-pub-a 10.50.0.0/24 ap-northeast-2a
iac-pub-c 10.50.1.0/24 ap-northeast-2c"
OK=0; [ "$(has "$A" '^10\.50\.0\.0/16')" = 1 ] && [ "$S" = "$E" ] && OK=1
res 1-4 2 "VPC 10.50.0.0/16, 서브넷 2개" "$OK" "$S"
A=$(q ec2 describe-security-groups --filters Name=group-name,Values=iac-web-sg --query "SecurityGroups[].IpPermissions[].[FromPort,ToPort]")
res 1-5 1.5 "SG inbound 80만 (SSH 없음)" "$(is "$(norm "$A")" "80 80")" "$A"
WEB=$(q ec2 describe-instances --filters Name=tag:Name,Values=iac-web Name=instance-state-name,Values=running --query "Reservations[0].Instances[0].InstanceId")
T=$(q ec2 describe-instances --instance-ids "${WEB:-i-none}" --query "Reservations[].Instances[].MetadataOptions.HttpTokens")
EN=$(q ec2 describe-volumes --filters Name=attachment.instance-id,Values=${WEB:-i-none} --query "Volumes[].Encrypted")
OK=0; [ "$T" = required ] && [ -n "$EN" ] && ! printf '%s' "$EN" | grep -q False && OK=1
res 1-6 2 "EBS 암호화 + IMDSv2 필수" "$OK" "tokens=$T encrypted=$EN"
URL=$(cd "$IAC_DIR" 2>/dev/null && terraform output -raw web_url 2>/dev/null)
R=""
for i in $(seq 1 12); do
  [ -z "$URL" ] && break
  R=$(curl -s -m 5 "$URL")
  printf '%s' "$R" | grep -q 'Hello Terraform' && break
  sleep 15
done
res 1-7 2 "web_url 응답 Hello Terraform" "$(has "$R" 'Hello Terraform')" "$URL $R"

echo "## 2. Streaming data lake"
A=$(q firehose describe-delivery-stream --delivery-stream-name click-stream --query "DeliveryStreamDescription.Destinations[0].ExtendedS3DestinationDescription.[BufferingHints.IntervalInSeconds,BufferingHints.SizeInMBs,Prefix,ErrorOutputPrefix]")
set -f; set -- $A; set +f
OK=0; [ "$1" = 60 ] && [ "$2" = 1 ] && [ "$3" = 'clicks/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/' ] && OK=1
res 2-1 2.5 "Firehose 버퍼 60초/1MiB, 파티션 prefix" "$OK" "$1 $2 $3"
res 2-2 1 "Error prefix" "$(is "$4" 'errors/!{firehose:error-output-type}/')" "$4"
A=$(q s3api list-objects-v2 --bucket "click-lake-$NO" --prefix clicks/year= --query "Contents[].Key" | tr '\t' '\n' | head -1)
res 2-3 1.5 "clicks/year=YYYY/month=MM/day=DD/ 객체" "$(has "$A" '^clicks/year=[0-9]{4}/month=[0-9]{2}/day=[0-9]{2}/')" "$A"
A=$(q glue get-table --database-name click_db --name clicks --query "Table.PartitionKeys[].Name")
res 2-4 2 "Glue table clicks 파티션 year/month/day" "$(is "$(norm "$A")" "year month day")" "$A"
A=$(q athena get-work-group --work-group click-wg --query "WorkGroup.Configuration.[BytesScannedCutoffPerQuery,ResultConfiguration.OutputLocation]")
OK=0; [ "$(has "$(norm "$A")" "^104857600 s3://click-result-$NO/?$")" = 1 ] && OK=1
res 2-5 2 "Workgroup 스캔 제한 100MB, 결과 위치" "$OK" "$A"
SQL=""
for id in $(q athena list-named-queries --work-group click-wg --query NamedQueryIds); do
  n=$(q athena get-named-query --named-query-id "$id" --query NamedQuery.Name)
  if [ "$n" = click-top-pages ]; then
    SQL=$(aws athena get-named-query --named-query-id "$id" --query NamedQuery.QueryString --output text 2>/dev/null)
  fi
done
res 2-6 1 "Saved query click-top-pages" "$([ -n "$SQL" ] && echo 1 || echo 0)" "$SQL"
R=""
if [ -n "$SQL" ]; then
  EID=$(q athena start-query-execution --work-group click-wg --query-execution-context Database=click_db --query-string "$SQL" --query QueryExecutionId)
  for i in $(seq 1 20); do
    st=$(q athena get-query-execution --query-execution-id "${EID:-none}" --query QueryExecution.Status.State)
    case "$st" in SUCCEEDED|FAILED|CANCELLED) break;; esac
    sleep 3
  done
  R=$(q athena get-query-results --query-execution-id "${EID:-none}" --query "ResultSet.Rows[].Data[].VarCharValue")
fi
res 2-7 3 "쿼리 결과 page,cnt /menu 3 /order 2 /event 1" "$(is "$(norm "$R")" "page cnt /menu 3 /order 2 /event 1")" "$R"

echo "## 3. Serverless REST API"
API=$(q apigateway get-rest-apis --query "items[?name=='memo-api'].id" | awk '{print $1}')
URL="https://$API.execute-api.ap-northeast-2.amazonaws.com/prod"
KEY=$(q apigateway get-api-keys --name-query memo-key --include-values --query "items[0].value")
A=$(q lambda get-function-configuration --function-name memo-handler --query "[Runtime,Environment.Variables.TABLE_NAME]")
res 3-1 1 "Lambda python3.12, TABLE_NAME=memo-table" "$(is "$(norm "$A")" "python3.12 memo-table")" "$A"
A=$(q apigateway get-stages --rest-api-id "${API:-none}" --query "item[].stageName")
res 3-2 1 "Stage prod" "$(has_all "$A" prod)" "$A"
A=$(q apigateway get-usage-plans --query "items[?name=='memo-plan'].[throttle.rateLimit,throttle.burstLimit,quota.limit,quota.period]")
res 3-3 2 "Usage plan 10 rps / 20 / 1000 per DAY" "$(has "$(norm "$A")" '^10(\.0)? 20 1000 DAY$')" "$A"
PLAN=$(q apigateway get-usage-plans --query "items[?name=='memo-plan'].id")
A=$(q apigateway get-usage-plan-keys --usage-plan-id "${PLAN:-none}" --query "items[].name")
res 3-4 1 "API key memo-key 연결" "$(has_all "$A" memo-key)" "$A"
R=$(curl -s -m 10 -X POST "$URL/memos" -H "x-api-key: $KEY" -H "Content-Type: application/json" -d '{"text":"hello"}' -w $'\n%{http_code}')
C=$(printf '%s' "$R" | tail -1); MID=$(printf '%s' "$R" | head -1 | jq -r '.memo_id // empty' 2>/dev/null)
OK=0; [ "$C" = 201 ] && [ -n "$MID" ] && OK=1
res 3-5 2 "POST /memos → 201" "$OK" "$R"
R=$(curl -s -m 10 "$URL/memos/$MID" -H "x-api-key: $KEY" -w $'\n%{http_code}')
OK=0; [ "$(printf '%s' "$R" | tail -1)" = 200 ] && [ "$(printf '%s' "$R" | head -1 | jq -r '.text' 2>/dev/null)" = hello ] && OK=1
res 3-6 2 "GET /memos/{id} → 200" "$OK" "$R"
R=$(curl -s -m 10 "$URL/memos/nothing-$RANDOM" -H "x-api-key: $KEY" -w $'\n%{http_code}')
res 3-7 1.5 "없는 ID → 404" "$(is "$(printf '%s' "$R" | tail -1)" 404)" "$R"
C=$(curl -s -m 10 -o /dev/null -w "%{http_code}" "$URL/memos/${MID:-x}")
res 3-8 1.5 "키 없음 → 403" "$(is "$C" 403)" "$C"
ROLE=$(q lambda get-function-configuration --function-name memo-handler --query Role | awk -F/ '{print $NF}')
: > /tmp/mock2_docs.json
for p in $(q iam list-role-policies --role-name "${ROLE:-none}" --query PolicyNames); do
  aws iam get-role-policy --role-name "$ROLE" --policy-name "$p" --query PolicyDocument --output json >> /tmp/mock2_docs.json 2>/dev/null
done
AWSDDB=0
for arn in $(q iam list-attached-role-policies --role-name "${ROLE:-none}" --query "AttachedPolicies[].PolicyArn"); do
  case "$arn" in arn:aws:iam::aws:policy/*DynamoDB*) AWSDDB=1;; arn:aws:iam::aws:policy/*) ;; *)
    v=$(q iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId)
    aws iam get-policy-version --policy-arn "$arn" --version-id "$v" --query PolicyVersion.Document --output json >> /tmp/mock2_docs.json 2>/dev/null;;
  esac
done
A=$(jq -s '[.[] | .Statement | if type=="array" then .[] else . end | select((.Action|tostring)|test("dynamodb"))]
  | (length>0) and all(.[]; ((.Action|if type=="string" then [.] else . end) | all(.[]; .=="dynamodb:PutItem" or .=="dynamodb:GetItem"))
      and ((.Resource|if type=="string" then [.] else . end) | all(.[]; test(":table/memo-table$"))))' /tmp/mock2_docs.json 2>/dev/null)
OK=0; [ "$A" = true ] && [ "$AWSDDB" = 0 ] && OK=1
res 3-9 1 "Lambda 역할 최소 권한 (PutItem·GetItem, memo-table)" "$OK" "role=$ROLE jq=$A awsManagedDDB=$AWSDDB"

echo "## 4. Fleet operation with SSM (도쿄)"
A=$(q ssm describe-instance-information $TK --filters Key=tag:Role,Values=web --query "InstanceInformationList[].PingStatus")
res 4-1 2 "Managed instance 2대 Online" "$(is "$(norm "$A")" "Online Online")" "$A"
A=$(q ssm describe-parameters $TK --parameter-filters Key=Name,Values=/ops/web/message --query "Parameters[].Type")
res 4-2 1 "Parameter SecureString" "$(is "$A" SecureString)" "$A"
A=$(q ssm describe-document --name ops-update-index $TK --query "Document.DocumentType")
res 4-3 1 "Document type Command" "$(is "$A" Command)" "$A"
A=$(q ssm list-associations $TK --association-filter-list key=AssociationName,value=ops-association --query "Associations[].[ScheduleExpression,Targets[0].Key,Targets[0].Values[0]]")
res 4-4 2 "Association rate(30 minutes), tag:Role=web" "$(is "$(norm "$A")" "rate(30 minutes) tag:Role web")" "$A"
SGS=$(q ec2 describe-instances $TK --filters Name=tag:Role,Values=web Name=instance-state-name,Values=running --query "Reservations[].Instances[].SecurityGroups[].GroupId" | tr '\t' '\n' | sort -u | tr '\n' ' ')
A=$(q ec2 describe-security-groups $TK --group-ids ${SGS:-sg-none} --query "SecurityGroups[].IpPermissions[?FromPort==\`22\`].FromPort")
OK=0; [ -n "$SGS" ] && [ -z "$A" ] && OK=1
res 4-5 1 "웹 서버 SG에 SSH(22) 없음" "$OK" "sgs=$SGS port22=${A:-없음}"
ORIG=$(q ssm get-parameter $TK --name /ops/web/message --with-decryption --query Parameter.Value)
NEWV="Mark Test $NO $RANDOM"
OUT=""
if [ -n "$ORIG" ]; then
  q ssm put-parameter $TK --name /ops/web/message --type SecureString --value "$NEWV" --overwrite >/dev/null
  AID=$(q ssm list-associations $TK --association-filter-list key=AssociationName,value=ops-association --query "Associations[0].AssociationId")
  q ssm start-associations-once $TK --association-ids "${AID:-none}" >/dev/null
  sleep 90
  CID=$(q ssm send-command $TK --document-name AWS-RunShellScript --targets Key=tag:Role,Values=web --parameters 'commands=["curl -s localhost"]' --query Command.CommandId)
  sleep 15
  OUT=$(q ssm list-command-invocations $TK --command-id "${CID:-none}" --details --query "CommandInvocations[].CommandPlugins[].Output")
  q ssm put-parameter $TK --name /ops/web/message --type SecureString --value "$ORIG" --overwrite >/dev/null
fi
N=$(printf '%s' "$OUT" | grep -o "$NEWV" | wc -l)
res 4-6 3 "값 변경 후 association 실행 → 2대 반영" "$([ "$N" -ge 2 ] && echo 1 || echo 0)" "expect='$NEWV' count=$N"

echo "=================================================="
echo "TOTAL SCORE: $TOTAL / $MAX"
echo "=================================================="
