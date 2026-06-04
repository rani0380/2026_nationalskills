#!/bin/bash

echo =====4-1=====
B=$(aws s3api list-buckets --query "Buckets[?contains(Name,'wsc2026-order-pipeline')].Name|[0]" --output text)
echo $B
aws s3api get-bucket-versioning --bucket $B --query Status --output text 2>/dev/null
echo

echo =====4-2=====
for T in wsc2026-orders wsc2026-inventory wsc2026-pipeline-history; do
  K=$(aws dynamodb describe-table --table-name $T --query "Table.KeySchema[].[KeyType,AttributeName]" --output text 2>/dev/null)
  PK=$(echo "$K"|grep HASH|awk '{print $2}')
  SK=$(echo "$K"|grep RANGE|awk '{print $2}')
  echo "$T	$PK	$SK"
done
aws dynamodb describe-time-to-live --table-name wsc2026-pipeline-history --query 'TimeToLiveDescription.TimeToLiveStatus' --output text 2>/dev/null
echo

echo =====4-3=====
for F in wsc2026-order-validator wsc2026-payment-processor; do
  echo "$F	$(aws lambda get-function --function-name $F --query 'Configuration.Runtime' --output text 2>/dev/null)"
done
echo

echo =====4-4=====
aws lambda invoke --function-name wsc2026-order-validator --payload '{"order_id":"ORD-T1","product_id":"P1","quantity":2,"unit_price":1000,"payment_method":"CARD"}' /tmp/v --cli-binary-format raw-in-base64-out >/dev/null 2>&1 && jq -r '"VALID\t"+(.valid|tostring)+"\tERRORS="+((.errors|length)|tostring)' /tmp/v
aws lambda invoke --function-name wsc2026-order-validator --payload '{"order_id":"BAD","product_id":"","quantity":0,"unit_price":-1,"payment_method":"X"}' /tmp/i --cli-binary-format raw-in-base64-out >/dev/null 2>&1 && jq -r '"INVALID\t"+(.valid|tostring)+"\tERRORS="+((.errors|length)|tostring)' /tmp/i
echo

echo =====4-5=====
S=$(aws stepfunctions list-state-machines --query "stateMachines[?name=='wsc2026-order-pipeline'].stateMachineArn|[0]" --output text)
aws stepfunctions describe-state-machine --state-machine-arn $S --query '[name,type]' --output text 2>/dev/null
echo

echo =====4-6=====
E=$(aws stepfunctions start-execution --state-machine-arn $S --input "{\"bucket\":\"$B\",\"key\":\"incoming/sample-orders.json\"}" --query executionArn --output text 2>/dev/null); sleep 30
aws stepfunctions describe-execution --execution-arn $E --query status --output text 2>/dev/null
aws dynamodb scan --table-name wsc2026-orders --query Count --output text 2>/dev/null
A=$(aws dynamodb get-item --table-name wsc2026-inventory --key '{"product_id":{"S":"PROD-A100"}}' --query Item.stock.N --output text 2>/dev/null); B2=$(aws dynamodb get-item --table-name wsc2026-inventory --key '{"product_id":{"S":"PROD-B200"}}' --query Item.stock.N --output text 2>/dev/null); C=$(aws dynamodb get-item --table-name wsc2026-inventory --key '{"product_id":{"S":"PROD-C300"}}' --query Item.stock.N --output text 2>/dev/null); echo "$A	$B2	$C"
aws dynamodb scan --table-name wsc2026-pipeline-history --query 'Items[-1].[status.S,total_orders.N,processed_orders.N]' --output text 2>/dev/null
echo