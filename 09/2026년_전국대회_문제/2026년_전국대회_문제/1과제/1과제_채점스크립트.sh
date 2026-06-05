#!/bin/bash
# =============================================================================
# 2026년도 전국기능경기대회 클라우드컴퓨팅 1과제 채점 스크립트
# grade_task1.sh
# 사용법: bash grade_task1.sh <선수ID>
# =============================================================================

set -euo pipefail

# --- 색상 정의 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- 인자 확인 ---
if [ $# -lt 1 ]; then
  echo -e "${RED}[ERROR] 선수ID를 입력하세요.${NC}"
  echo "사용법: bash grade_task1.sh <선수ID>"
  exit 1
fi

PLAYER_ID="$1"
REGION="ap-northeast-2"
TOTAL_SCORE=0
MAX_SCORE=30

# --- 전역 변수 (채점 중 공유) ---
VPC_ID=""
ALB_DNS=""
CF_DOMAIN=""
TD=""
ALB_ARN=""
TG_ARN=""
TS=$(date +%s)

# =============================================================================
# 헬퍼 함수
# =============================================================================

pass() {
  local item="$1"
  local score="$2"
  local msg="${3:-}"
  echo -e "  ${GREEN}[PASS]${NC} ${item} (+${score}점)${msg:+ | $msg}"
  TOTAL_SCORE=$(echo "$TOTAL_SCORE + $score" | bc)
}

fail() {
  local item="$1"
  local msg="${2:-}"
  echo -e "  ${RED}[FAIL]${NC} ${item}${msg:+ | $msg}"
}

section() {
  echo ""
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}${BOLD}  $1${NC}"
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

info() {
  echo -e "  ${BLUE}[INFO]${NC} $1"
}

warn() {
  echo -e "  ${YELLOW}[WARN]${NC} $1"
}

# =============================================================================
# 사전 준비
# =============================================================================

section "사전 준비"

# IAM AccessKey 구성 여부 확인
info "IAM AccessKey 구성 여부 확인 중..."
CONFIGURED_KEY=$(aws configure get aws_access_key_id 2>/dev/null || true)
if [ -n "$CONFIGURED_KEY" ]; then
  warn "IAM AccessKey가 구성되어 있습니다. 채점 전 삭제 후 진행하세요."
  warn "  $ aws configure set aws_access_key_id ''"
  warn "  $ aws configure set aws_secret_access_key ''"
fi

# 리전 확인
CURRENT_REGION=$(aws configure get region 2>/dev/null || echo "not-set")
info "현재 리전: $CURRENT_REGION"
if [ "$CURRENT_REGION" != "$REGION" ]; then
  warn "리전이 ap-northeast-2(서울)이 아닙니다. 명령어에 --region $REGION 옵션이 적용됩니다."
fi

echo ""
echo -e "${BOLD}  선수ID: ${YELLOW}${PLAYER_ID}${NC}"
echo -e "${BOLD}  채점 시작: $(date '+%Y-%m-%d %H:%M:%S KST')${NC}"

# =============================================================================
# 1. 네트워크 (VPC/Subnet/IGW) — 4점
# =============================================================================

section "1. 네트워크 (VPC/Subnet/IGW) [배점: 4점]"

# 1-1: VPC 및 Public Subnet 확인 (1.5점)
echo -e "\n${BOLD}[1-1] VPC(10.0.0.0/16) 및 Public Subnet 2개(다른 AZ) 확인 (1.5점)${NC}"

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${PLAYER_ID}-vpc" "Name=cidr-block,Values=10.0.0.0/16" \
  --query "Vpcs[0].VpcId" --output text --region $REGION 2>/dev/null || echo "None")

if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  fail "1-1" "${PLAYER_ID}-vpc (10.0.0.0/16) VPC를 찾을 수 없습니다."
else
  info "VPC ID: $VPC_ID"
  SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=${PLAYER_ID}-public-subnet-*" "Name=vpc-id,Values=$VPC_ID" \
    --query "Subnets[*].AvailabilityZone" --output text --region $REGION 2>/dev/null || echo "")
  SUBNET_COUNT=$(echo "$SUBNETS" | wc -w | tr -d ' ')
  UNIQUE_AZ=$(echo "$SUBNETS" | tr '\t' '\n' | sort -u | wc -l | tr -d ' ')

  if [ "$SUBNET_COUNT" -ge 2 ] && [ "$UNIQUE_AZ" -ge 2 ]; then
    pass "1-1" "1.5" "VPC 1개, Subnet ${SUBNET_COUNT}개 (AZ: $SUBNETS)"
  else
    fail "1-1" "Subnet ${SUBNET_COUNT}개 / 서로 다른 AZ ${UNIQUE_AZ}개 (2개 이상 필요)"
  fi
fi

# 1-2: IGW 연결 및 0.0.0.0/0 라우팅 확인 (1.5점)
echo -e "\n${BOLD}[1-2] Internet Gateway 연결 및 0.0.0.0/0 → IGW 라우팅 확인 (1.5점)${NC}"

if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
  fail "1-2" "VPC_ID 없음 — 1-1 선행 필요"
else
  IGW_STATE=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query "InternetGateways[0].Attachments[0].State" --output text --region $REGION 2>/dev/null || echo "None")

  ROUTE_IGW=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "RouteTables[*].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId" \
    --output text --region $REGION 2>/dev/null | grep "igw-" || echo "")

  if [ "$IGW_STATE" = "available" ] && [ -n "$ROUTE_IGW" ]; then
    pass "1-2" "1.5" "IGW attached, 0.0.0.0/0 → $ROUTE_IGW"
  else
    fail "1-2" "IGW 상태: ${IGW_STATE}, 라우팅: ${ROUTE_IGW:-없음}"
  fi
