#!/bin/bash
# ============================================================
#  2026 전국기능경기대회 클라우드컴퓨팅 제2과제
#  Module 1. NoSQL (DynamoDB) 채점 스크립트
#  Region: ap-northeast-2
#
#  채점항목 (5개 × 1.5점 = 7.5점)
#    [1-1] DynamoDB 테이블 생성 확인
#    [1-2] Partition Key / Sort Key 구성 정확성
#    [1-3] GSI (category-price-index) 생성 확인
#    [1-4] 샘플 데이터 20건 저장 확인
#    [1-5] result.json 생성 및 조회 결과 저장 확인
# ============================================================

REGION="ap-northeast-2"
TABLE="nosql-products"
INDEX="category-price-index"
RESULT_FILE="$HOME/result.json"

PASS=0; TOTAL=0

BOLD="\033[1m"; RED="\033[31m"; GREEN="\033[32m"
YELLOW="\033[33m"; CYAN="\033[36m"; RESET="\033[0m"

pass() { echo -e "  ${GREEN}[PASS]${RESET} $1  ${GREEN}(+1.5점)${RESET}"; ((PASS++)); ((TOTAL++)); }
fail() { echo -e "  ${RED}[FAIL]${RESET} $1  ${RED}(+0점)${RESET}";   ((TOTAL++)); }
info() { echo -e "         ${YELLOW}$1${RESET}"; }
cmd()  { echo -e "  ${CYAN}▶ $1${RESET}"; }

echo -e "\n${BOLD}${CYAN}================================================================${RESET}"
echo -e "${BOLD}${CYAN}  Module 1. NoSQL (DynamoDB) 채점  │  Region: ${REGION}${RESET}"
echo -e "${BOLD}${CYAN}================================================================${RESET}\n"

# ──────────────────────────────────────────────────────────────
# [1-1] DynamoDB 테이블 생성 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[1-1] DynamoDB 테이블 생성 확인${RESET}"
cmd "aws dynamodb describe-table \\"
cmd "  --table-name $TABLE \\"
cmd "  --region $REGION \\"
cmd "  --query \"Table.TableName\""
echo ""

RESULT=$(aws dynamodb describe-table \
  --table-name "$TABLE" \
  --region "$REGION" \
  --query "Table.TableName" \
  --output text 2>/dev/null)

info "결과값: ${RESULT:-조회 실패}"
info "기대값: $TABLE"
echo ""

[ "$RESULT" = "$TABLE" ] \
  && pass "[1-1] nosql-products 테이블 생성 확인" \
  || fail "[1-1] 테이블 없음 또는 이름 불일치 (결과: ${RESULT:-없음})"
echo ""

# ──────────────────────────────────────────────────────────────
# [1-2] Partition Key / Sort Key 구성 정확성
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[1-2] Partition Key / Sort Key 구성 정확성${RESET}"
cmd "aws dynamodb describe-table \\"
cmd "  --table-name $TABLE \\"
cmd "  --region $REGION \\"
cmd "  --query \"Table.KeySchema\""
echo ""

KEY_JSON=$(aws dynamodb describe-table \
  --table-name "$TABLE" \
  --region "$REGION" \
  --query "Table.KeySchema" \
  --output json 2>/dev/null)
echo "$KEY_JSON" | python3 -m json.tool 2>/dev/null | sed 's/^/         /'
echo ""

PK=$(aws dynamodb describe-table \
  --table-name "$TABLE" --region "$REGION" \
  --query "Table.KeySchema[?KeyType=='HASH'].AttributeName" \
  --output text 2>/dev/null)
SK=$(aws dynamodb describe-table \
  --table-name "$TABLE" --region "$REGION" \
  --query "Table.KeySchema[?KeyType=='RANGE'].AttributeName" \
  --output text 2>/dev/null)

info "결과값: HASH(PK)=${PK:-없음}  RANGE(SK)=${SK:-없음}"
info "기대값: HASH=product_id  RANGE=category"
echo ""

[ "$PK" = "product_id" ] && [ "$SK" = "category" ] \
  && pass "[1-2] PK=product_id (HASH), SK=category (RANGE) 확인" \
  || fail "[1-2] 키 스키마 오류 (PK=${PK:-없음}, SK=${SK:-없음})"
