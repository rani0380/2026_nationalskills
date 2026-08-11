#!/usr/bin/env bash
set -Eeuo pipefail
ns=apdev
cleanup(){ kubectl -n "$ns" delete pod api-check --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
kubectl -n "$ns" run api-check --image=curlimages/curl:8.10.1 --restart=Never --command -- sleep 600
kubectl -n "$ns" wait --for=condition=Ready pod/api-check --timeout=2m
for app in user product stress; do
  code=$(kubectl -n "$ns" exec api-check -- curl -sS -o /dev/null -w '%{http_code}' "http://$app-service:8080/healthcheck")
  printf '%-8s healthcheck=%s\n' "$app" "$code"
  test "$code" = 200
 done
request_id=999999999999
uuid=7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729
kubectl -n "$ns" exec api-check -- curl -fsS -G http://user-service:8080/v1/user \
  --data-urlencode 'email=dbdump500001@example.org' \
  --data-urlencode "requestid=$request_id" \
  --data-urlencode "uuid=$uuid"
kubectl -n "$ns" exec api-check -- curl -fsS -G http://product-service:8080/v1/product \
  --data-urlencode 'id=dbdump500001' \
  --data-urlencode "requestid=$request_id" \
  --data-urlencode "uuid=$uuid"
kubectl -n "$ns" exec api-check -- curl -fsS -X POST http://stress-service:8080/v1/stress \
  -H 'Content-Type: application/json' \
  -d "{\"requestid\":\"$request_id\",\"uuid\":\"$uuid\",\"length\":256}"
echo 'Smoke test complete.'