fi

# 1-3: 리소스 명명 규칙 확인 (1점)
echo -e "\n${BOLD}[1-3] 리소스 이름에 선수ID 접두어 확인 (1점)${NC}"

VPC_NAME=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${PLAYER_ID}-*" \
  --query "Vpcs[0].Tags[?Key=='Name'].Value|[0]" --output text --region $REGION 2>/dev/null || echo "None")

IGW_NAME=$(aws ec2 describe-internet-gateways \
  --filters "Name=tag:Name,Values=${PLAYER_ID}-*" "Name=attachment.vpc-id,Values=${VPC_ID}" \
  --query "InternetGateways[0].Tags[?Key=='Name'].Value|[0]" --output text --region $REGION 2>/dev/null || echo "None")

RT_NAME=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=${PLAYER_ID}-*" "Name=vpc-id,Values=${VPC_ID}" \
  --query "RouteTables[0].Tags[?Key=='Name'].Value|[0]" --output text --region $REGION 2>/dev/null || echo "None")

NAME_OK=0
[ "$VPC_NAME" != "None" ] && [ -n "$VPC_NAME" ] && NAME_OK=$((NAME_OK+1))
[ "$IGW_NAME" != "None" ] && [ -n "$IGW_NAME" ] && NAME_OK=$((NAME_OK+1))
[ "$RT_NAME" != "None" ] && [ -n "$RT_NAME" ] && NAME_OK=$((NAME_OK+1))

if [ "$NAME_OK" -ge 3 ]; then
  pass "1-3" "1" "VPC: $VPC_NAME, IGW: $IGW_NAME, RT: $RT_NAME"
else
  fail "1-3" "선수ID 접두어 미적용 리소스 존재 (확인: VPC=$VPC_NAME, IGW=$IGW_NAME, RT=$RT_NAME)"
fi

# =============================================================================
# 2. 정적 웹 호스팅 (S3/CloudFront) — 4점
# =============================================================================

section "2. 정적 웹 호스팅 (S3/CloudFront) [배점: 4점]"

BUCKET="${PLAYER_ID}-static-site"

# 2-1: S3 파일 업로드 확인 (1.5점)
echo -e "\n${BOLD}[2-1] index.html, main.jpeg 버킷 업로드 확인 (1.5점)${NC}"

S3_LIST=$(aws s3 ls "s3://${BUCKET}/" --region $REGION 2>/dev/null || echo "")
HAS_INDEX=$(echo "$S3_LIST" | grep "index.html" | wc -l | tr -d ' ')
HAS_JPEG=$(echo "$S3_LIST" | grep "main.jpeg" | wc -l | tr -d ' ')

if [ "$HAS_INDEX" -ge 1 ] && [ "$HAS_JPEG" -ge 1 ]; then
  pass "2-1" "1.5" "index.html, main.jpeg 모두 존재"
else
  fail "2-1" "index.html=${HAS_INDEX}개, main.jpeg=${HAS_JPEG}개"
fi

# 2-2: Block Public Access 및 OAC/OAI 확인 (1점)
echo -e "\n${BOLD}[2-2] S3 퍼블릭 접근 차단(Block Public Access) 확인 (1점)${NC}"

BLOCK_PUBLIC=$(aws s3api get-public-access-block \
  --bucket "$BUCKET" \
  --query "PublicAccessBlockConfiguration.BlockPublicAcls" \
  --output text --region $REGION 2>/dev/null || echo "False")

if [ "$BLOCK_PUBLIC" = "True" ]; then
  pass "2-2" "1" "BlockPublicAcls=True"
else
  fail "2-2" "BlockPublicAcls=$BLOCK_PUBLIC (True 필요)"
fi

# 2-3: CloudFront URL HTTP 200 확인 (1점) + Distribution Deployed 상태 (0.5점)
echo -e "\n${BOLD}[2-3] CloudFront URL 접근 HTTP 200 확인 (1점) + Deployed 상태 (0.5점)${NC}"

CF_DOMAIN=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Origins.Items[?contains(DomainName,'${BUCKET}')]].DomainName|[0]" \
  --output text 2>/dev/null || echo "None")

if [ "$CF_DOMAIN" = "None" ] || [ -z "$CF_DOMAIN" ]; then
  fail "2-3" "CloudFront Distribution을 찾을 수 없습니다 (오리진: ${BUCKET})"
