#!/bin/bash
# ============================================================
#  2026 전국기능경기대회 클라우드컴퓨팅 제2과제
#  Module 3. Workflow (S3 / Lambda / DynamoDB / Step Functions) 채점 스크립트
#  Region: ap-southeast-1
#
#  사용법: bash grade_module3.sh <비번호>
#  예시  : bash grade_module3.sh 007
#
#  채점항목 (5개 × 1.5점 = 7.5점)
#    [3-1] workflow-input-<비번호> S3 버킷 생성 확인
#    [3-2] workflow-output DynamoDB 테이블 생성 확인
#    [3-3] workflow-transform Lambda 함수 생성 확인
#    [3-4] workflow-state-machine Step Functions 생성 확인
#    [3-5] Step Functions 실행 후 데이터 저장 확인 (Count ≥ 1)
# ============================================================

REGION="ap-southeast-1"
TABLE="workflow-output"
LAMBDA="workflow-transform"
SFN_NAME="workflow-state-machine"

PASS=0; TOTAL=0

BOLD="\033[1m"; RED="\033[31m"; GREEN="\033[32m"
YELLOW="\033[33m"; CYAN="\033[36m"; RESET="\033[0m"

pass() { echo -e "  ${GREEN}[PASS]${RESET} $1  ${GREEN}(+1.5점)${RESET}"; ((PASS++)); ((TOTAL++)); }
fail() { echo -e "  ${RED}[FAIL]${RESET} $1  ${RED}(+0점)${RESET}";   ((TOTAL++)); }
info() { echo -e "         ${YELLOW}$1${RESET}"; }
cmd()  { echo -e "  ${CYAN}▶ $1${RESET}"; }

echo -e "\n${BOLD}${CYAN}================================================================${RESET}"
echo -e "${BOLD}${CYAN}  Module 3. Workflow 채점  │  Region: ${REGION}${RESET}"
echo -e "${BOLD}${CYAN}================================================================${RESET}\n"

# ── 비번호 처리 ──────────────────────────────────────────────
if [ -z "$1" ]; then
  echo -n "  비번호를 입력하세요: "
  read BIB_NUMBER
else
  BIB_NUMBER="$1"
fi
BUCKET="workflow-input-${BIB_NUMBER}"
info "입력 버킷: $BUCKET"
echo ""

# ──────────────────────────────────────────────────────────────
# [3-1] S3 버킷 생성 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[3-1] S3 버킷 생성 확인${RESET}"
cmd "aws s3api head-bucket \\"
cmd "  --bucket $BUCKET \\"
cmd "  --region $REGION"
echo ""

aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null
BUCKET_OK=$?

info "결과값: $([ $BUCKET_OK -eq 0 ] && echo '정상 응답 (버킷 존재)' || echo '오류 (버킷 없음)')"
info "기대값: 정상 응답"
echo ""

[ $BUCKET_OK -eq 0 ] \
  && pass "[3-1] S3 버킷 '$BUCKET' 생성 확인" \
  || fail "[3-1] S3 버킷 '$BUCKET' 없음"
echo ""

# ──────────────────────────────────────────────────────────────
# [3-2] DynamoDB 테이블 생성 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[3-2] DynamoDB 테이블 생성 확인 (workflow-output)${RESET}"
cmd "aws dynamodb describe-table \\"
cmd "  --table-name $TABLE \\"
cmd "  --region $REGION"
echo ""

TABLE_RESULT=$(aws dynamodb describe-table \
  --table-name "$TABLE" \
  --region "$REGION" \
  --output json 2>/dev/null)

TABLE_STATUS=$(echo "$TABLE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['Table']['TableStatus'])" 2>/dev/null)
echo "$TABLE_RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)['Table']
print('  TableName:', d.get('TableName'))
print('  TableStatus:', d.get('TableStatus'))
" 2>/dev/null | sed 's/^/         /'
echo ""

info "결과값: ${TABLE_STATUS:-조회 실패}"
info "기대값: workflow-output 존재"
echo ""

[ "$TABLE_STATUS" = "ACTIVE" ] \
  && pass "[3-2] workflow-output DynamoDB 테이블 생성 확인" \
  || fail "[3-2] 테이블 없음 또는 ACTIVE 아님 (결과: ${TABLE_STATUS:-없음})"
echo ""

# ──────────────────────────────────────────────────────────────
# [3-3] Lambda 함수 생성 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[3-3] Lambda 함수 생성 확인 (workflow-transform)${RESET}"
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
print('  FunctionName:', c.get('FunctionName'))
print('  Runtime:', c.get('Runtime'))
print('  Timeout:', c.get('Timeout'))
print('  TABLE_NAME:', c.get('Environment',{}).get('Variables',{}).get('TABLE_NAME',''))
" 2>/dev/null | sed 's/^/         /'
echo ""

info "결과값: $([ $LAMBDA_OK -eq 0 ] && echo '함수 존재' || echo '함수 없음')"
info "기대값: 함수 존재"
echo ""

[ $LAMBDA_OK -eq 0 ] \
  && pass "[3-3] workflow-transform Lambda 함수 생성 확인" \
  || fail "[3-3] Lambda 함수 '$LAMBDA' 없음"
