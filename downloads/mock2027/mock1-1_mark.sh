#!/bin/bash
# 2027 지방대회 대비 모의고사 1회 제1과제 채점 스크립트
# 실행 위치: cafe-bastion (AdministratorAccess 역할)
# 사용법: bash mock1-1_mark.sh
export AWS_DEFAULT_REGION=ap-northeast-2
export AWS_PAGER=""

TOTAL=0
MAX=0

# res <번호> <배점> <설명> <통과여부 0/1> <확인값>
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
has_all() { local s="$1"; shift; for w in "$@"; do printf '%s' "$s" | grep -Fqw -- "$w" || { echo 0; return; }; done; echo 1; }
norm() { printf '%s' "$1" | tr '\t\n' '  ' | tr -s ' ' | sed 's/^ //;s/ $//'; }

echo "=================================================="
echo " 2027 지방 모의고사 1회 제1과제 채점 결과"
echo " 계정: $(q sts get-caller-identity --query Account)"
echo " 시각: $(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S KST')"
echo "=================================================="

echo "## 1. VPC"
VPC=$(q ec2 describe-vpcs --filters Name=tag:Name,Values=cafe-vpc --query "Vpcs[0].VpcId")
[ "$VPC" = "None" ] && VPC=""
A=$(q ec2 describe-vpcs --filters Name=tag:Name,Values=cafe-vpc --query "Vpcs[].CidrBlock")
res 1-1 1 "VPC CIDR 10.10.0.0/16" "$(is "$(norm "$A")" "10.10.0.0/16")" "$A"

A=$(q ec2 describe-subnets --filters Name=vpc-id,Values=${VPC:-none} --query "Subnets[].[Tags[?Key=='Name']|[0].Value,CidrBlock,AvailabilityZone]" | tr -s '\t ' ' ' | sort)
E="cafe-app-a 10.10.10.0/24 ap-northeast-2a
cafe-app-c 10.10.11.0/24 ap-northeast-2c
cafe-db-a 10.10.20.0/24 ap-northeast-2a
cafe-db-c 10.10.21.0/24 ap-northeast-2c
cafe-pub-a 10.10.0.0/24 ap-northeast-2a
cafe-pub-c 10.10.1.0/24 ap-northeast-2c"
res 1-2 1.5 "서브넷 6개 이름/CIDR/AZ" "$(is "$A" "$E")" "$A"

A=$(q ec2 describe-route-tables --filters Name=vpc-id,Values=${VPC:-none} --query "RouteTables[].Tags[?Key=='Name'].Value")
res 1-3 1.5 "Route table 4개" "$(has_all "$A" cafe-pub-rt cafe-app-rt-a cafe-app-rt-c cafe-db-rt)" "$A"

PUBA=$(q ec2 describe-subnets --filters Name=tag:Name,Values=cafe-pub-a --query "Subnets[0].SubnetId")
PUBC=$(q ec2 describe-subnets --filters Name=tag:Name,Values=cafe-pub-c --query "Subnets[0].SubnetId")
A=$(q ec2 describe-nat-gateways --filter Name=vpc-id,Values=${VPC:-none} Name=state,Values=available --query "NatGateways[].SubnetId" | tr '\t' '\n' | sort | tr '\n' ' ')
E=$(printf '%s\n%s\n' "$PUBA" "$PUBC" | sort | tr '\n' ' ')
res 1-4 1.5 "AZ별 NAT Gateway (cafe-pub-a, cafe-pub-c)" "$(is "$A" "$E")" "$A"

RT=$(q ec2 describe-route-tables --filters Name=tag:Name,Values=cafe-db-rt --query "RouteTables[0].RouteTableId")
A=$(q ec2 describe-route-tables --filters Name=tag:Name,Values=cafe-db-rt --query "RouteTables[].Routes[?DestinationCidrBlock=='0.0.0.0/0'].DestinationCidrBlock")
OK=0; [ -n "$RT" ] && [ "$RT" != "None" ] && [ -z "$A" ] && OK=1
res 1-5 1.5 "DB route table 인터넷 경로 없음" "$OK" "rt=$RT default=${A:-없음}"