else
  info "CloudFront 도메인: $CF_DOMAIN"
  CF_STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${CF_DOMAIN}/" 2>/dev/null || echo "000")
  if [ "$CF_STATUS_CODE" = "200" ]; then
    pass "2-3 URL" "1" "https://${CF_DOMAIN}/ → HTTP $CF_STATUS_CODE"
  else
    fail "2-3 URL" "HTTP $CF_STATUS_CODE (200 필요)"
  fi

  # Distribution 상태 확인 (0.5점)
  DIST_ID=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Origins.Items[?contains(DomainName,'${BUCKET}')]].Id|[0]" \
    --output text 2>/dev/null || echo "None")
  DIST_STATUS=$(aws cloudfront get-distribution --id "$DIST_ID" \
    --query "Distribution.Status" --output text 2>/dev/null || echo "None")
  if [ "$DIST_STATUS" = "Deployed" ]; then
    pass "2-3 Deployed" "0.5" "Distribution 상태: $DIST_STATUS"
  else
    fail "2-3 Deployed" "Distribution 상태: $DIST_STATUS (Deployed 필요)"
  fi
fi

# =============================================================================
# 3. ECR — 2.5점
# =============================================================================

section "3. ECR (Elastic Container Registry) [배점: 2.5점]"

ECR_REPO="${PLAYER_ID}-book-ecr"

# 3-1: ECR Repository 생성 확인 (1점)
echo -e "\n${BOLD}[3-1] ECR 프라이빗 Repository 생성 확인 (1점)${NC}"

ECR_URI=$(aws ecr describe-repositories \
  --repository-names "$ECR_REPO" \
  --query "repositories[0].repositoryUri" --output text --region $REGION 2>/dev/null || echo "None")

if [ "$ECR_URI" != "None" ] && [ -n "$ECR_URI" ]; then
  pass "3-1" "1" "URI: $ECR_URI"
else
  fail "3-1" "ECR Repository ${ECR_REPO} 없음"
fi

# 3-2: latest 태그 이미지 (0.5점) + Linux/AMD64 (0.5점) + 기타 이미지 확인 (0.5점)
echo -e "\n${BOLD}[3-2] ECR latest 태그 이미지 확인 (0.5점) + Linux/AMD64 아키텍처 (0.5점)${NC}"

LATEST_IMAGE=$(aws ecr describe-images \
  --repository-name "$ECR_REPO" \
  --query "imageDetails[?imageTags[?@=='latest']].imageTags" \
  --output text --region $REGION 2>/dev/null || echo "")

if echo "$LATEST_IMAGE" | grep -q "latest"; then
  pass "3-2 latest" "0.5" "latest 태그 이미지 존재"
else
  fail "3-2 latest" "latest 태그 이미지 없음"
fi

# Task Definition에서 아키텍처 확인 (ECS 채점 후 활용 가능하도록 여기서도 확인)
TD_TMP=$(aws ecs describe-services \
  --cluster "${PLAYER_ID}-book-cluster" \
  --services "${PLAYER_ID}-book-service" \
  --query "services[0].taskDefinition" --output text --region $REGION 2>/dev/null || echo "None")

if [ "$TD_TMP" != "None" ] && [ -n "$TD_TMP" ]; then
  CPU_ARCH=$(aws ecs describe-task-definition \
    --task-definition "$TD_TMP" \
    --query "taskDefinition.runtimePlatform.cpuArchitecture" \
    --output text --region $REGION 2>/dev/null || echo "None")
  if [ "$CPU_ARCH" = "X86_64" ]; then
    pass "3-2 AMD64" "0.5" "cpuArchitecture: X86_64"
  else
    fail "3-2 AMD64" "cpuArchitecture: ${CPU_ARCH} (X86_64 필요)"
  fi
else
  warn "3-2 AMD64: Task Definition 조회 불가 — 4번 항목 채점 후 확인 가능"
fi

# =============================================================================
# 4. ECS/Fargate — 5.5점
# =============================================================================

section "4. ECS/Fargate [배점: 5.5점]"

ECS_CLUSTER="${PLAYER_ID}-book-cluster"
ECS_SERVICE="${PLAYER_ID}-book-service"

# 4-1: ECS Cluster ACTIVE 및 Task Running 확인 (1점)
echo -e "\n${BOLD}[4-1] ECS Cluster ACTIVE 및 Task Running 확인 (1점)${NC}"
info "※ ECS Task가 Running 상태가 될 때까지 최대 3분 대기합니다."

CLUSTER_STATUS=$(aws ecs describe-clusters \
  --clusters "$ECS_CLUSTER" \
  --query "clusters[0].status" --output text --region $REGION 2>/dev/null || echo "None")

RUNNING_COUNT=0
for i in 1 2 3; do
  RUNNING_COUNT=$(aws ecs list-tasks \
    --cluster "$ECS_CLUSTER" --desired-status RUNNING \
    --query "length(taskArns)" --output text --region $REGION 2>/dev/null || echo "0")
  [ "$RUNNING_COUNT" -ge 1 ] && break
  [ $i -lt 3 ] && info "Task Running 대기 중... (${i}/3, 60초 후 재시도)" && sleep 60
done

if [ "$CLUSTER_STATUS" = "ACTIVE" ] && [ "$RUNNING_COUNT" -ge 1 ]; then
  pass "4-1" "1" "Cluster: $CLUSTER_STATUS, Running Tasks: $RUNNING_COUNT"
else
  fail "4-1" "Cluster: $CLUSTER_STATUS, Running Tasks: $RUNNING_COUNT"
fi

# Task Definition ARN 저장
TD=$(aws ecs describe-services \
  --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
  --query "services[0].taskDefinition" --output text --region $REGION 2>/dev/null || echo "None")
info "Task Definition: $TD"

