#!/usr/bin/env bash
set -u
export AWS_PAGER=""

BIBUNHO="${BIBUNHO:-}"
API_WRITE_CHECK="${API_WRITE_CHECK:-1}"

if [ -z "$BIBUNHO" ]; then
  echo "ERROR: BIBUNHO 환경 변수를 입력해야 합니다. 예: BIBUNHO=07 bash $0" >&2
  exit 2
fi

for CMD in aws jq curl awk; do
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $CMD" >&2
    exit 2
  fi
done

OUT_TXT="task1_check_result_${BIBUNHO}.txt"
exec > >(tee "$OUT_TXT") 2>&1

echo "== 제1과제 Solution Architecture 채점 출력 =="
echo "BIBUNHO=${BIBUNHO}"
echo "API_WRITE_CHECK=${API_WRITE_CHECK}"
echo

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
S3_BUCKET="skills-book-static-2026-${BIBUNHO}"

DIST_ID=""
if [ -n "$ACCOUNT_ID" ] && [ "$ACCOUNT_ID" != "None" ]; then
  for ID in $(aws cloudfront list-distributions --query 'DistributionList.Items[].Id' --output text 2>/dev/null || true); do
    [ -z "$ID" ] || [ "$ID" = "None" ] && continue
    ARN="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${ID}"
    NAME=$(aws cloudfront list-tags-for-resource --resource "$ARN" --query 'Tags.Items[?Key==`Name`].Value | [0]' --output text 2>/dev/null || true)
    HAS_BUCKET=$(aws cloudfront get-distribution-config --id "$ID" --query "contains(join(',', DistributionConfig.Origins.Items[].DomainName), '${S3_BUCKET}')" --output text 2>/dev/null || true)
    if [ "$NAME" = "skills-book-cloudfront" ] && [ "$HAS_BUCKET" = "True" ]; then
      DIST_ID="$ID"
      break
    fi
  done
fi

