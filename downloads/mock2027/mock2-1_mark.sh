#!/bin/bash
# 2027 지방대회 대비 모의고사 2회 제1과제 채점 스크립트
# 실행 위치: ticket-bastion (ec2-user, AdministratorAccess, kubectl 연결 상태)
# 사용법: bash mock2-1_mark.sh
export AWS_DEFAULT_REGION=ap-northeast-2
export AWS_PAGER=""

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
k() { timeout 30 kubectl "$@" 2>/dev/null; }
is() { [ "$1" = "$2" ] && echo 1 || echo 0; }
has() { printf '%s' "$1" | grep -Eq -- "$2" && echo 1 || echo 0; }
has_all() { local s="$1"; shift; for w in "$@"; do printf '%s' "$s" | grep -Fqw -- "$w" || { echo 0; return; }; done; echo 1; }
norm() { printf '%s' "$1" | tr '\t\n' '  ' | tr -s ' ' | sed 's/^ //;s/ $//'; }

echo "=================================================="
echo " 2027 지방 모의고사 2회 제1과제 채점 결과"
echo " 계정: $(q sts get-caller-identity --query Account)"
echo " 시각: $(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S KST')"
echo "=================================================="

echo "## 1. Networking"
VPC=$(q ec2 describe-vpcs --filters Name=tag:Name,Values=ticket-vpc --query "Vpcs[0].VpcId")
[ "$VPC" = "None" ] && VPC=""
A=$(q ec2 describe-vpcs --filters Name=tag:Name,Values=ticket-vpc --query "Vpcs[].CidrBlock")
res 1-1 1 "VPC CIDR 10.20.0.0/16" "$(is "$(norm "$A")" "10.20.0.0/16")" "$A"
A=$(q ec2 describe-subnets --filters Name=vpc-id,Values=${VPC:-none} --query "Subnets[].[Tags[?Key=='Name']|[0].Value,CidrBlock,AvailabilityZone]" | tr -s '\t ' ' ' | sort)
E="ticket-priv-a 10.20.10.0/24 ap-northeast-2a
ticket-priv-b 10.20.11.0/24 ap-northeast-2b
ticket-pub-a 10.20.0.0/24 ap-northeast-2a
ticket-pub-b 10.20.1.0/24 ap-northeast-2b"
res 1-2 1.5 "서브넷 4개 이름/CIDR/AZ" "$(is "$A" "$E")" "$A"
P=$(q ec2 describe-subnets --filters Name=vpc-id,Values=${VPC:-none} Name=tag:kubernetes.io/role/elb,Values=1 --query "Subnets[].Tags[?Key=='Name'].Value" | tr '\t' '\n' | sort | tr '\n' ' ')
I=$(q ec2 describe-subnets --filters Name=vpc-id,Values=${VPC:-none} Name=tag:kubernetes.io/role/internal-elb,Values=1 --query "Subnets[].Tags[?Key=='Name'].Value" | tr '\t' '\n' | sort | tr '\n' ' ')
OK=0; [ "$(norm "$P")" = "ticket-pub-a ticket-pub-b" ] && [ "$(norm "$I")" = "ticket-priv-a ticket-priv-b" ] && OK=1
res 1-3 1.5 "ELB 서브넷 태그" "$OK" "elb=$P internal=$I"
A=$(q ec2 describe-nat-gateways --filter Name=vpc-id,Values=${VPC:-none} Name=state,Values=available --query "NatGateways[].Tags[?Key=='Name'].Value")
res 1-4 1 "NAT ticket-nat-a, ticket-nat-b" "$(has_all "$A" ticket-nat-a ticket-nat-b)" "$A"
A=$(q ec2 describe-route-tables --filters Name=tag:Name,Values=ticket-priv-rt-a,ticket-priv-rt-b --query "RouteTables[].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId" | tr '\t' '\n' | grep '^nat-' | sort -u | wc -l)
res 1-5 1 "Private RT 2개가 각자 다른 NAT로" "$(is "$A" 2)" "distinct NAT=$A"

echo "## 2. Bastion"
BASTION=$(q ec2 describe-instances --filters Name=tag:Name,Values=ticket-bastion Name=instance-state-name,Values=running --query "Reservations[].Instances[].InstanceId")
A=$(q ec2 describe-addresses --filters Name=instance-id,Values=${BASTION:-none} --query "Addresses[].PublicIp")
res 2-1 1 "Bastion Elastic IP" "$(has "$A" '^[0-9.]+$')" "$A"
A=$(k get nodes --no-headers | grep -cw Ready)
res 2-2 2 "kubectl get nodes (Ready 2 이상)" "$([ "${A:-0}" -ge 2 ] && echo 1 || echo 0)" "ready=$A user=$(whoami)"
A=$(helm version --short 2>/dev/null)
res 2-3 1 "helm 설치" "$(has "$A" '^v3\.')" "$A"
PROF=$(q ec2 describe-iam-instance-profile-associations --filters Name=instance-id,Values=${BASTION:-none} --query "IamInstanceProfileAssociations[0].IamInstanceProfile.Arn" | awk -F/ '{print $NF}')
ROLES=$(q iam get-instance-profile --instance-profile-name "${PROF:-none}" --query "InstanceProfile.Roles[].RoleName")
A=""
for r in $ROLES; do A="$A $(q iam list-attached-role-policies --role-name "$r" --query "AttachedPolicies[].PolicyName")"; done
res 2-4 1 "Bastion 역할 AdministratorAccess" "$(has_all "$A" AdministratorAccess)" "role=$ROLES $A"

