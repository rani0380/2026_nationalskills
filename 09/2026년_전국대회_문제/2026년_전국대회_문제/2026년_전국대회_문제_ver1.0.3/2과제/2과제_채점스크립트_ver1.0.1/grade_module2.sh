#!/bin/bash
# ============================================================
#  2026 전국기능경기대회 클라우드컴퓨팅 제2과제
#  Module 2. CDN (S3 / CloudFront) 채점 스크립트
#  Region: us-east-1
#
#  사용법: bash grade_module2.sh <비번호>
#  예시  : bash grade_module2.sh 007
#
#  채점항목 (5개 × 1.5점 = 7.5점)
#    [2-1] S3 버킷 생성 확인
#    [2-2] 정적 파일 업로드 확인 (index.html, style.css, image.png)
#    [2-3] CloudFront Distribution 생성 확인
#    [2-4] OAC 구성 및 S3 직접 접근 차단 확인
#    [2-5] X-Custom-Header: wsc2026 정상 반환 확인
# ============================================================

REGION="us-east-1"

PASS=0; TOTAL=0

BOLD="\033[1m"; RED="\033[31m"; GREEN="\033[32m"
YELLOW="\033[33m"; CYAN="\033[36m"; RESET="\033[0m"

pass() { echo -e "  ${GREEN}[PASS]${RESET} $1  ${GREEN}(+1.5점)${RESET}"; ((PASS++)) || true; ((TOTAL++)) || true; }
fail() { echo -e "  ${RED}[FAIL]${RESET} $1  ${RED}(+0점)${RESET}"; ((TOTAL++)) || true; }
info() { echo -e "         ${YELLOW}$1${RESET}"; }
cmd()  { echo -e "  ${CYAN}▶ $1${RESET}"; }

echo -e "\n${BOLD}${CYAN}================================================================${RESET}"
echo -e "${BOLD}${CYAN}  Module 2. CDN (S3 / CloudFront) 채점  │  Region: ${REGION}${RESET}"
echo -e "${BOLD}${CYAN}================================================================${RESET}\n"

# ── 비번호 처리 ──────────────────────────────────────────────
if [ -z "$1" ]; then
  echo -n "  비번호를 입력하세요: "
  read BIB_NUMBER
else
  BIB_NUMBER="$1"
fi
BUCKET="cdn-static-${BIB_NUMBER}"
COMMENT="cdn-${BIB_NUMBER}"
info "버킷명: $BUCKET  │  CF Comment: $COMMENT"
echo ""

# ──────────────────────────────────────────────────────────────
# [2-1] S3 버킷 생성 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[2-1] S3 버킷 생성 확인${RESET}"
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
  && pass "[2-1] S3 버킷 '$BUCKET' 생성 확인" \
  || fail "[2-1] S3 버킷 '$BUCKET' 없음"
echo ""

# ──────────────────────────────────────────────────────────────
# [2-2] 정적 파일 업로드 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[2-2] 정적 파일 업로드 확인 (index.html, style.css, image.png)${RESET}"
cmd "aws s3 ls s3://$BUCKET"
echo ""

S3_LS=$(aws s3 ls "s3://${BUCKET}" 2>/dev/null)
echo "$S3_LS" | sed 's/^/         /'
echo ""

HTML_OK=$(echo "$S3_LS" | grep -c "index.html")
CSS_OK=$(echo "$S3_LS"  | grep -c "style.css")
IMG_OK=$(echo "$S3_LS"  | grep -c "image.png")

info "결과값: index.html=$([ $HTML_OK -ge 1 ] && echo '있음' || echo '없음')  style.css=$([ $CSS_OK -ge 1 ] && echo '있음' || echo '없음')  image.png=$([ $IMG_OK -ge 1 ] && echo '있음' || echo '없음')"
info "기대값: index.html, style.css, image.png 모두 존재"
echo ""

[ $HTML_OK -ge 1 ] && [ $CSS_OK -ge 1 ] && [ $IMG_OK -ge 1 ] \
  && pass "[2-2] index.html, style.css, image.png 업로드 확인" \
  || fail "[2-2] 파일 업로드 불완전 (html=$HTML_OK, css=$CSS_OK, png=$IMG_OK)"
echo ""

# ──────────────────────────────────────────────────────────────
# [2-3] CloudFront Distribution 생성 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[2-3] CloudFront Distribution 생성 확인${RESET}"
cmd "CF_ID=\$(aws cloudfront list-distributions \\"
cmd "  --query \"DistributionList.Items[?Comment=='$COMMENT'].Id\" \\"
cmd "  --output text)"
echo ""
cmd "aws cloudfront get-distribution \\"
cmd "  --id \$CF_ID \\"
cmd "  --query \"Distribution.DistributionConfig.Enabled\""
echo ""

# Comment로 Distribution 조회
CF_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='${COMMENT}'].Id" \
  --output text 2>/dev/null)