# 4-2: 컨테이너 포트 8080 매핑 확인 (1.5점)
echo -e "\n${BOLD}[4-2] Task Definition 컨테이너 포트 8080 매핑 확인 (1.5점)${NC}"

if [ "$TD" = "None" ] || [ -z "$TD" ]; then
  fail "4-2" "Task Definition 조회 불가"
else
  PORT_CHECK=$(aws ecs describe-task-definition \
    --task-definition "$TD" \
    --query "taskDefinition.containerDefinitions[*].portMappings[?containerPort==\`8080\`].containerPort" \
    --output text --region $REGION 2>/dev/null || echo "")
  if echo "$PORT_CHECK" | grep -q "8080"; then
    pass "4-2" "1.5" "containerPort: 8080 확인"
  else
    fail "4-2" "containerPort 8080 없음 (현재: $PORT_CHECK)"
  fi
fi

# 4-3: 환경변수 AWS_REGION, TABLE_NAME 확인 (1점)
echo -e "\n${BOLD}[4-3] 환경변수 AWS_REGION, TABLE_NAME 설정 확인 (1점)${NC}"

if [ "$TD" = "None" ] || [ -z "$TD" ]; then
  fail "4-3" "Task Definition 조회 불가"
else
  ENV_VARS=$(aws ecs describe-task-definition \
    --task-definition "$TD" \
    --query "taskDefinition.containerDefinitions[*].environment" \
    --output json --region $REGION 2>/dev/null || echo "[]")

  HAS_REGION=$(echo "$ENV_VARS" | grep -c '"AWS_REGION"' || true)
  HAS_TABLE=$(echo "$ENV_VARS" | grep -c '"TABLE_NAME"' || true)
  REGION_VAL=$(echo "$ENV_VARS" | python3 -c "import sys,json; envs=json.load(sys.stdin); [print(e['value']) for lst in envs for e in lst if e['name']=='AWS_REGION']" 2>/dev/null | head -1 || echo "")
  TABLE_VAL=$(echo "$ENV_VARS" | python3 -c "import sys,json; envs=json.load(sys.stdin); [print(e['value']) for lst in envs for e in lst if e['name']=='TABLE_NAME']" 2>/dev/null | head -1 || echo "")

  if [ "$HAS_REGION" -ge 1 ] && [ "$HAS_TABLE" -ge 1 ] \
    && [ "$REGION_VAL" = "ap-northeast-2" ] \
    && [ "$TABLE_VAL" = "${PLAYER_ID}-booking-table" ]; then
    pass "4-3" "1" "AWS_REGION=$REGION_VAL, TABLE_NAME=$TABLE_VAL"
  else
    fail "4-3" "AWS_REGION='${REGION_VAL}', TABLE_NAME='${TABLE_VAL}'"
  fi
fi

# 4-4: IAM Role 및 CPU/Memory 확인 (1점)
echo -e "\n${BOLD}[4-4] Task Execution Role / Task Role 및 CPU=256, Memory=512 확인 (1점)${NC}"

if [ "$TD" = "None" ] || [ -z "$TD" ]; then
  fail "4-4" "Task Definition 조회 불가"
else
  EXEC_ROLE=$(aws ecs describe-task-definition \
    --task-definition "$TD" \
    --query "taskDefinition.executionRoleArn" --output text --region $REGION 2>/dev/null || echo "None")
  TASK_ROLE=$(aws ecs describe-task-definition \
    --task-definition "$TD" \
    --query "taskDefinition.taskRoleArn" --output text --region $REGION 2>/dev/null || echo "None")

  if [ "$EXEC_ROLE" != "None" ] && [ -n "$EXEC_ROLE" ] \
    && [ "$TASK_ROLE" != "None" ] && [ -n "$TASK_ROLE" ]; then
    pass "4-4 Role" "0.5" "ExecutionRole: $(basename $EXEC_ROLE), TaskRole: $(basename $TASK_ROLE)"
  else
    fail "4-4 Role" "ExecutionRole: $EXEC_ROLE, TaskRole: $TASK_ROLE"
  fi

  CPU_VAL=$(aws ecs describe-task-definition \
    --task-definition "$TD" \
    --query "taskDefinition.cpu" --output text --region $REGION 2>/dev/null || echo "")
  MEM_VAL=$(aws ecs describe-task-definition \
    --task-definition "$TD" \
    --query "taskDefinition.memory" --output text --region $REGION 2>/dev/null || echo "")

  if [ "$CPU_VAL" = "256" ] && [ "$MEM_VAL" = "512" ]; then
    pass "4-4 CPU/MEM" "0.5" "CPU=$CPU_VAL, Memory=$MEM_VAL"
  else
    fail "4-4 CPU/MEM" "CPU=$CPU_VAL (256 필요), Memory=$MEM_VAL (512 필요)"
  fi
fi

# 4-5: GET /health → HTTP 200 확인 (1점)
echo -e "\n${BOLD}[4-5] ALB DNS를 통해 GET /health HTTP 200 확인 (1점)${NC}"

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names "${PLAYER_ID}-book-alb" \
  --query "LoadBalancers[0].DNSName" --output text --region $REGION 2>/dev/null || echo "None")

if [ "$ALB_DNS" = "None" ] || [ -z "$ALB_DNS" ]; then
  fail "4-5" "ALB ${PLAYER_ID}-book-alb 조회 불가"
