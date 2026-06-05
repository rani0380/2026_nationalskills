#!/bin/bash
# ============================================================
#  2026 전국기능경기대회 클라우드컴퓨팅 제2과제
#  전체 모듈 통합 채점  (총 20개 항목 × 1.5점 = 30점)
#
#  사용법: bash grade_all.sh <비번호>
#  예시  : bash grade_all.sh 007
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOLD="\033[1m"; RED="\033[31m"; GREEN="\033[32m"
YELLOW="\033[33m"; CYAN="\033[36m"; RESET="\033[0m"

if [ -z "$1" ]; then
  echo -n "  비번호를 입력하세요: "
  read BIB_NUMBER
else
  BIB_NUMBER="$1"
fi

echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║   2026 전국기능경기대회 클라우드컴퓨팅 제2과제 통합 채점  ║${RESET}"
echo -e "${BOLD}${CYAN}║   비번호: ${BIB_NUMBER}  │  총 20항목 × 1.5점 = 30점              ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo -e "  채점 시작: $(date '+%Y-%m-%d %H:%M:%S')\n"

command -v aws &>/dev/null || { echo -e "${RED}[ERROR] AWS CLI 미설치${RESET}"; exit 1; }
chmod +x "$SCRIPT_DIR"/grade_module*.sh 2>/dev/null

declare -A MOD_PASS MOD_TOTAL

run_module() {
  local KEY="$1" SCRIPT="$2" ARGS="$3"
  echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  [ ! -f "$SCRIPT" ] && { echo -e "${RED}[ERROR] $SCRIPT 없음${RESET}"; return; }
  OUTPUT=$(bash "$SCRIPT" $ARGS 2>&1)
  echo "$OUTPUT"
  SUMMARY=$(echo "$OUTPUT" | grep "채점 결과:" | tail -1)
  MOD_PASS["$KEY"]=$(echo "$SUMMARY"  | grep -oP '\d+(?= / )')
  MOD_TOTAL["$KEY"]=$(echo "$SUMMARY" | grep -oP '(?<= / )\d+(?= 항목)')
}

run_module "M1" "$SCRIPT_DIR/grade_module1.sh" "$BIB_NUMBER"
run_module "M2" "$SCRIPT_DIR/grade_module2.sh" "$BIB_NUMBER"
run_module "M3" "$SCRIPT_DIR/grade_module3.sh" "$BIB_NUMBER"
run_module "M4" "$SCRIPT_DIR/grade_module4.sh" ""

# ── 최종 집계 ──────────────────────────────────────────────
GRAND_PASS=0; GRAND_TOTAL=0; GRAND_SCORE=0
for K in M1 M2 M3 M4; do
  P="${MOD_PASS[$K]:-0}"; T="${MOD_TOTAL[$K]:-0}"
  GRAND_PASS=$((GRAND_PASS   + P))
  GRAND_TOTAL=$((GRAND_TOTAL + T))
done
GRAND_SCORE=$(echo "scale=1; $GRAND_PASS * 1.5" | bc 2>/dev/null)

echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║                     최종 채점 결과 요약                       ║${RESET}"
echo -e "${BOLD}${CYAN}╠══════════════════════════════╦══════════╦══════════════════════╣${RESET}"
echo -e "${BOLD}${CYAN}║  모  듈                      ║  통과    ║  점  수              ║${RESET}"
echo -e "${BOLD}${CYAN}╠══════════════════════════════╬══════════╬══════════════════════╣${RESET}"

declare -A LABELS
LABELS["M1"]="Module 1. NoSQL               "
LABELS["M2"]="Module 2. CDN                 "
LABELS["M3"]="Module 3. Workflow             "
LABELS["M4"]="Module 4. RDS Connection       "

for K in M1 M2 M3 M4; do
  P="${MOD_PASS[$K]:-0}"; T="${MOD_TOTAL[$K]:-0}"
  S=$(echo "scale=1; $P * 1.5" | bc 2>/dev/null)
  [ "$P" = "$T" ] && [ "$T" -gt 0 ] && C="$GREEN" \
    || { [ "${P:-0}" -gt 0 ] && C="$YELLOW" || C="$RED"; }
  printf "${BOLD}${CYAN}║${RESET}  %-30s${BOLD}${CYAN}║${RESET}  ${C}%d / %d항목${RESET}  ${BOLD}${CYAN}║${RESET}  ${C}%s점 / 7.5점${RESET}          ${BOLD}${CYAN}║${RESET}\n" \
    "${LABELS[$K]}" "$P" "$T" "$S"
done

echo -e "${BOLD}${CYAN}╠══════════════════════════════╬══════════╬══════════════════════╣${RESET}"
printf "${BOLD}${CYAN}║${RESET}  %-30s${BOLD}${CYAN}║${RESET}  ${BOLD}%d / %d항목${RESET}  ${BOLD}${CYAN}║${RESET}  ${BOLD}%s점 / 30점${RESET}           ${BOLD}${CYAN}║${RESET}\n" \
  "합  계" "$GRAND_PASS" "$GRAND_TOTAL" "$GRAND_SCORE"
echo -e "${BOLD}${CYAN}╚══════════════════════════════╩══════════╩══════════════════════╝${RESET}"
echo -e "\n  채점 완료: $(date '+%Y-%m-%d %H:%M:%S')\n"
