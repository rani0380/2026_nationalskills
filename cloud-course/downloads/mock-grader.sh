#!/usr/bin/env bash
set -u
ENDPOINT="${1:-}"; IMAGE_PATH="${2:-}"; REQUESTS="${REQUESTS:-40}"; RESULT_FILE="mock-grader-result.json"
if [[ ! "$ENDPOINT" =~ ^https?://[^/]+/?$ ]]; then echo "Usage: $0 https://YOUR-ENDPOINT [/images/existing.jpg]"; exit 1; fi
command -v curl >/dev/null || { echo "curl is required"; exit 1; }
ENDPOINT="${ENDPOINT%/}"
new_identity(){ local stamp; stamp="$(date +%s%N)"; REQUEST_ID="9${stamp: -11}"; REQUEST_UUID="$(cat /proc/sys/kernel/random/uuid)"; }
request(){ local method="$1" path="$2" body="${3:-}" output; if [[ -n "$body" ]]; then output="$(curl -ksS --max-time 5 -o /dev/null -w '%{http_code} %{time_total}' -X "$method" -H 'Content-Type: application/json' --data "$body" "$ENDPOINT$path" 2>/dev/null || true)"; else output="$(curl -ksS --max-time 5 -o /dev/null -w '%{http_code} %{time_total}' -X "$method" "$ENDPOINT$path" 2>/dev/null || true)"; fi; [[ "$output" =~ ^[0-9]{3}[[:space:]][0-9.]+$ ]] || output="000 5.999"; printf '%s\n' "$output"; }
new_identity
USER_EMAIL="practice-${REQUEST_ID}@example.org"
USER_BODY=$(printf '{"requestid":"%s","uuid":"%s","username":"practice-%s","email":"%s"}' "$REQUEST_ID" "$REQUEST_UUID" "$REQUEST_ID" "$USER_EMAIL")
USER_CREATE="$(request POST "/v1/user?requestid=${REQUEST_ID}&uuid=${REQUEST_UUID}" "$USER_BODY")"
new_identity
PRODUCT_ID="practice-${REQUEST_ID}"
PRODUCT_BODY=$(printf '{"requestid":"%s","uuid":"%s","id":"%s","name":"practice-product","price":1234}' "$REQUEST_ID" "$REQUEST_UUID" "$PRODUCT_ID")
PRODUCT_CREATE="$(request POST "/v1/product?requestid=${REQUEST_ID}&uuid=${REQUEST_UUID}" "$PRODUCT_BODY")"
echo "USER create: HTTP ${USER_CREATE%% *}"; echo "PRODUCT create: HTTP ${PRODUCT_CREATE%% *}"
run_load(){ local kind="$1" limit="$2" success=0 fast=0 i code elapsed method path body; for ((i=1;i<=REQUESTS;i++)); do new_identity; case "$kind" in user) method=GET; path="/v1/user?email=${USER_EMAIL}&requestid=${REQUEST_ID}&uuid=${REQUEST_UUID}"; body="";; product) method=GET; path="/v1/product?id=${PRODUCT_ID}&requestid=${REQUEST_ID}&uuid=${REQUEST_UUID}"; body="";; stress) method=POST; path="/v1/stress?requestid=${REQUEST_ID}&uuid=${REQUEST_UUID}"; body=$(printf '{"requestid":"%s","uuid":"%s","length":256}' "$REQUEST_ID" "$REQUEST_UUID");; esac; read -r code elapsed <<<"$(request "$method" "$path" "$body")"; if [[ "$code" =~ ^2 ]]; then ((success+=1)); if awk -v t="$elapsed" -v l="$limit" 'BEGIN{exit !(t<=l)}'; then ((fast+=1)); fi; fi; done; awk -v n="$REQUESTS" -v s="$success" -v f="$fast" 'BEGIN{printf "%.2f %.2f",s*100/n,f*100/n}'; }
echo "Measuring USER"; read -r USER_AVAIL USER_PERF <<<"$(run_load user 0.2)"
echo "Measuring PRODUCT"; read -r PRODUCT_AVAIL PRODUCT_PERF <<<"$(run_load product 0.2)"
echo "Measuring STRESS"; read -r STRESS_AVAIL STRESS_PERF <<<"$(run_load stress 1.0)"
EXCEPTION_OK=0
for ((i=1;i<=REQUESTS;i++)); do read -r invalid_code _ <<<"$(request GET '/v1/user?email=invalid')"; new_identity; read -r none_code _ <<<"$(request GET "/v1/none?requestid=${REQUEST_ID}&uuid=${REQUEST_UUID}")"; [[ "$invalid_code" == 403 ]] && ((EXCEPTION_OK+=1)); [[ "$none_code" == 404 ]] && ((EXCEPTION_OK+=1)); done
EXCEPTION_RATE=$(awk -v n="$((REQUESTS*2))" -v s="$EXCEPTION_OK" 'BEGIN{printf "%.2f",s*100/n}')
IMAGE_RATE="0.00"
if [[ -n "$IMAGE_PATH" ]]; then IMAGE_OK=0; for ((i=1;i<=REQUESTS;i++)); do read -r image_code _ <<<"$(request GET "$IMAGE_PATH")"; [[ "$image_code" == 200 ]] && ((IMAGE_OK+=1)); done; IMAGE_RATE=$(awk -v n="$REQUESTS" -v s="$IMAGE_OK" 'BEGIN{printf "%.2f",s*100/n}'); fi
cat > "$RESULT_FILE" <<JSON
{"endpoint":"$ENDPOINT","metrics":{"image":$IMAGE_RATE,"exception":$EXCEPTION_RATE,"user_availability":$USER_AVAIL,"user_performance":$USER_PERF,"product_availability":$PRODUCT_AVAIL,"product_performance":$PRODUCT_PERF,"stress_availability":$STRESS_AVAIL,"stress_performance":$STRESS_PERF},"checks":[{"name":"USER create","ok":$( [[ "$USER_CREATE" =~ ^201 ]] && echo true || echo false ),"detail":"HTTP ${USER_CREATE%% *}"},{"name":"PRODUCT create","ok":$( [[ "$PRODUCT_CREATE" =~ ^201 ]] && echo true || echo false ),"detail":"HTTP ${PRODUCT_CREATE%% *}"}]}
JSON
echo "Completed: $RESULT_FILE"
echo "USER availability/performance: ${USER_AVAIL}% / ${USER_PERF}%"
echo "PRODUCT availability/performance: ${PRODUCT_AVAIL}% / ${PRODUCT_PERF}%"
echo "STRESS availability/performance: ${STRESS_AVAIL}% / ${STRESS_PERF}%"
echo "Exception handling: ${EXCEPTION_RATE}%"