A=$(q ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=${VPC:-none} Name=service-name,Values=com.amazonaws.ap-northeast-2.secretsmanager --query "VpcEndpoints[].[VpcEndpointType,PrivateDnsEnabled]")
res 1-6 1.5 "Secrets Manager Interface endpoint + Private DNS" "$(is "$(norm "$A")" "Interface True")" "$A"

A=$(q ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=${VPC:-none} Name=service-name,Values=com.amazonaws.ap-northeast-2.s3 --query "VpcEndpoints[].VpcEndpointType")
res 1-7 0.5 "S3 Gateway endpoint" "$(has "$A" "Gateway")" "$A"

A=$(q ec2 describe-flow-logs --filter Name=resource-id,Values=${VPC:-none} --query "FlowLogs[].[LogDestinationType,LogGroupName]")
res 1-8 1.5 "Flow log → /cafe/vpc/flowlog" "$(is "$(norm "$A")" "cloud-watch-logs /cafe/vpc/flowlog")" "$A"

echo "## 2. Bastion"
BASTION=$(q ec2 describe-instances --filters Name=tag:Name,Values=cafe-bastion Name=instance-state-name,Values=running --query "Reservations[].Instances[].InstanceId")
A=$(q ec2 describe-addresses --filters Name=instance-id,Values=${BASTION:-none} --query "Addresses[].PublicIp")
res 2-1 1 "Bastion Elastic IP" "$(has "$A" '^[0-9.]+$')" "$A"

SGS=$(q ec2 describe-instances --instance-ids ${BASTION:-i-none} --query "Reservations[].Instances[].SecurityGroups[].GroupId")
A=$(q ec2 describe-security-groups --group-ids ${SGS:-sg-none} --query "SecurityGroups[].IpPermissions[?FromPort==\`2222\`].FromPort")
L=$(ss -tln 2>/dev/null | grep -c ':2222 ')
OK=0; [ -n "$A" ] && [ "$L" -ge 1 ] && OK=1
res 2-2 1.5 "SSH 2222 (SG 허용 + sshd 수신)" "$OK" "sg=${A:-없음} listen=$L"

A=$(q ec2 describe-instance-attribute --instance-id ${BASTION:-i-none} --attribute disableApiTermination --query "DisableApiTermination.Value")
res 2-3 1.5 "종료 방지" "$(is "$(norm "$A")" "True")" "$A"

echo "## 3. ECR"
T=$(q ecr describe-images --repository-name cafe-order --query "imageDetails[].imageTags[]")
OK=0; [ "$(has_all "$T" v1.0.0)" = 1 ] && ! printf '%s' "$T" | grep -qw latest && OK=1
res 3-1 1 "cafe-order 저장소 + v1.0.0 (latest 없음)" "$OK" "$T"
A=$(q ecr describe-repositories --repository-names cafe-order --query "repositories[].[imageTagMutability,imageScanningConfiguration.scanOnPush,encryptionConfiguration.encryptionType]")
set -- $A
res 3-2 1 "Tag immutable" "$(is "$1" IMMUTABLE)" "$1"
res 3-3 1 "Scan on push" "$(is "$2" True)" "$2"
res 3-4 1 "KMS 암호화" "$(is "$3" KMS)" "$3"