echo "## 3. DynamoDB"
A=$(q dynamodb describe-table --table-name ticket-table --query "Table.[SSEDescription.SSEType,DeletionProtectionEnabled,BillingModeSummary.BillingMode]")
set -- $A
DK=$(q dynamodb describe-table --table-name ticket-table --query "Table.SSEDescription.KMSMasterKeyArn")
AL=$(q kms list-aliases --key-id "${DK:-none}" --query "Aliases[].AliasName")
OK=0; [ "$1" = KMS ] && [ "$(has_all "$AL" alias/ticket-ddb-key)" = 1 ] && OK=1
res 3-1 1.5 "CMK alias/ticket-ddb-key" "$OK" "$1 $AL"
B=$(q dynamodb describe-continuous-backups --table-name ticket-table --query "ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus")
res 3-2 1 "PITR" "$(is "$B" ENABLED)" "$B"
res 3-3 1 "삭제 방지" "$(is "$2" True)" "$2"
res 3-4 0.5 "On-demand" "$(is "$3" PAY_PER_REQUEST)" "$3"

echo "## 4. ECR"
A=$(q ecr describe-repositories --repository-names ticket-api --query "repositories[].[imageTagMutability,imageScanningConfiguration.scanOnPush,encryptionConfiguration.encryptionType]")
res 4-1 2 "Immutable, Scan on push, KMS" "$(is "$(norm "$A")" "IMMUTABLE True KMS")" "$A"
A=$(q ecr describe-images --repository-name ticket-api --query "imageDetails[].imageTags[]")
res 4-2 1 "태그 v1.0.0" "$(has_all "$A" v1.0.0)" "$A"

echo "## 5. EKS"
A=$(q eks describe-cluster --name ticket-cluster --query "cluster.resourcesVpcConfig.[endpointPublicAccess,endpointPrivateAccess]")
res 5-1 2 "Private endpoint only" "$(is "$(norm "$A")" "False True")" "$A"
A=$(q eks describe-cluster --name ticket-cluster --query "cluster.logging.clusterLogging[?enabled].types[]")
res 5-2 2 "Control plane 로그 api, audit, authenticator" "$(has_all "$A" api audit authenticator)" "$A"
EK=$(q eks describe-cluster --name ticket-cluster --query "cluster.encryptionConfig[0].provider.keyArn")
A=$(q kms list-aliases --key-id "${EK:-none}" --query "Aliases[].AliasName")
res 5-3 2 "Secret 암호화 alias/ticket-eks-key" "$(has_all "$A" alias/ticket-eks-key)" "$A"
A=$(q eks describe-nodegroup --cluster-name ticket-cluster --nodegroup-name ticket-ng --query "nodegroup.[scalingConfig.minSize,scalingConfig.desiredSize,scalingConfig.maxSize,instanceTypes[0]]")
res 5-4 2 "Node group 2/2/4 t3.medium" "$(is "$(norm "$A")" "2 2 4 t3.medium")" "$A"
L=$(k get nodes -l role=app --no-headers | wc -l)
N=$(q ec2 describe-instances --filters Name=tag:Name,Values=ticket-node Name=instance-state-name,Values=running --query "length(Reservations[].Instances[])")
OK=0; [ "$L" -ge 2 ] && [ "${N:-0}" -ge 2 ] && OK=1
res 5-5 2 "Node label role=app, Name tag ticket-node" "$OK" "label=$L nametag=$N"