# Comment 미설정 시 Origin 도메인으로 폴백
if [ -z "$CF_ID" ] || [ "$CF_ID" = "None" ]; then
  CF_ID=$(aws cloudfront list-distributions 2>/dev/null | python3 -c "
import sys,json
bucket='$BUCKET'
for d in json.load(sys.stdin).get('DistributionList',{}).get('Items',[]):
    for o in d.get('Origins',{}).get('Items',[]):
        if bucket in o.get('DomainName',''):
            print(d['Id']); break
" 2>/dev/null)
  [ -n "$CF_ID" ] && info "※ Comment 조회 실패 → Origin 도메인으로 대체 조회"
fi

if [ -z "$CF_ID" ] || [ "$CF_ID" = "None" ]; then
  info "결과값: Distribution 없음 (Comment='$COMMENT')"
  info "기대값: true"
  echo ""
  fail "[2-3] CloudFront Distribution 없음"
  CF_DOMAIN=""
else
  ENABLED=$(aws cloudfront get-distribution \
    --id "$CF_ID" \
    --query "Distribution.DistributionConfig.Enabled" \
    --output text 2>/dev/null)
  CF_DOMAIN=$(aws cloudfront get-distribution \
    --id "$CF_ID" \
    --query "Distribution.DomainName" \
    --output text 2>/dev/null)
  CF_STATUS=$(aws cloudfront get-distribution \
    --id "$CF_ID" \
    --query "Distribution.Status" \
    --output text 2>/dev/null)

  info "Distribution ID: $CF_ID"
  info "CloudFront 도메인: $CF_DOMAIN"
  info "결과값: Enabled=$ENABLED  Status=$CF_STATUS"
  info "기대값: true"
  echo ""

  [ "${ENABLED,,}" = "true" ] \
    && pass "[2-3] CloudFront Distribution 생성 확인 (Enabled=true)" \
    || fail "[2-3] CloudFront Distribution 비활성화 (Enabled=${ENABLED:-없음})"
fi
echo ""

# ──────────────────────────────────────────────────────────────
# [2-4] OAC 연결 및 S3 직접 접근 차단 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[2-4] OAC 구성 및 S3 직접 접근 차단 확인${RESET}"
cmd "aws cloudfront get-distribution \\"
cmd "  --id \$CF_ID \\"
cmd "  --query \"Distribution.DistributionConfig.Origins.Items[0].OriginAccessControlId\""
echo ""

if [ -n "$CF_ID" ] && [ "$CF_ID" != "None" ]; then
  OAC_ID=$(aws cloudfront get-distribution \
    --id "$CF_ID" \
    --query "Distribution.DistributionConfig.Origins.Items[0].OriginAccessControlId" \
    --output text 2>/dev/null)

  # S3 직접 URL 접근 차단 확인
  S3_URL="https://${BUCKET}.s3.${REGION}.amazonaws.com/index.html"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$S3_URL" 2>/dev/null)

  info "결과값: OAC_ID=${OAC_ID:-없음}  S3 직접 접근 HTTP=$HTTP_CODE"
  info "기대값: OAC ID 값 존재, S3 직접 접근 차단(403 또는 400)"
  echo ""

  OAC_OK=false; S3_BLOCK=false
  [ -n "$OAC_ID" ] && [ "$OAC_ID" != "None" ] && OAC_OK=true
  { [ "$HTTP_CODE" = "403" ] || [ "$HTTP_CODE" = "400" ]; } && S3_BLOCK=true

  $OAC_OK && $S3_BLOCK \
    && pass "[2-4] OAC 연결 확인 (ID: $OAC_ID), S3 직접 접근 차단 (HTTP $HTTP_CODE)" \
    || fail "[2-4] OAC 오류 (OAC=${OAC_ID:-없음}, S3직접접근=HTTP $HTTP_CODE)"
else
  info "결과값: Distribution 없음 - OAC 확인 불가"
  echo ""
  fail "[2-4] Distribution 없음으로 OAC 확인 불가"
fi
echo ""

# ──────────────────────────────────────────────────────────────
# [2-5] X-Custom-Header: wsc2026 정상 반환 확인
# ──────────────────────────────────────────────────────────────
echo -e "${BOLD}[2-5] X-Custom-Header: wsc2026 정상 반환 확인${RESET}"

if [ -n "$CF_DOMAIN" ]; then
  cmd "curl -sI \"https://${CF_DOMAIN}/index.html?v=1\" | grep X-Custom-Header"
  echo ""

  HEADER_LINE=$(curl -sI "https://${CF_DOMAIN}/index.html?v=1" --max-time 20 2>/dev/null \
    | grep -i "X-Custom-Header")
  echo "         ${HEADER_LINE:-X-Custom-Header: (없음)}"
  echo ""

  HEADER_VAL=$(echo "$HEADER_LINE" | awk '{print $2}' | tr -d '\r\n')
  info "결과값: X-Custom-Header: ${HEADER_VAL:-없음}"
  info "기대값: X-Custom-Header: wsc2026"
  echo ""

  [ "$HEADER_VAL" = "wsc2026" ] \
    && pass "[2-5] X-Custom-Header: wsc2026 응답 확인" \
    || fail "[2-5] X-Custom-Header 오류 (결과: ${HEADER_VAL:-없음})"
else
  cmd "curl -sI \"https://<CloudFront Domain>/index.html?v=1\" | grep X-Custom-Header"
  echo ""
  info "결과값: CloudFront 도메인 없음 - 헤더 확인 불가"
  echo ""
  fail "[2-5] CloudFront 도메인 없음으로 헤더 확인 불가"
fi
echo ""

# ──────────────────────────────────────────────────────────────
SCORE=$(echo "scale=1; $PASS * 1.5" | bc 2>/dev/null || echo "$((PASS * 3 / 2))")
echo -e "${BOLD}${CYAN}================================================================${RESET}"
echo -e "${BOLD}  Module 2. CDN 채점 결과: ${PASS} / ${TOTAL} 항목 통과  │  ${SCORE}점 / 7.5점${RESET}"
echo -e "${BOLD}${CYAN}================================================================${RESET}\n"
