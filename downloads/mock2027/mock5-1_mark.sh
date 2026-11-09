#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ! "$1" =~ ^[0-9]{1,12}$ ]]; then
  echo "Usage: bash $0 <비번호> [교사영역별점수]" >&2
  exit 2
fi

for command in aws python3 curl; do
  if ! command -v "$command" >/dev/null; then
    echo "[ERROR] 필요한 명령을 찾을 수 없습니다: $command" >&2
    exit 1
  fi
done

checker=$(mktemp)
trap 'rm -f -- "$checker"' EXIT
curl -fsSL --max-time 60 "https://rani0380.github.io/2026_nationalskills/downloads/mock2027/mock5-check.py" -o "$checker"
python3 "$checker" 1 "$@"