echo "## 4. ECS"
A=$(q ecs describe-clusters --clusters cafe-cluster --include SETTINGS --query "clusters[].settings[?name=='containerInsights'].value")
res 4-1 1.5 "Container Insights" "$(has "$A" '^(enabled|enhanced)$')" "$A"
A=$(q ecs describe-task-definition --task-definition cafe-order-td --query "taskDefinition.[cpu,memory,requiresCompatibilities[0]]")
res 4-2 1 "Task 0.5 vCPU / 1 GB / Fargate" "$(is "$(norm "$A")" "512 1024 FARGATE")" "$A"
S=$(q ecs describe-task-definition --task-definition cafe-order-td --query "taskDefinition.containerDefinitions[0].secrets[].name")
P=$(q ecs describe-task-definition --task-definition cafe-order-td --query "taskDefinition.containerDefinitions[0].environment[?name=='DB_PASSWORD'].name")
OK=0; [ "$(has_all "$S" DB_PASSWORD)" = 1 ] && [ -z "$P" ] && OK=1
res 4-3 2 "DB_PASSWORD를 secrets로 주입 (평문 없음)" "$OK" "secrets=$S env=${P:-없음}"
A=$(q ecs describe-services --cluster cafe-cluster --services cafe-order-svc --query "services[].[runningCount,networkConfiguration.awsvpcConfiguration.assignPublicIp,enableExecuteCommand]")
set -- $A
OK=0; [ "$1" = "2" ] && [ "$2" = "DISABLED" ] && OK=1
res 4-4 1.5 "Service running 2, 공인 IP 없음" "$OK" "running=$1 publicIp=$2"
res 4-5 1.5 "ECS Exec 활성화" "$(is "$3" True)" "$3"
A=$(q application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids service/cafe-cluster/cafe-order-svc --query "ScalableTargets[].[MinCapacity,MaxCapacity]")
B=$(q application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id service/cafe-cluster/cafe-order-svc --query "ScalingPolicies[].[PolicyType,TargetTrackingScalingPolicyConfiguration.TargetValue]")
OK=0; [ "$(norm "$A")" = "2 6" ] && [ "$(has "$B" 'TargetTrackingScaling[[:space:]]+60(\.0)?')" = 1 ] && OK=1
res 4-6 1.5 "Auto scaling Min2 Max6 CPU 60%" "$OK" "$A / $B"

echo "## 5. ALB"
ALB_ARN=$(q elbv2 describe-load-balancers --names cafe-alb --query "LoadBalancers[0].LoadBalancerArn")
ALB=$(q elbv2 describe-load-balancers --names cafe-alb --query "LoadBalancers[0].DNSName")
A=$(q elbv2 describe-load-balancers --names cafe-alb --query "LoadBalancers[].Scheme")
res 5-1 1 "internet-facing" "$(is "$A" internet-facing)" "$A"
A=$(q elbv2 describe-target-groups --names cafe-order-tg --query "TargetGroups[].[TargetType,HealthCheckPath]")
res 5-2 1.5 "Target group ip, /health" "$(is "$(norm "$A")" "ip /health")" "$A"
LIS=$(q elbv2 describe-listeners --load-balancer-arn ${ALB_ARN:-none} --query "Listeners[?Port==\`80\`].ListenerArn")
A=$(q elbv2 describe-rules --listener-arn ${LIS:-none} --query "Rules[?IsDefault].Actions[].FixedResponseConfig.[StatusCode,MessageBody]")
res 5-3 1.5 "Default action 404 not found" "$(is "$(norm "$A")" "404 not found")" "$A"
A=$(q elbv2 describe-rules --listener-arn ${LIS:-none} --query "Rules[].Conditions[].Values[]")
OK=0; printf '%s' "$A" | grep -Fq '/v1/*' && printf '%s' "$A" | grep -Fqw '/health' && OK=1
res 5-4 1 "경로 규칙 /v1/*, /health" "$OK" "$A"

echo "## 6. Aurora"
A=$(q rds describe-db-clusters --db-cluster-identifier cafe-db --query "DBClusters[].[Engine,Port,DeletionProtection]")
set -- $A
res 6-1 1 "Engine aurora-mysql" "$(is "$1" aurora-mysql)" "$1"
I=$(q rds describe-db-instances --filters Name=db-cluster-id,Values=cafe-db --query "DBInstances[].[DBInstanceClass,AvailabilityZone,PubliclyAccessible]")
N=$(printf '%s\n' "$I" | grep -c 'db.t3.medium')
Z=$(printf '%s\n' "$I" | awk 'NF{print $2}' | sort -u | wc -l)
OK=0; [ "$N" = 2 ] && [ "$Z" = 2 ] && ! printf '%s' "$I" | grep -q True && OK=1
res 6-2 1.5 "db.t3.medium 2대, 서로 다른 AZ, 비공개" "$OK" "$I"
res 6-3 1 "Port 3307" "$(is "$2" 3307)" "$2"
KEY=$(q rds describe-db-clusters --db-cluster-identifier cafe-db --query "DBClusters[0].KmsKeyId")
A=$(q kms list-aliases --key-id "${KEY:-none}" --query "Aliases[].AliasName")
res 6-4 1.5 "KMS alias/cafe-db-key" "$(has_all "$A" alias/cafe-db-key)" "$A"
res 6-5 1 "삭제 방지" "$(is "$3" True)" "$3"
A=$(q rds describe-db-clusters --db-cluster-identifier cafe-db --query "DBClusters[].EnabledCloudwatchLogsExports[]")
res 6-6 1 "로그 내보내기 error, slowquery" "$(has_all "$A" error slowquery)" "$A"

