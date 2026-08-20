#!/usr/bin/env bash
set -uo pipefail

OUT="challenge2-grade-result.json"
LOG_DIR="challenge2-grade-logs"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export AWS_PAGER=""
GRADER_VERSION="2026-08-20.2"
mkdir -p "$LOG_DIR"
: >"$TMP/results.tsv"

say() { printf '%s\n' "$*"; }
fatal() { printf '[오류] %s\n' "$*" >&2; exit 1; }

find_python() {
  if command -v python3 >/dev/null 2>&1; then
    printf 'python3'
  elif command -v python >/dev/null 2>&1; then
    printf 'python'
  else
    return 1
  fi
}

record() {
  local module="$1" id="$2" points="$3" title="$4" status="$5"
  printf '%s\t%s\t%s\t%s\t%s\n' "$module" "$id" "$points" "$title" "$status" >>"$TMP/results.tsv"
}

check() {
  local module="$1" id="$2" points="$3" title="$4" command="$5"
  local log="$LOG_DIR/module${module}-${id}.log"
  if bash -o pipefail -c "$command" >"$log" 2>&1; then
    record "$module" "$id" "$points" "$title" pass
    printf '[PASS] M%s-%s %s (+%s)\n' "$module" "$id" "$title" "$points"
  else
    record "$module" "$id" "$points" "$title" fail
    printf '[FAIL] M%s-%s %s (+0/%s)\n' "$module" "$id" "$title" "$points"
    if [[ -s "$log" ]]; then
      sed 's/^/       /' "$log" | tail -n 4
    else
      printf '       조건과 일치하는 리소스를 찾지 못했습니다.\n'
    fi
  fi
}

write_json() {
  local py="$1"
  "$py" - "$TMP/results.tsv" "$OUT" <<'PY'
import csv
import datetime
import json
import sys

rows = []
with open(sys.argv[1], encoding="utf-8") as stream:
    for module, cid, points, title, status in csv.reader(stream, delimiter="\t"):
        value = float(points)
        rows.append({
            "module": int(module),
            "id": cid,
            "title": title,
            "points": value,
            "status": status,
            "earned": value if status == "pass" else 0.0,
        })

modules = []
for number in range(1, 5):
    checks = [row for row in rows if row["module"] == number]
    modules.append({
        "module": number,
        "score": round(sum(row["earned"] for row in checks), 1),
        "max": round(sum(row["points"] for row in checks), 1),
        "checks": checks,
    })

payload = {
    "schema": "challenge2-practice-v1",
    "generatedAt": datetime.datetime.now().astimezone().isoformat(),
    "score": round(sum(row["earned"] for row in rows), 1),
    "maxScore": round(sum(row["points"] for row in rows), 1),
    "modules": modules,
}
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(payload, stream, ensure_ascii=False, indent=2)
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
}

PYTHON_BIN="$(find_python)" || fatal "python3 또는 python 명령을 찾을 수 없습니다. AWS CloudShell에서 실행하세요."

if [[ "${1:-}" == "--self-test" ]]; then
  OUT="challenge2-grade-self-test.json"
  say "채점 스크립트 자체 테스트를 실행합니다. AWS 리소스는 조회하지 않습니다."
  for module in 1 2 3 4; do
    for id in 1 2 3 4 5; do
      check "$module" "$id" 1.5 "Self test M${module}-${id}" true
    done
  done
  write_json "$PYTHON_BIN" >/dev/null || fatal "자체 테스트 JSON 생성에 실패했습니다."
  "$PYTHON_BIN" - "$OUT" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert data["schema"] == "challenge2-practice-v1"
assert data["score"] == 30.0 and data["maxScore"] == 30.0
assert len(data["modules"]) == 4
assert all(len(module["checks"]) == 5 for module in data["modules"])
PY
  say "[PASS] 자체 테스트 완료: $OUT"
  exit 0
fi

command -v aws >/dev/null 2>&1 || fatal "AWS CLI를 찾을 수 없습니다. AWS CloudShell에서 실행하세요."
command -v curl >/dev/null 2>&1 || fatal "curl을 찾을 수 없습니다."
if ! aws sts get-caller-identity --output json >"$LOG_DIR/aws-identity.log" 2>&1; then
  cat "$LOG_DIR/aws-identity.log" >&2
  fatal "AWS 로그인 정보를 확인할 수 없습니다. 콘솔에 다시 로그인한 뒤 CloudShell을 새로 열어주세요."
fi

say "채점기 버전: $GRADER_VERSION"
say "제2과제 모듈 1~4 채점을 시작합니다. 실패 상세 로그: $LOG_DIR"

