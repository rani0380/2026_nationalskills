#!/bin/bash

# 1. DynamoDB 테이블 이름 및 빌링 모드
aws dynamodb describe-table --table-name wsc2026-api-storage --query "Table.TableName" --output text
aws dynamodb describe-table --table-name wsc2026-api-storage --query "Table.BillingModeSummary.BillingMode" --output text 2>/dev/null || echo "PROVISIONED"

# 2. Lambda 함수 이름 및 런타임
aws lambda get-function --function-name wsc2026-api-handler --query "Configuration.FunctionName" --output text
aws lambda get-function-configuration --function-name wsc2026-api-handler --query "Runtime" --output text

# 3. IAM 역할 정책 (ROLE_NAME 변수 필요)
if [ -n "$ROLE_NAME" ]; then
    for arn in $(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query "AttachedPolicies[*].PolicyArn" --output text); do
        VERSION=$(aws iam get-policy --policy-arn "$arn" --query "Policy.DefaultVersionId" --output text)
        aws iam get-policy-version --policy-arn "$arn" --version-id "$VERSION" --query "PolicyVersion.Document" --output json
    done
fi

# 4. Lambda 함수 호출 및 결과 출력 (임시 파일 자동 삭제)
aws lambda invoke --function-name wsc2026-api-handler --payload '{"method": "GET", "id": "lambda-chk-999"}' --cli-binary-format raw-in-base64-out out_l_get.json >/dev/null 2>&1
if [ -f out_l_get.json ]; then
    cat out_l_get.json && echo ""
    rm -f out_l_get.json
fi

# 5. API Gateway 정보 조회 및 테스트
API_ID=$(aws apigateway get-rest-apis --query "items[?name=='wsc2026-rest-api'].id" --output text)

if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
    # 리소스 메서드 및 스테이지 이름 출력
    aws apigateway get-resources --rest-api-id "$API_ID" --query "items[?path=='/item'].resourceMethods" --output json
    STAGE_NAME=$(aws apigateway get-stages --rest-api-id "$API_ID" --query "item[0].stageName" --output text)
    echo "$STAGE_NAME"

    # API POST 요청 테스트
    REGION=$(aws configure get region)
    [ -z "$REGION" ] && REGION="ap-northeast-2"
    URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/${STAGE_NAME}/item"
    curl -s -X POST -H "Content-Type: application/json" -d '{"id": "api-chk-888", "name": "Check-Api", "team": "Cloud"}' "$URL" && echo ""
fi