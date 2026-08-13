#!/usr/bin/env bash
set -u
ENDPOINT="${1:-}"; IMAGE_PATH="${2:-}"; REQUESTS="${REQUESTS:-40}"
if [[ ! "$ENDPOINT" =~ ^https?://[^/]+/?$ ]]; then echo "사용법: $0 https://YOUR-ENDPOINT [/images/existing.jpg]"; exit 1; fi
ENDPOINT="${ENDPOINT%/}"; RID="$(date +%s%N)"; UUID="$(cat /proc/sys/kernel/random/uuid)"
EMAIL="practice-${RID}@example.org"; PID="practice-${RID}"
request(){ local m="$1" p="$2" b="${3:-}"; if [[ -n "$b" ]]; then curl -ksS --max-time 5 -o /dev/null -w '%{http_code} %{time_total}' -X "$m" -H 'Content-Type: application/json' --data "$b" "$ENDPOINT$p" 2>/dev/null || echo '000 5.999'; else curl -ksS --max-time 5 -o /dev/null -w '%{http_code} %{time_total}' -X "$m" "$ENDPOINT$p" 2>/dev/null || echo '000 5.999'; fi; }
UB=$(printf '{"requestid":"%s","uuid":"%s","username":"practice-%s","email":"%s"}' "$RID" "$UUID" "$RID" "$EMAIL")
PB=$(printf '{"requestid":"%s","uuid":"%s","id":"%s","name":"practice-product","price":1234}' "$RID" "$UUID" "$PID")
SB=$(printf '{"requestid":"%s","uuid":"%s","length":256}' "$RID" "$UUID")
UC="$(request POST "/v1/user?requestid=${RID}&uuid=${UUID}" "$UB")"; PC="$(request POST "/v1/product?requestid=${RID}&uuid=${UUID}" "$PB")"
run_load(){ local k="$1" lim="$2" ok=0 fast=0 i code sec path method body; for ((i=1;i<=REQUESTS;i++)); do case "$k" in user) method=GET; path="/v1/user?email=${EMAIL}&requestid=${RID}${i}&uuid=${UUID}"; body="";; product) method=GET; path="/v1/product?id=${PID}&requestid=${RID}${i}&uuid=${UUID}"; body="";; stress) method=POST; path="/v1/stress?requestid=${RID}${i}&uuid=${UUID}"; body="$SB";; esac; read -r code sec <<<"$(request "$method" "$path" "$body")"; [[ "$code" =~ ^2 ]] && ((ok+=1)); if [[ "$code" =~ ^2 ]] && awk -v t="$sec" -v l="$lim" 'BEGIN{exit !(t<=l)}'; then ((fast+=1)); fi; done; awk -v n="$REQUESTS" -v s="$ok" -v f="$fast" 'BEGIN{printf "%.2f %.2f",s*100/n,f*100/n}'; }
echo "USER 측정"; read -r UA UP <<<"$(run_load user .2)"
echo "PRODUCT 측정"; read -r PA PP <<<"$(run_load product .2)"
echo "STRESS 측정"; read -r SA SP <<<"$(run_load stress 1)"
EX=0; for ((i=1;i<=REQUESTS;i++)); do read -r C1 _ <<<"$(request GET '/v1/user?email=invalid')"; read -r C2 _ <<<"$(request GET "/v1/none?requestid=${RID}${i}&uuid=${UUID}")"; [[ "$C1" == 403 ]] && ((EX+=1)); [[ "$C2" == 404 ]] && ((EX+=1)); done
EP=$(awk -v n="$((REQUESTS*2))" -v s="$EX" 'BEGIN{printf "%.2f",s*100/n}'); IP=0
if [[ -n "$IMAGE_PATH" ]]; then OK=0; for ((i=1;i<=REQUESTS;i++)); do read -r C _ <<<"$(request GET "$IMAGE_PATH")"; [[ "$C" == 200 ]] && ((OK+=1)); done; IP=$(awk -v n="$REQUESTS" -v s="$OK" 'BEGIN{printf "%.2f",s*100/n}'); fi
cat > mock-grader-result.json <<JSON
{"endpoint":"$ENDPOINT","metrics":{"image":$IP,"exception":$EP,"user_availability":$UA,"user_performance":$UP,"product_availability":$PA,"product_performance":$PP,"stress_availability":$SA,"stress_performance":$SP},"checks":[{"name":"USER 생성","ok":$( [[ "$UC" =~ ^201 ]] && echo true || echo false ),"detail":"HTTP ${UC%% *}"},{"name":"PRODUCT 생성","ok":$( [[ "$PC" =~ ^201 ]] && echo true || echo false ),"detail":"HTTP ${PC%% *}"}]}
JSON
echo "완료: mock-grader-result.json"