# Module 1 — DynamoDB (7.5)
check 1 1 1.5 "VPC와 Client EC2" 'VPC=$(aws ec2 describe-vpcs --region ap-northeast-2 --filters Name=tag:Name,Values=practice-orders-vpc --query "Vpcs[?CidrBlock==\`10.81.0.0/16\`].VpcId|[0]" --output text); test "${VPC:-None}" != None && ROW=$(aws ec2 describe-instances --region ap-northeast-2 --filters Name=tag:Name,Values=practice-orders-client Name=instance-state-name,Values=running --query "Reservations[0].Instances[0].[InstanceType,PublicIpAddress]" --output text); printf "%s" "$ROW" | grep -Eq "t3\.micro[[:space:]]+[0-9]+\."'
check 1 2 1.5 "DynamoDB 테이블" 'for t in practice-orders practice-products practice-sessions; do test "$(aws dynamodb describe-table --region ap-northeast-2 --table-name "$t" --query Table.TableStatus --output text)" = ACTIVE || exit 1; done'
check 1 3 1.5 "GSI와 TTL" 'test "$(aws dynamodb describe-table --region ap-northeast-2 --table-name practice-orders --query "Table.GlobalSecondaryIndexes[?IndexName==\`CustomerCreatedAtIndex\`].IndexStatus|[0]" --output text)" = ACTIVE && test "$(aws dynamodb describe-table --region ap-northeast-2 --table-name practice-products --query "Table.GlobalSecondaryIndexes[?IndexName==\`WarehouseStockIndex\`].IndexStatus|[0]" --output text)" = ACTIVE && TTL=$(aws dynamodb describe-time-to-live --region ap-northeast-2 --table-name practice-sessions --query "TimeToLiveDescription.[TimeToLiveStatus,AttributeName]" --output text) && printf "%s" "$TTL" | grep -Eq "ENABLED[[:space:]]+expiresAt"'
check 1 4 1.5 "암호화와 PITR" 'test "$(aws dynamodb describe-continuous-backups --region ap-northeast-2 --table-name practice-orders --query ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus --output text)" = ENABLED && test "$(aws dynamodb describe-table --region ap-northeast-2 --table-name practice-orders --query Table.SSEDescription.SSEType --output text)" = KMS'
check 1 5 1.5 "Application API" 'IP=$(aws ec2 describe-instances --region ap-northeast-2 --filters Name=tag:Name,Values=practice-orders-client Name=instance-state-name,Values=running --query "Reservations[0].Instances[0].PublicIpAddress" --output text); test -n "$IP" && test "$IP" != None && curl -fsS -m 10 "http://$IP:8080/health" | grep -q dynamodb && curl -fsS -m 10 "http://$IP:8080/v1/orders/O-2001" | grep -q O-2001'

# Module 2 — VPC Lattice (7.5)
check 2 1 1.5 "두 VPC CIDR" 'A=$(aws ec2 describe-vpcs --region ap-northeast-1 --filters Name=tag:Name,Values=practice-lattice-client-vpc --query "Vpcs[?CidrBlock==\`10.82.0.0/16\`].VpcId|[0]" --output text); B=$(aws ec2 describe-vpcs --region ap-northeast-1 --filters Name=tag:Name,Values=practice-lattice-service-vpc --query "Vpcs[?CidrBlock==\`10.83.0.0/16\`].VpcId|[0]" --output text); [[ "$A" == vpc-* && "$B" == vpc-* ]]'
check 2 2 1.5 "Client와 Service EC2" 'C=$(aws ec2 describe-instances --region ap-northeast-1 --filters Name=tag:Name,Values=practice-lattice-client Name=instance-state-name,Values=running --query "Reservations[0].Instances[0].PublicIpAddress" --output text); S=$(aws ec2 describe-instances --region ap-northeast-1 --filters Name=tag:Name,Values=practice-lattice-inventory Name=instance-state-name,Values=running --query "Reservations[0].Instances[0].PublicIpAddress" --output text); test -n "$C" && test "$C" != None && { test -z "$S" || test "$S" = None; }'
check 2 3 1.5 "Service Network와 Service" 'test "$(aws vpc-lattice list-service-networks --region ap-northeast-1 --query "items[?name==\`practice-lattice-sn\`].status|[0]" --output text)" = ACTIVE && test "$(aws vpc-lattice list-services --region ap-northeast-1 --query "items[?name==\`practice-lattice-inventory-service\`].status|[0]" --output text)" = ACTIVE'
check 2 4 1.5 "Target Group과 Listener" 'TG=$(aws vpc-lattice list-target-groups --region ap-northeast-1 --query "items[?name==\`practice-lattice-inventory-tg\`].id|[0]" --output text); SID=$(aws vpc-lattice list-services --region ap-northeast-1 --query "items[?name==\`practice-lattice-inventory-service\`].id|[0]" --output text); test -n "$TG" && test "$TG" != None && test "$(aws vpc-lattice list-targets --region ap-northeast-1 --target-group-identifier "$TG" --query "items[0].status" --output text)" = HEALTHY && test "$(aws vpc-lattice list-listeners --region ap-northeast-1 --service-identifier "$SID" --query "items[?name==\`practice-lattice-http-listener\` && protocol==\`HTTP\` && port==\`80\`].id|[0]" --output text)" != None'
check 2 5 1.5 "End-to-End API" 'IP=$(aws ec2 describe-instances --region ap-northeast-1 --filters Name=tag:Name,Values=practice-lattice-client Name=instance-state-name,Values=running --query "Reservations[0].Instances[0].PublicIpAddress" --output text); test -n "$IP" && test "$IP" != None && R=$(curl -fsS -m 10 "http://$IP/v1/client/inventory?id=P-100") && printf "%s" "$R" | grep -q P-100 && printf "%s" "$R" | grep -q vpc-lattice'