else
  HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${ALB_DNS}/health" 2>/dev/null || echo "000")
  if [ "$HEALTH_CODE" = "200" ]; then
    pass "4-5" "1" "GET /health → HTTP $HEALTH_CODE"
  else
    fail "4-5" "GET /health → HTTP $HEALTH_CODE (200 필요)"
  fi
fi

# =============================================================================
# 5. ALB — 3점
# =============================================================================

section "5. ALB (Application Load Balancer) [배점: 3점]"

ALB_NAME="${PLAYER_ID}-book-alb"

# 5-1: ALB internet-facing 및 active 확인 (1점)
echo -e "\n${BOLD}[5-1] ALB internet-facing, active 확인 (1점)${NC}"

ALB_INFO=$(aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --query "LoadBalancers[0].{Scheme:Scheme,State:State.Code}" \
  --output json --region $REGION 2>/dev/null || echo "{}")

ALB_SCHEME=$(echo "$ALB_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Scheme',''))" 2>/dev/null || echo "")
ALB_STATE=$(echo "$ALB_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('State',''))" 2>/dev/null || echo "")

if [ "$ALB_SCHEME" = "internet-facing" ] && [ "$ALB_STATE" = "active" ]; then
  pass "5-1" "1" "Scheme: $ALB_SCHEME, State: $ALB_STATE"
else
  fail "5-1" "Scheme: $ALB_SCHEME, State: $ALB_STATE"
fi

# 5-2: Listener HTTP:80 및 Target Group HTTP:8080 (IP) 확인 (1점)
echo -e "\n${BOLD}[5-2] Listener HTTP:80 및 TG HTTP:8080 (Target Type: IP) 확인 (1점)${NC}"

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text --region $REGION 2>/dev/null || echo "None")

if [ "$ALB_ARN" = "None" ] || [ -z "$ALB_ARN" ]; then
  fail "5-2" "ALB ARN 조회 불가"
else
  LISTENER_PORT=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --query "Listeners[?Port==\`80\`].Port" --output text --region $REGION 2>/dev/null || echo "")
  TG_INFO=$(aws elbv2 describe-target-groups \
    --load-balancer-arn "$ALB_ARN" \
    --query "TargetGroups[?Port==\`8080\` && TargetType=='ip'].{Port:Port,Type:TargetType}" \
    --output json --region $REGION 2>/dev/null || echo "[]")

  HAS_LISTENER=$(echo "$LISTENER_PORT" | grep -c "80" || true)
  HAS_TG=$(echo "$TG_INFO" | grep -c "8080" || true)

  if [ "$HAS_LISTENER" -ge 1 ] && [ "$HAS_TG" -ge 1 ]; then
    pass "5-2" "1" "Listener HTTP:80 확인, TG HTTP:8080(ip) 확인"
  else
    fail "5-2" "Listener:80 ${HAS_LISTENER}개, TG:8080(ip) ${HAS_TG}개"
  fi
fi

# TG_ARN 저장 (6-2에서 사용)
TG_ARN=$(aws elbv2 describe-target-groups \
  --load-balancer-arn "$ALB_ARN" \
  --query "TargetGroups[0].TargetGroupArn" --output text --region $REGION 2>/dev/null || echo "None")

# 5-3: 보안그룹 규칙 확인 (1점)
echo -e "\n${BOLD}[5-3] ALB SG(인바운드 HTTP:80) 및 ECS SG(인바운드 TCP:8080 소스=ALB SG) 확인 (1점)${NC}"

ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PLAYER_ID}-alb-sg" \
  --query "SecurityGroups[0].GroupId" --output text --region $REGION 2>/dev/null || echo "None")

ECS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PLAYER_ID}-ecs-sg" \
  --query "SecurityGroups[0].GroupId" --output text --region $REGION 2>/dev/null || echo "None")

