#!/usr/bin/env bash
set -u

OUT="challenge2-grade-result.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check() {
  local module="$1" id="$2" points="$3" title="$4" command="$5"
  if bash -c "$command" >"$TMP/${module}-${id}.log" 2>&1; then
    printf '%s\t%s\t%s\t%s\tpass\n' "$module" "$id" "$points" "$title" >>"$TMP/results.tsv"
  else
    printf '%s\t%s\t%s\t%s\tfail\n' "$module" "$id" "$points" "$title" >>"$TMP/results.tsv"
  fi
}

: >"$TMP/results.tsv"

# Module 1 — DynamoDB (7.5)
check 1 1 1.5 "VPC와 Client EC2" 'aws ec2 describe-vpcs --region ap-northeast-2 --filters Name=tag:Name,Values=practice-orders-vpc --query "Vpcs[?CidrBlock==`10.81.0.0/16`].VpcId|[0]" --output text | grep -q "^vpc-" && aws ec2 describe-instances --region ap-northeast-2 --filters Name=tag:Name,Values=practice-orders-client Name=instance-state-name,Values=running --query "Reservations[0].Instances[0].[InstanceType,PublicIpAddress]" --output text | grep -q "t3.micro"'
check 1 2 1.5 "DynamoDB 테이블" 'for t in practice-orders practice-products practice-sessions; do aws dynamodb describe-table --region ap-northeast-2 --table-name "$t" --query "Table.TableStatus" --output text | grep -q ACTIVE || exit 1; done'
check 1 3 1.5 "GSI와 TTL" 'aws dynamodb describe-table --region ap-northeast-2 --table-name practice-orders --query "Table.GlobalSecondaryIndexes[].IndexName" --output text | grep -q CustomerCreatedAtIndex && aws dynamodb describe-table --region ap-northeast-2 --table-name practice-products --query "Table.GlobalSecondaryIndexes[].IndexName" --output text | grep -q WarehouseStockIndex && aws dynamodb describe-time-to-live --region ap-northeast-2 --table-name practice-sessions --query "TimeToLiveDescription.[TimeToLiveStatus,AttributeName]" --output text | grep -q "ENABLED.*expiresAt"'
check 1 4 1.5 "암호화와 PITR" 'aws dynamodb describe-continuous-backups --region ap-northeast-2 --table-name practice-orders --query "ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus" --output text | grep -q ENABLED && aws dynamodb describe-table --region ap-northeast-2 --table-name practice-orders --query "Table.SSEDescription.SSEType" --output text | grep -q KMS'
check 1 5 1.5 "Application API" 'IP=$(aws ec2 describe-instances --region ap-northeast-2 --filters Name=tag:Name,Values=practice-orders-client Name=instance-state-name,Values=running --query "Reservations[0].Instances[0].PublicIpAddress" --output text); curl -fsS -m 10 "http://$IP:8080/health" | grep -q dynamodb && curl -fsS -m 10 "http://$IP:8080/v1/orders/O-2001" | grep -q O-2001'

# Module 2 — VPC Lattice (7.5)
check 2 1 1.5 "두 VPC CIDR" 'aws ec2 describe-vpcs --region ap-northeast-1 --filters Name=tag:Name,Values=practice-lattice-client-vpc --query "Vpcs[?CidrBlock==`10.82.0.0/16`].VpcId|[0]" --output text | grep -q "^vpc-" && aws ec2 describe-vpcs --region ap-northeast-1 --filters Name=tag:Name,Values=practice-lattice-service-vpc --query "Vpcs[?CidrBlock==`10.83.0.0/16`].VpcId|[0]" --output text | grep -q "^vpc-"'
check 2 2 1.5 "Client와 Service EC2" 'C=$(aws ec2 describe-instances --region ap-northeast-1 --filters Name=tag:Name,Values=practice-lattice-client Name=instance-state-name,Values=running --query "Reservations[0].Instances[0].PublicIpAddress" --output text); S=$(aws ec2 describe-instances --region ap-northeast-1 --filters Name=tag:Name,Values=practice-lattice-inventory Name=instance-state-name,Values=running --query "Reservations[0].Instances[0].PublicIpAddress" --output text); test "$C" != None -a "$C" != null -a "$S" = None'
check 2 3 1.5 "Service Network와 Service" 'aws vpc-lattice list-service-networks --region ap-northeast-1 --query "items[?name==`practice-lattice-sn`].status|[0]" --output text | grep -q ACTIVE && aws vpc-lattice list-services --region ap-northeast-1 --query "items[?name==`practice-lattice-inventory-service`].status|[0]" --output text | grep -q ACTIVE'
check 2 4 1.5 "Target Group과 Listener" 'TG=$(aws vpc-lattice list-target-groups --region ap-northeast-1 --query "items[?name==`practice-lattice-inventory-tg`].id|[0]" --output text); test "$TG" != None && aws vpc-lattice list-targets --region ap-northeast-1 --target-group-identifier "$TG" --query "items[0].status" --output text | grep -Eq "HEALTHY|ACTIVE"'
check 2 5 1.5 "End-to-End API" 'IP=$(aws ec2 describe-instances --region ap-northeast-1 --filters Name=tag:Name,Values=practice-lattice-client Name=instance-state-name,Values=running --query "Reservations[0].Instances[0].PublicIpAddress" --output text); R=$(curl -fsS -m 10 "http://$IP/v1/client/inventory?id=P-100"); grep -q P-100 <<<"$R" && grep -q vpc-lattice <<<"$R"'

