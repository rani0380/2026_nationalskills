#!/bin/bash

# 1. S3 버킷 및 EventBridge 알림 설정 확인
aws s3api head-bucket --bucket wsc2026-wf-inbound-bucket 2>/dev/null && echo "S3 Bucket: wsc2026-wf-inbound-bucket (Exists)"
aws s3api get-bucket-notification-configuration --bucket wsc2026-wf-inbound-bucket --query "EventBridgeConfiguration" --output json 2>/dev/null

# 2. EventBridge 규칙 확인 (us-east-1)
aws events describe-rule --name wsc2026-s3-trigger-rule --region us-east-1 --query "{Name:Name,State:State}" --output table

# 3. Lambda 함수 설정 확인
aws lambda get-function-configuration --function-name wsc2026-transform-lambda --query "{FunctionName:FunctionName,Runtime:Runtime}" --output table

# 4. Lambda 함수 호출 테스트 (임시 파일 자동 삭제)
aws lambda invoke --function-name wsc2026-transform-lambda \
  --payload '{"detail":{"bucket":{"name":"wsc2026-wf-inbound-bucket"},"object":{"key":"test.json"}}}' \
  --cli-binary-format raw-in-base64-out response_normal.json >/dev/null 2>&1
if [ -f response_normal.json ]; then
    cat response_normal.json && echo ""
    rm -f response_normal.json
fi

# 5. DynamoDB 테이블 확인
aws dynamodb describe-table --table-name wsc2026-target-db --query "Table.[TableName, BillingModeSummary.BillingMode]" --output text 2>/dev/null || \
aws dynamodb describe-table --table-name wsc2026-target-db --query "Table.TableName" --output text

# 6. 통합 테스트 (S3 업로드 -> Step Functions -> DynamoDB 확인)
echo '{"id":"abc123","data":"sample_value"}' > test.json
aws s3 cp test.json s3://wsc2026-wf-inbound-bucket/test.json >/dev/null

sleep 5

SF_ARN=$(aws stepfunctions list-state-machines --query "stateMachines[0].stateMachineArn" --output text)
if [ -n "$SF_ARN" ] && [ "$SF_ARN" != "None" ]; then
    aws stepfunctions list-executions --state-machine-arn "$SF_ARN" --query "executions[0].{status:status,name:name}" --output table
fi

aws dynamodb get-item --table-name wsc2026-target-db --key '{"id":{"S":"abc123"}}' --query "Item" --output json

# 로컬 임시 파일 생성 정리
rm -f test.json