ALB_SG_80=$(aws ec2 describe-security-groups \
  --group-ids "$ALB_SG_ID" \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`80\`].IpRanges[?CidrIp=='0.0.0.0/0'].CidrIp" \
  --output text --region $REGION 2>/dev/null || echo "")

ECS_SG_8080_SRC=$(aws ec2 describe-security-groups \
  --group-ids "$ECS_SG_ID" \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`8080\`].UserIdGroupPairs[0].GroupId" \
  --output text --region $REGION 2>/dev/null || echo "")

ALB_OK=$(echo "$ALB_SG_80" | grep -c "0.0.0.0/0" || true)
ECS_OK=0
[ "$ECS_SG_8080_SRC" = "$ALB_SG_ID" ] && ECS_OK=1

if [ "$ALB_OK" -ge 1 ] && [ "$ECS_OK" -eq 1 ]; then
  pass "5-3" "1" "ALB SG: HTTP:80/0.0.0.0/0, ECS SG: TCP:8080 소스=$ALB_SG_ID"
else
  fail "5-3" "ALB SG 80포트: ${ALB_OK}개 / ECS SG 8080 소스 ALB SG 매칭: ${ECS_OK}"
fi

# 5-4: Target Health 확인 (0.5점)
echo -e "\n${BOLD}[5-4] Target Group Health Healthy 확인 (0.5점)${NC}"

if [ "$TG_ARN" != "None" ] && [ -n "$TG_ARN" ]; then
  HEALTHY_COUNT=$(aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --query "TargetHealthDescriptions[?TargetHealth.State=='healthy'].TargetHealth.State" \
    --output text --region $REGION 2>/dev/null | wc -w | tr -d ' ')
  if [ "$HEALTHY_COUNT" -ge 1 ]; then
    pass "5-4" "0.5" "Healthy 대상: $HEALTHY_COUNT개"
  else
    fail "5-4" "Healthy 대상 없음 (현재: $HEALTHY_COUNT개)"
  fi
else
  fail "5-4" "Target Group ARN 조회 불가"
fi

# =============================================================================
# 6. DynamoDB — 4점
# =============================================================================

section "6. DynamoDB [배점: 4점]"

TABLE_NAME="${PLAYER_ID}-booking-table"

# 6-1: 테이블 ACTIVE, PK=client_id, BillingMode 확인 (1점)
echo -e "\n${BOLD}[6-1] DynamoDB 테이블 ACTIVE / PK:client_id(S) / BillingMode 확인 (1점)${NC}"

TABLE_STATUS=$(aws dynamodb describe-table \
  --table-name "$TABLE_NAME" \
  --query "Table.TableStatus" --output text --region $REGION 2>/dev/null || echo "None")
TABLE_PK=$(aws dynamodb describe-table \
  --table-name "$TABLE_NAME" \
  --query "Table.KeySchema[?KeyType=='HASH'].AttributeName|[0]" \
  --output text --region $REGION 2>/dev/null || echo "None")
TABLE_BILLING=$(aws dynamodb describe-table \
  --table-name "$TABLE_NAME" \
  --query "Table.BillingModeSummary.BillingMode" \
  --output text --region $REGION 2>/dev/null || echo "PROVISIONED")

if [ "$TABLE_STATUS" = "ACTIVE" ] && [ "$TABLE_PK" = "client_id" ]; then
  pass "6-1" "1" "Status:$TABLE_STATUS, PK:$TABLE_PK, Billing:$TABLE_BILLING"
else
  fail "6-1" "Status:$TABLE_STATUS (ACTIVE 필요), PK:$TABLE_PK (client_id 필요)"
fi

# 6-2: POST /v1/book 호출 및 DynamoDB 저장 확인 (1.5점)
# ※ 신버전 문제지: 사용자는 ALB DNS 직접 호출 금지 → CloudFront 경유 호출
echo -e "\n${BOLD}[6-2] POST /v1/book → booking_id 응답 및 DynamoDB 저장 확인 (1.5점)${NC}"
info "타임스탬프 기반 client_id 사용: chk-${PLAYER_ID}-${TS}"
info "※ 신버전 아키텍처: CloudFront 도메인 경유 호출 (ALB DNS 직접 호출 금지)"

# CF 도메인 재확인 (독립 실행 보장)
if [ -z "$CF_DOMAIN" ] || [ "$CF_DOMAIN" = "None" ]; then
  CF_DOMAIN=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Origins.Items[?contains(DomainName,'${PLAYER_ID}-static-site')]].DomainName|[0]" \
    --output text 2>/dev/null || echo "None")
fi

if [ "$CF_DOMAIN" = "None" ] || [ -z "$CF_DOMAIN" ]; then
  fail "6-2" "CloudFront 도메인 조회 불가 — 2번 항목 채점 확인 필요"
else
  info "호출 엔드포인트: https://${CF_DOMAIN}/v1/book"
  POST_RESP=$(curl -s -X POST "https://${CF_DOMAIN}/v1/book" \
    -H "Content-Type: application/json" \
    -d "{\"client_id\":\"chk-${PLAYER_ID}-${TS}\",\"username\":\"채점자\",\"email\":\"chk@test.com\",\"concert_name\":\"Seoul2026\"}" \
    2>/dev/null || echo "")
  info "POST 응답: $POST_RESP"

  HAS_BOOKING_ID=$(echo "$POST_RESP" | grep -c "booking_id" || true)
  DB_ITEM=$(aws dynamodb get-item \
    --table-name "$TABLE_NAME" \
    --key "{\"client_id\":{\"S\":\"chk-${PLAYER_ID}-${TS}\"}}" \
    --output json --region $REGION 2>/dev/null || echo "{}")

  HAS_DB_ITEM=$(echo "$DB_ITEM" | grep -c "client_id" || true)

  if [ "$HAS_BOOKING_ID" -ge 1 ] && [ "$HAS_DB_ITEM" -ge 1 ]; then
    pass "6-2" "1.5" "booking_id 응답 확인, DynamoDB 항목 저장 확인 (CF 경유)"
  else
    fail "6-2" "booking_id 응답: ${HAS_BOOKING_ID}개, DynamoDB 저장: ${HAS_DB_ITEM}개"
  fi
fi

# 6-3: DynamoDB 6개 속성 정합성 확인 (1.5점)
echo -e "\n${BOLD}[6-3] DynamoDB 저장 데이터 6개 속성 정합성 확인 (1.5점)${NC}"
echo -e "  (client_id, booking_id, username, email, concert_name, created_at)"

DB_ITEM_DATA=$(aws dynamodb get-item \
  --table-name "$TABLE_NAME" \
  --key "{\"client_id\":{\"S\":\"chk-${PLAYER_ID}-${TS}\"}}" \
  --query "Item" --output json --region $REGION 2>/dev/null || echo "null")

ATTRS=("client_id" "booking_id" "username" "email" "concert_name" "created_at")
ALL_OK=1
for attr in "${ATTRS[@]}"; do
  if ! echo "$DB_ITEM_DATA" | grep -q "\"$attr\""; then
    fail "6-3" "속성 누락: $attr"
    ALL_OK=0
  fi
done
if [ "$ALL_OK" -eq 1 ]; then
  pass "6-3" "1.5" "6개 속성 모두 존재"
fi

# =============================================================================
# 7. CloudWatch Logs — 4점
# =============================================================================

section "7. CloudWatch Logs [배점: 4점]"

LOG_GROUP="/skillskorea/ecs/app"

# 7-1: 로그 그룹 생성 확인 (1점)
echo -e "\n${BOLD}[7-1] 로그 그룹 ${LOG_GROUP} 생성 확인 (1점)${NC}"

LG_NAME=$(aws logs describe-log-groups \
  --log-group-name-prefix "$LOG_GROUP" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName|[0]" \
  --output text --region $REGION 2>/dev/null || echo "None")

if [ "$LG_NAME" = "$LOG_GROUP" ]; then
  pass "7-1" "1" "로그 그룹: $LG_NAME"
else
  fail "7-1" "로그 그룹 ${LOG_GROUP} 없음"
fi

# 7-2: ecs/ 접두어 로그 스트림 자동 생성 확인 (1점)
echo -e "\n${BOLD}[7-2] Task 단위 로그 스트림(ecs/ 접두어) 자동 생성 확인 (1점)${NC}"

STREAM_COUNT=$(aws logs describe-log-streams \
  --log-group-name "$LOG_GROUP" \
  --query "length(logStreams[?starts_with(logStreamName,'ecs/')])" \
  --output text --region $REGION 2>/dev/null || echo "0")

if [ "$STREAM_COUNT" -ge 1 ] 2>/dev/null; then
  pass "7-2" "1" "ecs/ 접두어 스트림 ${STREAM_COUNT}개 존재"
else
  fail "7-2" "ecs/ 접두어 스트림 없음"
fi

# 7-3: 애플리케이션 요청 로그 수집 확인 (1점)
echo -e "\n${BOLD}[7-3] 애플리케이션 요청 로그(method) CloudWatch 수집 확인 (1점)${NC}"
info "※ 최대 3분 소요될 수 있습니다."

START_TIME=$(( ($(date +%s) - 3600) * 1000 ))
LOG_EVENT_COUNT=0

for i in 1 2 3; do
  LOG_EVENT_COUNT=$(aws logs filter-log-events \
    --log-group-name "$LOG_GROUP" \
    --filter-pattern "method" \
    --start-time "$START_TIME" \
    --query "length(events)" --output text --region $REGION 2>/dev/null || echo "0")
  [ "$LOG_EVENT_COUNT" -ge 1 ] 2>/dev/null && break
  [ $i -lt 3 ] && info "로그 수집 대기 중... (${i}/3, 60초 후 재시도)" && sleep 60
done

if [ "$LOG_EVENT_COUNT" -ge 1 ] 2>/dev/null; then
  pass "7-3" "1" "로그 이벤트 ${LOG_EVENT_COUNT}건 수집 확인"
else
  fail "7-3" "method 패턴 로그 없음"
fi

# 7-4: awslogs 드라이버 및 로그 그룹 설정 확인 (1점)
echo -e "\n${BOLD}[7-4] Task Definition logConfiguration awslogs 드라이버 설정 확인 (1점)${NC}"

if [ "$TD" = "None" ] || [ -z "$TD" ]; then
  fail "7-4" "Task Definition 조회 불가"
else
  LOG_CONFIG=$(aws ecs describe-task-definition \
    --task-definition "$TD" \
    --query "taskDefinition.containerDefinitions[0].logConfiguration" \
    --output json --region $REGION 2>/dev/null || echo "{}")

  HAS_AWSLOGS=$(echo "$LOG_CONFIG" | grep -c '"awslogs"' || true)
  HAS_LOG_GROUP=$(echo "$LOG_CONFIG" | grep -c '/skillskorea/ecs/app' || true)

  if [ "$HAS_AWSLOGS" -ge 1 ] && [ "$HAS_LOG_GROUP" -ge 1 ]; then
    pass "7-4" "1" "logDriver:awslogs, awslogs-group:${LOG_GROUP}"
  else
    fail "7-4" "logDriver 또는 awslogs-group 설정 불일치 (현재: $LOG_CONFIG)"
  fi
fi

# =============================================================================
# 8. 종합 동작 확인 — 3점
# =============================================================================

section "8. 종합 동작 확인 [배점: 3점]"

# 8-1: CF→/(200), CF→/health(200), CF→POST /v1/book 연계 최종 확인 (1.5점)
# ※ 신버전 아키텍처: 모든 경로(정적+API)를 CloudFront 경유로 확인
echo -e "\n${BOLD}[8-1] 전체 연계 동작 최종 확인 — CloudFront 경유 (1.5점)${NC}"
echo -e "  CF→/(정적), CF→/health(API), CF→POST /v1/book(DynamoDB 연동)"

# CF 도메인 재확인
if [ -z "$CF_DOMAIN" ] || [ "$CF_DOMAIN" = "None" ]; then
  CF_DOMAIN=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Origins.Items[?contains(DomainName,'${PLAYER_ID}-static-site')]].DomainName|[0]" \
    --output text 2>/dev/null || echo "None")
fi

CF_STATIC_CODE="000"
CF_HEALTH_CODE="000"
CF_BOOK_CODE="000"

if [ -n "$CF_DOMAIN" ] && [ "$CF_DOMAIN" != "None" ]; then
  # 정적 웹 (S3 오리진)
  CF_STATIC_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${CF_DOMAIN}/" 2>/dev/null || echo "000")
  # /health (ALB 오리진)
  CF_HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${CF_DOMAIN}/health" 2>/dev/null || echo "000")
  # POST /v1/book (ALB 오리진 → DynamoDB)
  CF_BOOK_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "https://${CF_DOMAIN}/v1/book" \
    -H "Content-Type: application/json" \
    -d "{\"client_id\":\"chk-8-1-${PLAYER_ID}-${TS}\",\"username\":\"채점자\",\"email\":\"chk@test.com\",\"concert_name\":\"Seoul2026\"}" \
    2>/dev/null || echo "000")
fi

info "CF /        (정적) : HTTP $CF_STATIC_CODE"
info "CF /health  (ALB)  : HTTP $CF_HEALTH_CODE"
info "CF /v1/book (ALB)  : HTTP $CF_BOOK_CODE"

if [ "$CF_STATIC_CODE" = "200" ] && [ "$CF_HEALTH_CODE" = "200" ] && [ "$CF_BOOK_CODE" = "200" ]; then
  pass "8-1" "1.5" "CF 정적:$CF_STATIC_CODE, CF /health:$CF_HEALTH_CODE, CF /v1/book:$CF_BOOK_CODE"
else
  fail "8-1" "CF/:$CF_STATIC_CODE, CF/health:$CF_HEALTH_CODE, CF/v1/book:$CF_BOOK_CODE (모두 200 필요)"
fi

# 8-2: 불필요 리소스 미존재 확인 (1.5점)
echo -e "\n${BOLD}[8-2] 불필요 리소스 미존재 확인 (1.5점)${NC}"
info "※ IaC(Terraform, CDK 등) 사용 확인 시 0점 처리됩니다."

EXTRA_ALB=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?LoadBalancerName!='${PLAYER_ID}-book-alb'].LoadBalancerName" \
  --output text --region $REGION 2>/dev/null | tr '\t' '\n' | grep -v "^$" || echo "")

EXTRA_EC2=$(aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[*].Instances[*].InstanceId" \
  --output text --region $REGION 2>/dev/null | tr '\t' '\n' | grep -v "^$" || echo "")

EXTRA_VPC=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=false" \
  --query "Vpcs[?CidrBlock!='10.0.0.0/16'].VpcId" \
  --output text --region $REGION 2>/dev/null | tr '\t' '\n' | grep -v "^$" || echo "")

ISSUES=""
[ -n "$EXTRA_ALB" ] && ISSUES="${ISSUES}미사용 ALB: $EXTRA_ALB; "
[ -n "$EXTRA_EC2" ] && ISSUES="${ISSUES}EC2 인스턴스: $EXTRA_EC2; "
[ -n "$EXTRA_VPC" ] && ISSUES="${ISSUES}불필요 VPC: $EXTRA_VPC; "

if [ -z "$ISSUES" ]; then
  pass "8-2" "1.5" "불필요 리소스 없음"
else
  fail "8-2" "$ISSUES"
fi

# =============================================================================
# 최종 결과
# =============================================================================

section "채점 결과 요약"

echo ""
echo -e "${BOLD}  선수ID   : ${YELLOW}${PLAYER_ID}${NC}"
echo -e "${BOLD}  채점 일시: $(date '+%Y-%m-%d %H:%M:%S KST')${NC}"
echo ""
echo -e "  ┌─────────────────────────────────────────────┐"
echo -e "  │  항목                          배점   득점  │"
echo -e "  ├─────────────────────────────────────────────┤"
echo -e "  │  1. 네트워크 (VPC/Subnet/IGW)    4          │"
echo -e "  │  2. 정적 웹 호스팅 (S3/CF)       4          │"
echo -e "  │  3. ECR                          2.5        │"
echo -e "  │  4. ECS/Fargate                  5.5        │"
echo -e "  │  5. ALB                          3          │"
echo -e "  │  6. DynamoDB                     4          │"
echo -e "  │  7. CloudWatch Logs              4          │"
echo -e "  │  8. 종합 동작 확인               3          │"
echo -e "  ├─────────────────────────────────────────────┤"
printf   "  │  %-30s  %2s / %2s      │\n" "합계" "$TOTAL_SCORE" "$MAX_SCORE"
echo -e "  └─────────────────────────────────────────────┘"
echo ""

if (( $(echo "$TOTAL_SCORE >= 27" | bc -l) )); then
  echo -e "  ${GREEN}${BOLD}우수${NC}"
elif (( $(echo "$TOTAL_SCORE >= 21" | bc -l) )); then
  echo -e "  ${YELLOW}${BOLD}보통${NC}"
else
  echo -e "  ${RED}${BOLD}미흡${NC}"
fi

echo ""
echo -e "${BOLD}  채점 완료. 이의신청 완료 후 리소스를 삭제하세요.${NC}"
echo ""
