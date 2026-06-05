#!/bin/bash
# ============================================================
#  2026 전국기능경기대회 클라우드컴퓨팅 제2과제
#  Module 4. RDS Connection (Aurora Serverless v2 / Lambda) 채점 스크립트
#  Region: ap-northeast-3
#
#  채점항목 (5개 × 1.5점 = 7.5점)
#    [4-1] Aurora Cluster 생성 확인
#    [4-2] Data API (HTTP Endpoint) 활성화 확인
#    [4-3] Secrets Manager 시크릿 (rds/aurora/admin) 확인
#    [4-4] rds-query-function Lambda 함수 생성 확인
#    [4-5] Lambda 실행 결과 정상 반환 확인
# ============================================================

REGION="ap-northeast-3"
CLUSTER="rds-aurora-cluster"
SECRET_ID="rds/aurora/admin"
LAMBDA="rds-query-function"
RESPONSE_FILE="/tmp/response_$$.json"

PASS=0; TOTAL=0

BOLD="\033[1m"; RED="\033[31m"; GREEN="\033[32m"
YELLOW="\033[33m"; CYAN="\033[36m"; RESET="\033[0m"

pass() { echo -e "  ${GREEN}[PASS]${RESET} $1  ${GREEN}(+1.5점)${RESET}"; ((PASS++)); ((TOTAL++)); }
fail() { echo -e "  ${RED}[FAIL]${RESET} $1  ${RED}(+0점)${RESET}";   ((TOTAL++)); }
info() { echo -e "         ${YELLOW}$1${RESET}"; }
cmd()  { echo -e "  ${CYAN}▶ $1${RESET}"; }

echo -e "\n${BOLD}${CYAN}================================================================${RESET}"
echo -e "${BOLD}${CYAN}  Module 4. RDS Connection 채점  │  Region: ${REGION}${RESET}"
echo -e "${BOLD}${CYAN}================================================================${RESET}\n"

# ──────────────────────────────────────────────────────────────
# [4-1] Aurora Cluster 생성 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[4-1] Aurora Cluster 생성 확인${RESET}"
cmd "aws rds describe-db-clusters \\"
cmd "  --db-cluster-identifier $CLUSTER \\"
cmd "  --region $REGION"
echo ""

CLUSTER_JSON=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$CLUSTER" \
  --region "$REGION" \
  --output json 2>/dev/null)
CLUSTER_OK=$?

echo "$CLUSTER_JSON" | python3 -c "
import sys,json
clusters=json.load(sys.stdin).get('DBClusters',[])
if clusters:
    c=clusters[0]
    print('  DBClusterIdentifier:', c.get('DBClusterIdentifier'))
    print('  Status:', c.get('Status'))
    print('  Engine:', c.get('Engine'))
    print('  EngineVersion:', c.get('EngineVersion'))
" 2>/dev/null | sed 's/^/         /'
echo ""

info "결과값: $([ $CLUSTER_OK -eq 0 ] && echo '클러스터 존재' || echo '클러스터 없음')"
info "기대값: Cluster 존재"
echo ""