# Module 3 — IAM Event Handling (7.5)
check 3 1 1.5 "Protected Role과 Backup" 'test "$(aws iam get-role --role-name practice-protected-role --query Role.RoleName --output text)" = practice-protected-role && B=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, \`practice-iam-backup-\`)].Name|[0]" --output text) && [[ "$B" == practice-iam-backup-* ]]'
check 3 2 1.5 "SNS Topic" 'ARN=$(aws sns list-topics --region ap-northeast-2 --query "Topics[?contains(TopicArn, \`:practice-iam-alert-topic\`)].TopicArn|[0]" --output text); [[ "$ARN" == *:practice-iam-alert-topic ]]'
check 3 3 1.5 "Lambda 구성" 'ROW=$(aws lambda get-function-configuration --region ap-northeast-2 --function-name practice-iam-remediate-fn --query "[State,Runtime,Handler,Timeout]" --output text); printf "%s" "$ROW" | grep -Eq "Active[[:space:]]+python3\.12[[:space:]]+remediate_iam\.lambda_handler[[:space:]]+([3-9][0-9]|[1-9][0-9]{2,})"'
check 3 4 1.5 "EventBridge Target" 'ROW=$(aws events describe-rule --region ap-northeast-2 --name practice-iam-change-rule --query "[State,EventPattern]" --output text); printf "%s" "$ROW" | grep -q ENABLED && printf "%s" "$ROW" | grep -q UpdateAssumeRolePolicy && ARN=$(aws events list-targets-by-rule --region ap-northeast-2 --rule practice-iam-change-rule --query "Targets[?contains(Arn, \`practice-iam-remediate-fn\`)].Arn|[0]" --output text) && [[ "$ARN" == *practice-iam-remediate-fn* ]]'
check 3 5 1.5 "Lambda Log" 'NAME=$(aws logs describe-log-groups --region ap-northeast-2 --log-group-name-prefix /aws/lambda/practice-iam-remediate-fn --query "logGroups[0].logGroupName" --output text); [[ "$NAME" == */aws/lambda/practice-iam-remediate-fn ]] || test "$NAME" = /aws/lambda/practice-iam-remediate-fn'

# Module 4 — SQS + ECS (7.5)
check 4 1 1.5 "SQS와 DLQ" 'Q=$(aws sqs get-queue-url --region ap-northeast-2 --queue-name practice-ecs-queue --query QueueUrl --output text); test -n "$Q" && A=$(aws sqs get-queue-attributes --region ap-northeast-2 --queue-url "$Q" --attribute-names VisibilityTimeout RedrivePolicy --query Attributes --output json) && printf "%s" "$A" | grep -q RedrivePolicy'
check 4 2 1.5 "ECR Image" 'D=$(aws ecr describe-images --region ap-northeast-2 --repository-name practice-ecs-worker --image-ids imageTag=latest --query "imageDetails[0].imageDigest" --output text); [[ "$D" == sha256:* ]]'
check 4 3 1.5 "ECS Cluster와 Service" 'test "$(aws ecs describe-clusters --region ap-northeast-2 --clusters practice-ecs-cluster --query "clusters[0].status" --output text)" = ACTIVE && test "$(aws ecs describe-services --region ap-northeast-2 --cluster practice-ecs-cluster --services practice-ecs-worker-service --query "services[0].status" --output text)" = ACTIVE'
check 4 4 1.5 "Service Auto Scaling" 'ROW=$(aws application-autoscaling describe-scalable-targets --region ap-northeast-2 --service-namespace ecs --resource-ids service/practice-ecs-cluster/practice-ecs-worker-service --query "ScalableTargets[0].[MinCapacity,MaxCapacity]" --output text); read -r MIN MAX <<<"$ROW"; test "${MIN:-}" = 0 && test "${MAX:-}" = 6'
check 4 5 1.5 "CloudWatch Alarms" 'test "$(aws cloudwatch describe-alarms --region ap-northeast-2 --alarm-names practice-ecs-scale-out-alarm practice-ecs-scale-in-alarm --query "length(MetricAlarms)" --output text)" = 2'

if ! write_json "$PYTHON_BIN"; then
  fatal "결과 JSON 생성에 실패했습니다. $TMP/results.tsv 내용을 확인하세요."
fi

say "완료: $OUT"
say "실패 상세 로그: $LOG_DIR"