echo "## 6. Kubernetes"
D=$(k -n ticket get deploy ticket-api -o json)
jd() { printf '%s' "$D" | jq -c "$1" 2>/dev/null; }
res 6-1 2 "Deployment readyReplicas 2" "$(is "$(jd '.status.readyReplicas')" 2)" "$(jd '.status.readyReplicas')"
res 6-2 1 "nodeSelector role=app" "$(is "$(jd '.spec.template.spec.nodeSelector.role')" '"app"')" "$(jd '.spec.template.spec.nodeSelector')"
A="$(jd '.spec.template.spec.containers[0].readinessProbe.httpGet.path') $(jd '.spec.template.spec.containers[0].livenessProbe.httpGet.path')"
res 6-3 1.5 "readiness/liveness /health" "$(is "$A" '"/health" "/health"')" "$A"
A="$(jd '.spec.template.spec.containers[0].resources.requests.cpu') $(jd '.spec.template.spec.containers[0].resources.requests.memory')"
res 6-4 1 "requests 250m / 256Mi" "$(is "$A" '"250m" "256Mi"')" "$A"
A=$(k -n ticket get svc ticket-svc -o jsonpath='{.spec.type} {.spec.ports[0].port} {.spec.ports[0].targetPort}')
res 6-5 1 "Service ClusterIP 80→8080" "$(is "$A" "ClusterIP 80 8080")" "$A"
ALB_ARN=$(q elbv2 describe-load-balancers --names ticket-alb --query "LoadBalancers[0].LoadBalancerArn")
A=$(q elbv2 describe-load-balancers --names ticket-alb --query "LoadBalancers[].[Scheme,State.Code]")
T=$(q elbv2 describe-target-groups --load-balancer-arn "${ALB_ARN:-none}" --query "TargetGroups[].TargetType")
OK=0; [ "$(norm "$A")" = "internet-facing active" ] && [ "$(norm "$T")" = ip ] && OK=1
res 6-6 2 "Ingress → ALB ticket-alb, internet-facing, ip" "$OK" "$A $T"
A=$(k -n ticket get hpa ticket-hpa -o jsonpath='{.spec.minReplicas} {.spec.maxReplicas} {.spec.metrics[0].resource.target.averageUtilization}')
res 6-7 2 "HPA 2~6, CPU 50%" "$(is "$A" "2 6 50")" "$A"
A=""
for id in $(q eks list-pod-identity-associations --cluster-name ticket-cluster --namespace ticket --query "associations[].associationId"); do
  A="$A $(q eks describe-pod-identity-association --cluster-name ticket-cluster --association-id "$id" --query "association.[serviceAccount,roleArn]")"
done
res 6-8 2 "Pod Identity ticket-sa → ticket-pod-role" "$(has "$A" 'ticket-sa[[:space:]]+arn:aws:iam::[0-9]+:role/ticket-pod-role')" "$A"
A=$(k top pods -n ticket --no-headers | wc -l)
res 6-9 1.5 "Metrics Server (kubectl top)" "$([ "$A" -ge 1 ] && echo 1 || echo 0)" "rows=$A"

echo "## 7. Application"
ALB=$(q elbv2 describe-load-balancers --names ticket-alb --query "LoadBalancers[0].DNSName")
R=$(curl -s -m 10 -X POST "http://$ALB/v1/tickets" -H "Content-Type: application/json" -d '{"event":"concert","seat":"A-1"}')
TID=$(printf '%s' "$R" | jq -r '.ticket_id // empty' 2>/dev/null)
res 7-1 1.5 "POST /v1/tickets" "$(has "$TID" '^[0-9a-f-]{36}$')" "$R"
R=$(curl -s -m 10 "http://$ALB/v1/tickets?ticket_id=$TID")
OK=0; [ "$(printf '%s' "$R" | jq -r '.seat' 2>/dev/null)" = A-1 ] && [ "$(printf '%s' "$R" | jq -r '.event' 2>/dev/null)" = concert ] && OK=1
res 7-2 1.5 "GET /v1/tickets" "$OK" "$R"
A=$(printf '%s' "$D" | grep -c 'AWS_ACCESS_KEY_ID\|AWS_SECRET_ACCESS_KEY')
OK=0; [ -n "$D" ] && [ "$A" = 0 ] && OK=1
res 7-3 1 "Deployment에 액세스 키 없음" "$OK" "matches=$A"

echo "## 8. Logging"
A=$(k -n amazon-cloudwatch get ds -o custom-columns=NAME:.metadata.name,READY:.status.numberReady,DESIRED:.status.desiredNumberScheduled --no-headers | grep fluent-bit)
NODES=$(k get nodes --no-headers | wc -l)
OK=0; printf '%s' "$A" | awk -v n="$NODES" '$2==$3 && $2>=n && n>0 {f=1} END{exit !f}' && OK=1
res 8-1 1.5 "Fluent Bit DaemonSet 전 노드 Ready" "$OK" "$A nodes=$NODES"
A=$(q logs describe-log-groups --log-group-name-prefix /ticket/app --query "logGroups[?logGroupName=='/ticket/app'].retentionInDays")
res 8-2 1 "로그 보관 7일" "$(is "$A" 7)" "$A"
A=""
for i in $(seq 1 10); do
  [ -z "$TID" ] && break
  A=$(q logs filter-log-events --log-group-name /ticket/app --filter-pattern "\"$TID\"" --query "events[0].message")
  [ -n "$A" ] && [ "$A" != None ] && break
  sleep 30
done
res 8-3 1.5 "방금 만든 예매 로그 수집 (최대 5분 대기)" "$(has "$A" "${TID:-NO_TICKET}")" "$A"

echo "=================================================="
echo "TOTAL SCORE: $TOTAL / $MAX"
echo "=================================================="
