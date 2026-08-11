#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
manifest=app-deployments.yaml
if grep -q 'REPLACE_' "$manifest"; then
  echo "ERROR: app-deployments.yaml의 REPLACE_* 값을 먼저 교체하세요." >&2
  grep -o 'REPLACE_[A-Z_]*' "$manifest" | sort -u >&2
  exit 1
fi
kubectl apply -f "$manifest" --dry-run=server
read -rsp 'DB password: ' db_password
echo
password_file=$(mktemp)
trap 'rm -f "$password_file"' EXIT
chmod 600 "$password_file"
printf '%s' "$db_password" > "$password_file"
unset db_password
kubectl create namespace apdev --dry-run=client -o yaml | kubectl apply -f -
kubectl -n apdev create secret generic app-db-secret \
  --from-literal=MYSQL_USER=appuser \
  --from-file=MYSQL_PASSWORD="$password_file" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f "$password_file"
trap - EXIT
kubectl apply -f "$manifest"
for app in user product stress; do
  kubectl -n apdev rollout status deployment/"$app-deployment" --timeout=5m
done
kubectl -n apdev get deployment,pod,service -o wide