# Module 3 — IAM Event Handling (7.5)
check 3 1 1.5 "Protected Role과 Backup" 'aws iam get-role --role-name practice-protected-role --query "Role.RoleName" --output text | grep -q practice-protected-role && aws s3api list-buckets --query "Buckets[?starts_with(Name, `practice-iam-backup-`)].Name|[0]" --output text | grep -q practice-iam-backup-'
check 3 2 1.5 "SNS Topic" 'aws sns list-topics --region ap-northeast-2 --query "Topics[?contains(TopicArn, `:practice-iam-alert-topic`)].TopicArn|[0]" --output text | grep -q practice-iam-alert-topic'
check 3 3 1.5 "Lambda 구성" 'aws lambda get-function-configuration --region ap-northeast-2 --function-name practice-iam-remediate-fn --query "[State,Runtime,Handler,Timeout]" --output text | grep -q "Active.*python3.12.*remediate_iam.lambda_handler"'
check 3 4 1.5 "EventBridge Target" 'aws events describe-rule --region ap-northeast-2 --name practice-iam-change-rule --query "[State,EventPattern]" --output text | grep -q "ENABLED.*UpdateAssumeRolePolicy" && aws events list-targets-by-rule --region ap-northeast-2 --rule practice-iam-change-rule --query "Targets[?contains(Arn, `practice-iam-remediate-fn`)].Arn|[0]" --output text | grep -q practice-iam-remediate-fn'
check 3 5 1.5 "Lambda Log" 'aws logs describe-log-groups --region ap-northeast-2 --log-group-name-prefix /aws/lambda/practice-iam-remediate-fn --query "logGroups[0].logGroupName" --output text | grep -q practice-iam-remediate-fn'

# Module 4 — SQS + ECS (7.5)
check 4 1 1.5 "SQS와 DLQ" 'Q=$(aws sqs get-queue-url --region ap-northeast-2 --queue-name practice-ecs-queue --query QueueUrl --output text); aws sqs get-queue-attributes --region ap-northeast-2 --queue-url "$Q" --attribute-names VisibilityTimeout RedrivePolicy --query "Attributes" --output json | grep -q RedrivePolicy'
check 4 2 1.5 "ECR Image" 'aws ecr describe-images --region ap-northeast-2 --repository-name practice-ecs-worker --image-ids imageTag=latest --query "imageDetails[0].imageDigest" --output text | grep -q sha256:'
check 4 3 1.5 "ECS Cluster와 Service" 'aws ecs describe-clusters --region ap-northeast-2 --clusters practice-ecs-cluster --query "clusters[0].status" --output text | grep -q ACTIVE && aws ecs describe-services --region ap-northeast-2 --cluster practice-ecs-cluster --services practice-ecs-worker-service --query "services[0].status" --output text | grep -q ACTIVE'
check 4 4 1.5 "Service Auto Scaling" 'aws application-autoscaling describe-scalable-targets --region ap-northeast-2 --service-namespace ecs --resource-ids service/practice-ecs-cluster/practice-ecs-worker-service --query "ScalableTargets[0].[MinCapacity,MaxCapacity]" --output text | grep -q $'"'"'0[[:space:]]*6'"'"''
check 4 5 1.5 "CloudWatch Alarms" 'aws cloudwatch describe-alarms --region ap-northeast-2 --alarm-names practice-ecs-scale-out-alarm practice-ecs-scale-in-alarm --query "length(MetricAlarms)" --output text | grep -q 2'

python3 - "$TMP/results.tsv" "$OUT" <<'PY'
import csv, json, sys
rows=[]
with open(sys.argv[1], encoding="utf-8") as f:
    for module, cid, points, title, status in csv.reader(f, delimiter="\t"):
        rows.append({"module":int(module),"id":cid,"title":title,"points":float(points),"status":status,"earned":float(points) if status=="pass" else 0})
modules=[]
for number in range(1,5):
    checks=[r for r in rows if r["module"]==number]
    modules.append({"module":number,"score":sum(r["earned"] for r in checks),"max":sum(r["points"] for r in checks),"checks":checks})
payload={"schema":"challenge2-practice-v1","generatedAt":__import__("datetime").datetime.now().astimezone().isoformat(),"score":sum(r["earned"] for r in rows),"maxScore":sum(r["points"] for r in rows),"modules":modules}
with open(sys.argv[2],"w",encoding="utf-8") as f: json.dump(payload,f,ensure_ascii=False,indent=2)
print(json.dumps(payload,ensure_ascii=False,indent=2))
PY

echo "완료: $OUT"