echo "## 7. Secrets Manager"
SKEY=$(q secretsmanager describe-secret --secret-id cafe/db-secret --query KmsKeyId)
A=$(q kms list-aliases --key-id "${SKEY:-none}" --query "Aliases[].AliasName")
res 7-1 1.5 "Secret CMK alias/cafe-secret-key" "$(has_all "$A" alias/cafe-secret-key)" "$A"
U=$(aws secretsmanager get-secret-value --secret-id cafe/db-secret --query SecretString --output text 2>/dev/null | jq -r '.username // empty' 2>/dev/null)
res 7-2 1.5 "앱 계정 cafeapp (admin 아님)" "$(is "$U" cafeapp)" "$U"

echo "## 8. Application"
R=$(curl -s -m 10 -X POST "http://$ALB/v1/orders" -H "Content-Type: application/json" -d '{"menu":"latte","qty":2}')
OID=$(printf '%s' "$R" | jq -r '.order_id // empty' 2>/dev/null)
res 8-1 1.5 "POST /v1/orders" "$(has "$OID" '^[0-9]+$')" "$R"
R=$(curl -s -m 10 "http://$ALB/v1/orders?order_id=$OID")
OK=0; [ "$(printf '%s' "$R" | jq -r '.menu' 2>/dev/null)" = latte ] && [ "$(printf '%s' "$R" | jq -r '.qty' 2>/dev/null)" = 2 ] && OK=1
res 8-2 1.5 "GET /v1/orders" "$OK" "$R"
C=$(curl -s -m 10 -o /dev/null -w "%{http_code}" "http://$ALB/admin")
res 8-3 1 "비정상 경로 /admin → 404" "$(is "$C" 404)" "$C"

echo "## 9. CloudWatch"
A=$(q logs describe-log-groups --log-group-name-prefix /cafe/ecs/order --query "logGroups[?logGroupName=='/cafe/ecs/order'].retentionInDays")
res 9-1 1 "로그 보관 14일" "$(is "$A" 14)" "$A"
A=$(q cloudwatch get-dashboard --dashboard-name cafe-dashboard --query DashboardBody | grep -oE "RequestCount|HTTPCode_Target_5XX_Count|CPUUtilization" | sort -u | tr '\n' ' ')
res 9-2 1.5 "Dashboard 위젯 3종" "$(has_all "$A" RequestCount HTTPCode_Target_5XX_Count CPUUtilization)" "$A"
A=$(q cloudwatch describe-alarms --alarm-names cafe-5xx-alarm --query "MetricAlarms[].[MetricName,Period,Statistic,Threshold,ComparisonOperator,AlarmActions[0]]")
OK=0; [ "$(has "$A" 'HTTPCode_Target_5XX_Count[[:space:]]+300[[:space:]]+Sum[[:space:]]+10(\.0)?[[:space:]]+GreaterThanOrEqualToThreshold[[:space:]]+arn:aws:sns:.*:cafe-alert$')" = 1 ] && OK=1
res 9-3 1 "Alarm 5분 합계 10 이상 → cafe-alert" "$OK" "$A"

echo "=================================================="
echo "TOTAL SCORE: $TOTAL / $MAX"
echo "=================================================="