if [ $CLUSTER_OK -eq 0 ]; then
  CLUSTER_DATA=$(echo "$CLUSTER_JSON" | python3 -c "
import sys,json; c=json.load(sys.stdin).get('DBClusters',[{}])[0]; print(json.dumps(c))
" 2>/dev/null)
  pass "[4-1] Aurora 클러스터 '$CLUSTER' 생성 확인"
else
  CLUSTER_DATA="{}"
  fail "[4-1] Aurora 클러스터 '$CLUSTER' 없음"
fi
echo ""

# ──────────────────────────────────────────────────────────────
# [4-2] Data API (HTTP Endpoint) 활성화 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[4-2] Data API (HTTP Endpoint) 활성화 확인${RESET}"
cmd "aws rds describe-db-clusters \\"
cmd "  --db-cluster-identifier $CLUSTER \\"
cmd "  --region $REGION \\"
cmd "  --query \"DBClusters[0].HttpEndpointEnabled\""
echo ""

HTTP_ENABLED=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$CLUSTER" \
  --region "$REGION" \
  --query "DBClusters[0].HttpEndpointEnabled" \
  --output text 2>/dev/null)

echo "         $HTTP_ENABLED"
echo ""

info "결과값: HttpEndpointEnabled=${HTTP_ENABLED:-없음}"
info "기대값: true"
echo ""

[ "$HTTP_ENABLED" = "true" ] \
  && pass "[4-2] RDS Data API (HTTP Endpoint) 활성화 확인 (true)" \
  || fail "[4-2] Data API 비활성화 (결과: ${HTTP_ENABLED:-없음})"
echo ""

# ──────────────────────────────────────────────────────────────
# [4-3] Secrets Manager 시크릿 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[4-3] Secrets Manager 시크릿 확인 (rds/aurora/admin)${RESET}"
cmd "aws secretsmanager describe-secret \\"
cmd "  --secret-id $SECRET_ID \\"
cmd "  --region $REGION"
echo ""

SECRET_RESULT=$(aws secretsmanager describe-secret \
  --secret-id "$SECRET_ID" \
  --region "$REGION" \
  --output json 2>/dev/null)
SECRET_OK=$?

echo "$SECRET_RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('  Name:', d.get('Name'))
print('  ARN:', d.get('ARN'))
" 2>/dev/null | sed 's/^/         /'
echo ""

info "결과값: $([ $SECRET_OK -eq 0 ] && echo 'Secret 존재' || echo 'Secret 없음')"
info "기대값: Secret 존재"
echo ""

[ $SECRET_OK -eq 0 ] \
  && pass "[4-3] Secrets Manager 시크릿 '$SECRET_ID' 확인" \
  || fail "[4-3] 시크릿 '$SECRET_ID' 없음"
echo ""

# ──────────────────────────────────────────────────────────────
# [4-4] Lambda 함수 생성 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[4-4] Lambda 함수 생성 확인 (rds-query-function)${RESET}"
cmd "aws lambda get-function \\"
cmd "  --function-name $LAMBDA \\"
cmd "  --region $REGION"
echo ""

LAMBDA_RESULT=$(aws lambda get-function \
  --function-name "$LAMBDA" \
  --region "$REGION" \
  --output json 2>/dev/null)
LAMBDA_OK=$?

echo "$LAMBDA_RESULT" | python3 -c "
import sys,json
c=json.load(sys.stdin).get('Configuration',{})
env=c.get('Environment',{}).get('Variables',{})
print('  FunctionName:', c.get('FunctionName'))
print('  Runtime:', c.get('Runtime'))
print('  VpcId:', c.get('VpcConfig',{}).get('VpcId','(없음)'))
print('  CLUSTER_ARN:', env.get('CLUSTER_ARN','(없음)'))
print('  SECRET_ARN:', env.get('SECRET_ARN','(없음)'))
print('  DB_NAME:', env.get('DB_NAME','(없음)'))
" 2>/dev/null | sed 's/^/         /'
echo ""

info "결과값: $([ $LAMBDA_OK -eq 0 ] && echo '함수 존재' || echo '함수 없음')"
info "기대값: 함수 존재"
echo ""

[ $LAMBDA_OK -eq 0 ] \
  && pass "[4-4] rds-query-function Lambda 함수 생성 확인" \
  || fail "[4-4] Lambda 함수 '$LAMBDA' 없음"
echo ""

# ──────────────────────────────────────────────────────────────
# [4-5] Lambda 실행 결과 정상 반환 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[4-5] Lambda 실행 결과 정상 반환 확인${RESET}"
cmd "aws lambda invoke \\"
cmd "  --function-name $LAMBDA \\"
cmd "  --region $REGION \\"
cmd "  response.json"
echo ""
cmd "cat response.json"
echo ""

aws lambda invoke \
  --function-name "$LAMBDA" \
  --region        "$REGION" \
  "$RESPONSE_FILE" 2>/dev/null
INVOKE_OK=$?

if [ -f "$RESPONSE_FILE" ]; then
  python3 -m json.tool "$RESPONSE_FILE" 2>/dev/null | sed 's/^/         /' \
    || cat "$RESPONSE_FILE" | sed 's/^/         /'
  echo ""

  # 정상 JSON 결과 반환 여부 확인
  FUNC_RESULT=$(python3 -c "
import json
try:
    d = json.load(open('$RESPONSE_FILE'))
    # errorMessage 또는 errorType이 있으면 실패
    if 'errorMessage' in d or 'errorType' in d:
        print('error')
    else:
        print('ok')
except:
    print('invalid')
" 2>/dev/null)

  info "결과값: 호출=$([ $INVOKE_OK -eq 0 ] && echo '성공' || echo '실패')  JSON 결과=${FUNC_RESULT}"
  info "기대값: 정상 JSON 결과 반환"
  echo ""

  [ $INVOKE_OK -eq 0 ] && [ "$FUNC_RESULT" = "ok" ] \
    && pass "[4-5] Lambda 실행 후 정상 JSON 결과 반환 확인" \
    || fail "[4-5] Lambda 실행 오류 (호출=$([ $INVOKE_OK -eq 0 ] && echo ok || echo fail), 결과=${FUNC_RESULT})"
else
  info "결과값: response.json 없음 (Lambda 호출 실패)"
  info "기대값: 정상 JSON 결과 반환"
  echo ""
  fail "[4-5] Lambda 호출 실패 또는 response.json 없음"
fi

rm -f "$RESPONSE_FILE"
echo ""

# ──────────────────────────────────────────────────────────────
SCORE=$(echo "scale=1; $PASS * 1.5" | bc 2>/dev/null || echo "$((PASS * 3 / 2))")
echo -e "${BOLD}${CYAN}================================================================${RESET}"
echo -e "${BOLD}  Module 4. RDS Connection 채점 결과: ${PASS} / ${TOTAL} 항목 통과  │  ${SCORE}점 / 7.5점${RESET}"
echo -e "${BOLD}${CYAN}================================================================${RESET}\n"
