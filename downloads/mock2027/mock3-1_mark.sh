#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 || ! "$1" =~ ^[0-9]{1,6}$ ]]; then
  echo "Usage: bash $0 <비번호> [교사영역별점수]"
  exit 2
fi
# Fetch the shared read-only checker into a temporary directory.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
curl -fLsS "https://rani0380.github.io/2026_nationalskills/downloads/mock2027/mock3-check.py" -o "$tmpdir/mock3-check.py"
python3 "$tmpdir/mock3-check.py" 1 "$@"