echo ""

# ──────────────────────────────────────────────────────────────
# [1-3] GSI (category-price-index) 생성 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[1-3] GSI (category-price-index) 생성 확인${RESET}"
cmd "aws dynamodb describe-table \\"
cmd "  --table-name $TABLE \\"
cmd "  --region $REGION \\"
cmd "  --query \"Table.GlobalSecondaryIndexes[*].IndexName\""
echo ""

GSI_NAMES=$(aws dynamodb describe-table \
  --table-name "$TABLE" \
  --region "$REGION" \
  --query "Table.GlobalSecondaryIndexes[*].IndexName" \
  --output text 2>/dev/null)

info "결과값: ${GSI_NAMES:-없음}"
info "기대값: $INDEX"
echo ""

echo "$GSI_NAMES" | grep -q "$INDEX" \
  && pass "[1-3] GSI '$INDEX' 생성 확인" \
  || fail "[1-3] GSI '$INDEX' 없음 (결과: ${GSI_NAMES:-없음})"
echo ""

# ──────────────────────────────────────────────────────────────
# [1-4] 샘플 데이터 20건 저장 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[1-4] 샘플 데이터 20건 저장 확인${RESET}"
cmd "aws dynamodb scan \\"
cmd "  --table-name $TABLE \\"
cmd "  --region $REGION \\"
cmd "  --select COUNT"
echo ""

SCAN=$(aws dynamodb scan \
  --table-name "$TABLE" \
  --region "$REGION" \
  --select COUNT \
  --output json 2>/dev/null)
echo "$SCAN" | python3 -m json.tool 2>/dev/null | sed 's/^/         /'
echo ""

COUNT=$(echo "$SCAN" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Count',0))" 2>/dev/null)
info "결과값: Count=${COUNT:-0}"
info "기대값: Count ≥ 20"
echo ""

[ "${COUNT:-0}" -ge 20 ] 2>/dev/null \
  && pass "[1-4] 데이터 ${COUNT}건 저장 확인 (≥ 20건)" \
  || fail "[1-4] 데이터 부족 (결과: ${COUNT:-0}건, 기대: 20건 이상)"
echo ""

# ──────────────────────────────────────────────────────────────
# [1-5] result.json 생성 및 조회 결과 저장 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[1-5] result.json 생성 및 조회 결과 저장 확인${RESET}"
cmd "ls ~/result.json"
cmd "cat ~/result.json"
echo ""

ls "$RESULT_FILE" 2>/dev/null && echo "" || true

if [ ! -f "$RESULT_FILE" ]; then
  info "결과값: ~/result.json 없음"
  info "기대값: 파일 존재 및 상품 데이터 포함"
  echo ""
  fail "[1-5] ~/result.json 파일 없음"
else
  cat "$RESULT_FILE" | python3 -m json.tool 2>/dev/null | head -20 | sed 's/^/         /'
  echo ""

  VALID=$(python3 -c "
import json
try:
    data = json.load(open('$RESULT_FILE'))
    items = data if isinstance(data, list) else [data]
    if len(items) > 0 and isinstance(items[0], dict):
        has_keys = any(k in items[0] for k in ['product_id','category','price'])
        print('ok' if has_keys else 'no_keys')
    else:
        print('empty')
except:
    print('invalid')
" 2>/dev/null)

  info "결과값: 파일 존재, 내용=${VALID}"
  info "기대값: 파일 존재 및 상품 데이터 확인"
  echo ""

  [ "$VALID" = "ok" ] \
    && pass "[1-5] ~/result.json 존재 및 상품 데이터 확인" \
    || fail "[1-5] result.json 내용 오류 (결과: $VALID)"
fi
echo ""

# ──────────────────────────────────────────────────────────────
SCORE=$(echo "scale=1; $PASS * 1.5" | bc 2>/dev/null || echo "$((PASS * 3 / 2))")
echo -e "${BOLD}${CYAN}================================================================${RESET}"
echo -e "${BOLD}  Module 1. NoSQL 채점 결과: ${PASS} / ${TOTAL} 항목 통과  │  ${SCORE}점 / 7.5점${RESET}"
echo -e "${BOLD}${CYAN}================================================================${RESET}\n"