echo ""

# ──────────────────────────────────────────────────────────────
# [3-4] Step Functions 상태 머신 생성 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[3-4] Step Functions 상태 머신 생성 확인${RESET}"

# ARN 조회
SFN_ARN=$(aws stepfunctions list-state-machines \
  --region "$REGION" \
  --query "stateMachines[?name=='$SFN_NAME'].stateMachineArn" \
  --output text 2>/dev/null)

cmd "aws stepfunctions describe-state-machine \\"
cmd "  --state-machine-arn $SFN_ARN"
echo ""

if [ -z "$SFN_ARN" ] || [ "$SFN_ARN" = "None" ]; then
  info "결과값: 상태 머신 '$SFN_NAME' 없음"
  info "기대값: StateMachineType=STANDARD, workflow-state-machine 존재"
  echo ""
  fail "[3-4] 상태 머신 '$SFN_NAME' 없음"
else
  SFN_DESC=$(aws stepfunctions describe-state-machine \
    --state-machine-arn "$SFN_ARN" \
    --region "$REGION" \
    --output json 2>/dev/null)
  SFN_TYPE=$(echo "$SFN_DESC" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type',''))" 2>/dev/null)

  echo "$SFN_DESC" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('  name:', d.get('name'))
print('  type:', d.get('type'))
print('  status:', d.get('status'))
" 2>/dev/null | sed 's/^/         /'
  echo ""

  info "결과값: type=${SFN_TYPE:-없음}"
  info "기대값: StateMachineType=STANDARD, workflow-state-machine 존재"
  echo ""

  [ "$SFN_TYPE" = "STANDARD" ] \
    && pass "[3-4] workflow-state-machine 생성 확인 (type=STANDARD)" \
    || fail "[3-4] 상태 머신 오류 (type=${SFN_TYPE:-없음})"
fi
echo ""

# ──────────────────────────────────────────────────────────────
# [3-5] Step Functions 실행 후 데이터 저장 확인 (Count ≥ 1)
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[3-5] Step Functions 실행 후 데이터 저장 확인${RESET}"

# 실행 (SFN이 존재하는 경우)
if [ -n "$SFN_ARN" ] && [ "$SFN_ARN" != "None" ]; then
  cmd "aws stepfunctions start-execution \\"
  cmd "  --state-machine-arn $SFN_ARN \\"
  cmd "  --input '{\"bucket\":\"$BUCKET\",\"key\":\"data.csv\"}' \\"
  cmd "  --region $REGION"
  echo ""

  EXEC_ARN=$(aws stepfunctions start-execution \
    --state-machine-arn "$SFN_ARN" \
    --input "{\"bucket\":\"${BUCKET}\",\"key\":\"data.csv\"}" \
    --region "$REGION" \
    --query "executionArn" \
    --output text 2>/dev/null)

  if [ -n "$EXEC_ARN" ] && [ "$EXEC_ARN" != "None" ]; then
    info "실행 ARN: $EXEC_ARN"
    info "완료 대기 중 (최대 60초)..."
    echo ""
    for i in $(seq 1 12); do
      sleep 5
      EXEC_STATUS=$(aws stepfunctions describe-execution \
        --execution-arn "$EXEC_ARN" \
        --region "$REGION" \
        --query "status" \
        --output text 2>/dev/null)
      info "  ${i}회 확인 (${i}×5s): $EXEC_STATUS"
      [ "$EXEC_STATUS" = "SUCCEEDED" ] || [ "$EXEC_STATUS" = "FAILED" ] || [ "$EXEC_STATUS" = "ABORTED" ] && break
    done
    echo ""
    info "실행 최종 상태: $EXEC_STATUS"
  fi
fi

echo ""
cmd "aws dynamodb scan \\"
cmd "  --table-name $TABLE \\"
cmd "  --region $REGION \\"
cmd "  --select COUNT"
echo ""

sleep 2
SCAN=$(aws dynamodb scan \
  --table-name "$TABLE" \
  --region "$REGION" \
  --select COUNT \
  --output json 2>/dev/null)
echo "$SCAN" | python3 -m json.tool 2>/dev/null | sed 's/^/         /'
echo ""

COUNT=$(echo "$SCAN" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Count',0))" 2>/dev/null)
info "결과값: Count=${COUNT:-0}"
info "기대값: Count ≥ 1"
echo ""

[ "${COUNT:-0}" -ge 1 ] 2>/dev/null \
  && pass "[3-5] workflow-output 테이블 데이터 저장 확인 (${COUNT}건)" \
  || fail "[3-5] workflow-output 테이블 데이터 없음 (Count=0)"
echo ""

# ──────────────────────────────────────────────────────────────
SCORE=$(echo "scale=1; $PASS * 1.5" | bc 2>/dev/null || echo "$((PASS * 3 / 2))")
echo -e "${BOLD}${CYAN}================================================================${RESET}"
echo -e "${BOLD}  Module 3. Workflow 채점 결과: ${PASS} / ${TOTAL} 항목 통과  │  ${SCORE}점 / 7.5점${RESET}"
echo -e "${BOLD}${CYAN}================================================================${RESET}\n"