DIST_DOMAIN=""
if [ -n "$DIST_ID" ]; then
  DIST_DOMAIN=$(aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.DomainName' --output text 2>/dev/null || true)
fi

ALB_ARN=$(aws resourcegroupstaggingapi get-resources --region ap-northeast-2 --tag-filters Key=Name,Values=skills-book-alb --query 'ResourceTagMappingList[0].ResourceARN' --output text 2>/dev/null || true)
TG_ARN=$(aws resourcegroupstaggingapi get-resources --region ap-northeast-2 --tag-filters Key=Name,Values=skills-book-tg --query 'ResourceTagMappingList[0].ResourceARN' --output text 2>/dev/null || true)
REPO_ARN=$(aws resourcegroupstaggingapi get-resources --region ap-northeast-2 --tag-filters Key=Name,Values=skills-book-ecr --query 'ResourceTagMappingList[0].ResourceARN' --output text 2>/dev/null || true)
REPO_NAME=""
if [ -n "$REPO_ARN" ] && [ "$REPO_ARN" != "None" ]; then
  REPO_NAME="${REPO_ARN##*/}"
fi

CLUSTER_ARN=$(aws resourcegroupstaggingapi get-resources --region ap-northeast-2 --tag-filters Key=Name,Values=skills-book-cluster --query 'ResourceTagMappingList[0].ResourceARN' --output text 2>/dev/null || true)
SERVICE_ARN=$(aws resourcegroupstaggingapi get-resources --region ap-northeast-2 --tag-filters Key=Name,Values=skills-book-service --query 'ResourceTagMappingList[0].ResourceARN' --output text 2>/dev/null || true)
TASK_DEF=""
for TD in $(aws ecs list-task-definitions --region ap-northeast-2 --family-prefix skills-book-task --status ACTIVE --sort DESC --query 'taskDefinitionArns[]' --output text 2>/dev/null || true); do
  FAMILY=$(aws ecs describe-task-definition --region ap-northeast-2 --task-definition "$TD" --query 'taskDefinition.family' --output text 2>/dev/null || true)
  if [ "$FAMILY" = "skills-book-task" ]; then
    TASK_DEF="$TD"
    break
  fi
done

echo "[1-1] VPC 존재 확인 (1.0점)"
aws ec2 describe-vpcs --region ap-northeast-2 --filters Name=tag:Name,Values=skills-book-vpc --query 'Vpcs[].{Name:Tags[?Key==`Name`].Value|[0],VpcId:VpcId,Cidr:CidrBlock,State:State}' --output table

echo
echo "[1-2] Public/Private Subnet 구성 (1.0점)"
aws ec2 describe-subnets --region ap-northeast-2 --filters Name=tag:Name,Values=skills-book-public-a,skills-book-public-b,skills-book-private-a,skills-book-private-b --query 'Subnets[].{Name:Tags[?Key==`Name`].Value|[0],SubnetId:SubnetId,VpcId:VpcId,Cidr:CidrBlock,AZ:AvailabilityZone}' --output table

echo
echo "[1-3] Public Routing 구성 (1.0점)"
for SUBNET_ID in $(aws ec2 describe-subnets --region ap-northeast-2 --filters Name=tag:Name,Values=skills-book-public-a,skills-book-public-b --query 'Subnets[].SubnetId' --output text 2>/dev/null || true); do
  echo "subnet=${SUBNET_ID}"
  ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables --region ap-northeast-2 --filters Name=association.subnet-id,Values="$SUBNET_ID" --query 'RouteTables[].RouteTableId' --output text 2>/dev/null || true)
  if [ -z "$ROUTE_TABLE_IDS" ] || [ "$ROUTE_TABLE_IDS" = "None" ]; then
    VPC_ID=$(aws ec2 describe-subnets --region ap-northeast-2 --subnet-ids "$SUBNET_ID" --query 'Subnets[0].VpcId' --output text 2>/dev/null || true)
    ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables --region ap-northeast-2 --filters Name=vpc-id,Values="$VPC_ID" Name=association.main,Values=true --query 'RouteTables[].RouteTableId' --output text 2>/dev/null || true)
  fi
  for ROUTE_TABLE_ID in $ROUTE_TABLE_IDS; do
    echo "route_table=${ROUTE_TABLE_ID}"
    aws ec2 describe-route-tables --region ap-northeast-2 --route-table-ids "$ROUTE_TABLE_ID" --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0` && starts_with(GatewayId, `igw-`)].{GatewayId:GatewayId,State:State}' --output table
  done
done

echo
echo "[1-4] NAT Gateway 구성 (1.0점)"
aws ec2 describe-nat-gateways --region ap-northeast-2 --filter Name=tag:Name,Values=skills-book-natgw Name=state,Values=available --query 'NatGateways[].{NatGatewayId:NatGatewayId,State:State,SubnetId:SubnetId,VpcId:VpcId}' --output table

echo
echo "[1-5] DynamoDB VPC Endpoint 구성 (1.0점)"
aws ec2 describe-vpc-endpoints --region ap-northeast-2 --filters Name=tag:Name,Values=skills-book-ddb-vpce Name=vpc-endpoint-type,Values=Gateway Name=service-name,Values=com.amazonaws.ap-northeast-2.dynamodb --query 'VpcEndpoints[].{VpcEndpointId:VpcEndpointId,State:State,VpcId:VpcId,RouteTableIds:RouteTableIds,ServiceName:ServiceName}' --output table

echo
echo "[2-1] S3 정적 파일 배치 및 CloudFront 접근 (1.5점)"
echo "DIST_ID=${DIST_ID}"
echo "DIST_DOMAIN=${DIST_DOMAIN}"
aws s3api head-object --bucket "$S3_BUCKET" --key index.html
aws s3api head-object --bucket "$S3_BUCKET" --key main.jpeg
if [ -n "$DIST_DOMAIN" ] && [ "$DIST_DOMAIN" != "None" ]; then
  curl -s -o /dev/null -w 'index_http=%{http_code}\n' "https://${DIST_DOMAIN}/"
  curl -s -o /dev/null -w 'image_http=%{http_code}\n' "https://${DIST_DOMAIN}/main.jpeg"
else
  echo "CloudFront Distribution 식별 실패"
fi

echo
echo "[2-2] S3 Public Access 차단 (1.0점)"
aws s3api get-public-access-block --bucket "$S3_BUCKET" --query 'PublicAccessBlockConfiguration'
aws s3api get-bucket-tagging --bucket "$S3_BUCKET" --query 'TagSet[?Key==`Name`].Value | [0]' --output text
curl -s -o /dev/null -w 's3_direct_http=%{http_code}\n' "https://${S3_BUCKET}.s3.ap-northeast-2.amazonaws.com/index.html"

echo
echo "[2-3] CloudFront OAC 구성 (1.5점)"
if [ -n "$DIST_ID" ]; then
  aws cloudfront get-distribution-config --id "$DIST_ID" --query 'DistributionConfig.Origins.Items[].{Id:Id,DomainName:DomainName,OAC:OriginAccessControlId}' --output table
fi
aws s3api get-bucket-policy --bucket "$S3_BUCKET" --query Policy --output text

echo
echo "[2-4] CloudFront 단일 엔드포인트 및 라우팅 (1.0점)"
if [ -n "$DIST_ID" ]; then
  aws cloudfront get-distribution-config --id "$DIST_ID" --query 'DistributionConfig.{Default:DefaultCacheBehavior.TargetOriginId,Behaviors:CacheBehaviors.Items[].{Path:PathPattern,Origin:TargetOriginId,Methods:AllowedMethods.Items}}'
fi

echo
echo "[3-1] ALB 및 Target Group 구성 (1.5점)"
echo "ALB_ARN=${ALB_ARN}"
echo "TG_ARN=${TG_ARN}"
aws elbv2 describe-load-balancers --region ap-northeast-2 --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].{Scheme:Scheme,DNSName:DNSName,State:State.Code,Subnets:AvailabilityZones[].SubnetId}'
aws elbv2 describe-target-groups --region ap-northeast-2 --target-group-arns "$TG_ARN" --query 'TargetGroups[0].{TargetType:TargetType,Protocol:Protocol,Port:Port,HealthCheckPath:HealthCheckPath}'
aws elbv2 describe-target-health --region ap-northeast-2 --target-group-arn "$TG_ARN" --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}' --output table

echo
echo "[3-2] CloudFront Custom Header 구성 (1.0점)"
if [ -n "$DIST_ID" ]; then
  aws cloudfront get-distribution-config --id "$DIST_ID" --query 'DistributionConfig.Origins.Items[].{DomainName:DomainName,CustomHeaders:CustomHeaders.Items}'
fi

echo
echo "[3-3] ALB Header 기반 차단 (1.5점)"
HEADER_VALUE=""
if [ -n "$DIST_ID" ]; then
  HEADER_VALUE=$(aws cloudfront get-distribution-config --id "$DIST_ID" --query 'DistributionConfig.Origins.Items[].CustomHeaders.Items[?HeaderName==`X-Origin-Verify`].HeaderValue | [0]' --output text 2>/dev/null || true)
fi
ALB_DNS=$(aws elbv2 describe-load-balancers --region ap-northeast-2 --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || true)
echo "HEADER_LENGTH=${#HEADER_VALUE}"
echo "ALB_DNS=${ALB_DNS}"
if [ -n "$ALB_DNS" ] && [ "$ALB_DNS" != "None" ]; then
  curl -s -o /dev/null -w 'alb_direct_http=%{http_code}\n' "http://${ALB_DNS}/"
  curl -s -o /dev/null -w 'alb_header_health_http=%{http_code}\n' -H "X-Origin-Verify: ${HEADER_VALUE}" "http://${ALB_DNS}/health"
fi

echo
echo "[4-1] ECR Repository 및 Image 구성 (1.5점)"
echo "REPO_ARN=${REPO_ARN}"
echo "REPO_NAME=${REPO_NAME}"
aws ecr describe-images --region ap-northeast-2 --repository-name "$REPO_NAME" --query 'imageDetails[].{Digest:imageDigest,Tags:imageTags,PushedAt:imagePushedAt}' --output table

echo
echo "[4-2] ECS Task Definition 구성 (1.5점)"
echo "TASK_DEF=${TASK_DEF}"
aws ecs describe-task-definition --region ap-northeast-2 --task-definition "$TASK_DEF" --query 'taskDefinition.{Family:family,Compat:requiresCompatibilities,Network:networkMode,Cpu:cpu,Memory:memory,ExecutionRole:executionRoleArn,TaskRole:taskRoleArn,Container:containerDefinitions[0].name,Image:containerDefinitions[0].image,Port:containerDefinitions[0].portMappings[0].containerPort,Log:containerDefinitions[0].logConfiguration,Env:containerDefinitions[0].environment}'

echo
echo "[4-3] ECS Service 배포 구성 (1.5점)"
echo "CLUSTER_ARN=${CLUSTER_ARN}"
echo "SERVICE_ARN=${SERVICE_ARN}"
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets --region ap-northeast-2 --filters Name=tag:Name,Values=skills-book-private-a,skills-book-private-b --query 'Subnets[].SubnetId' --output text 2>/dev/null | awk '{for(i=1;i<=NF;i++) print $i}' | sort | paste -sd, -)
echo "PRIVATE_SUBNET_IDS=${PRIVATE_SUBNET_IDS}"
aws ecs describe-services --region ap-northeast-2 --cluster "$CLUSTER_ARN" --services "$SERVICE_ARN" --query 'services[0].{Status:status,Desired:desiredCount,Running:runningCount,TaskDefinition:taskDefinition,PublicIP:networkConfiguration.awsvpcConfiguration.assignPublicIp,Subnets:networkConfiguration.awsvpcConfiguration.subnets,LoadBalancers:loadBalancers}'

echo
echo "[4-4] Book API 정상 동작 (1.5점)"
if [ "$API_WRITE_CHECK" = "0" ]; then
  echo "API_WRITE_CHECK=0 이므로 POST 쓰기 검증을 건너뜁니다."
elif [ -z "$DIST_DOMAIN" ] || [ "$DIST_DOMAIN" = "None" ]; then
  echo "CloudFront Distribution Domain 식별 실패"
else
  TOKEN="judge-${BIBUNHO}-$(date +%s)-$RANDOM"
  BODY_FILE=$(mktemp)
  HTTP_CODE=$(curl -s -o "$BODY_FILE" -w '%{http_code}' -X POST "https://${DIST_DOMAIN}/v1/book" -H 'Content-Type: application/json' -d "{\"client_id\":\"${TOKEN}\",\"username\":\"Judge-${TOKEN}\",\"email\":\"${TOKEN}@example.com\",\"concert_name\":\"SkillsBook-${TOKEN}\"}" || true)
  BOOKING_ID=$(jq -r '.booking_id // empty' "$BODY_FILE" 2>/dev/null || true)
  echo "api_http=${HTTP_CODE}"
  echo "booking_id=${BOOKING_ID}"
  cat "$BODY_FILE"
  echo
  rm -f "$BODY_FILE"
  if [ -n "$BOOKING_ID" ]; then
    aws dynamodb get-item --region ap-northeast-2 --table-name skills-book-booking --key "{\"booking_id\":{\"S\":\"${BOOKING_ID}\"}}" --consistent-read
  fi
fi

echo
echo "[5-1] DynamoDB Table 구성 (1.0점)"
aws dynamodb describe-table --region ap-northeast-2 --table-name skills-book-booking --query 'Table.{Status:TableStatus,KeySchema:KeySchema,Attributes:AttributeDefinitions,SSE:SSEDescription}'

echo
echo "[5-2] DynamoDB KMS CMK 암호화 (1.5점)"
aws kms describe-key --region ap-northeast-2 --key-id alias/skills-book-ddb --query 'KeyMetadata.{Arn:Arn,Enabled:Enabled,KeyManager:KeyManager,KeyUsage:KeyUsage}' --output table
aws dynamodb describe-table --region ap-northeast-2 --table-name skills-book-booking --query 'Table.SSEDescription.KMSMasterKeyArn' --output text

echo
echo "[5-3] ECS Task Execution Role 연결 (1.0점)"
aws ecs describe-task-definition --region ap-northeast-2 --task-definition "$TASK_DEF" --query 'taskDefinition.executionRoleArn' --output text

echo
echo "[5-4] ECS Task Role 연결 (1.5점)"
aws ecs describe-task-definition --region ap-northeast-2 --task-definition "$TASK_DEF" --query 'taskDefinition.{ExecutionRole:executionRoleArn,TaskRole:taskRoleArn}'

echo
echo "[6-1] ECS Container Logs 구성 (1.5점)"
aws logs describe-log-groups --region ap-northeast-2 --log-group-name-prefix /ecs/skills-book-app --query 'logGroups[?logGroupName==`/ecs/skills-book-app`].{Name:logGroupName,Retention:retentionInDays}' --output table
aws logs describe-log-streams --region ap-northeast-2 --log-group-name /ecs/skills-book-app --log-stream-name-prefix book --query 'logStreams[].{Name:logStreamName,LastEvent:lastEventTimestamp}' --output table

echo
echo "[6-2] 4xx/5xx Metric Filter 구성 (1.5점)"
aws logs describe-metric-filters --region ap-northeast-2 --log-group-name /ecs/skills-book-app --query 'metricFilters[].{Name:filterName,Pattern:filterPattern,Metric:metricTransformations[0].metricName,Namespace:metricTransformations[0].metricNamespace,Value:metricTransformations[0].metricValue}' --output table

echo
echo "[6-3] CloudWatch Alarm 구성 (1.5점)"
aws cloudwatch describe-alarms --region ap-northeast-2 --alarm-names skills-book-4xx-alarm skills-book-5xx-alarm --query 'MetricAlarms[].{Name:AlarmName,Metric:MetricName,Namespace:Namespace,Statistic:Statistic,Threshold:Threshold,Operator:ComparisonOperator,Period:Period,Evaluation:EvaluationPeriods,Datapoints:DatapointsToAlarm,TreatMissingData:TreatMissingData}' --output table

echo
echo "[6-4] CloudWatch Alarm 세부 구성 (0.5점)"
aws cloudwatch describe-alarms --region ap-northeast-2 --alarm-names skills-book-4xx-alarm skills-book-5xx-alarm --query 'MetricAlarms[].{Name:AlarmName,TreatMissingData:TreatMissingData}' --output table

echo
echo "Result file: ${OUT_TXT}"
