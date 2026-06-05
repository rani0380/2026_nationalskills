#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:-ap-southeast-1}"
TEAM_ID="${TEAM_ID:?Set TEAM_ID to your assigned number, for example: export TEAM_ID=1234}"
BUCKET_NAME="${BUCKET_NAME:-workflow-input-${TEAM_ID}}"
TABLE_NAME="${TABLE_NAME:-workflow-output}"
LAMBDA_NAME="${LAMBDA_NAME:-workflow-transform}"
STATE_MACHINE_NAME="${STATE_MACHINE_NAME:-workflow-state-machine}"
LAMBDA_ROLE_NAME="${LAMBDA_ROLE_NAME:-workflow-transform-role}"
SFN_ROLE_NAME="${SFN_ROLE_NAME:-workflow-state-machine-role}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ZIP_FILE="$(mktemp --suffix=.zip)"
TRUST_FILE="$(mktemp)"
POLICY_FILE="$(mktemp)"
SFN_POLICY_FILE="$(mktemp)"
STATE_FILE="$(mktemp)"

cleanup() {
  rm -f "$ZIP_FILE" "$TRUST_FILE" "$POLICY_FILE" "$SFN_POLICY_FILE" "$STATE_FILE"
}
trap cleanup EXIT

if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
fi
aws s3api put-bucket-tagging --bucket "$BUCKET_NAME" --tagging "TagSet=[{Key=Module,Value=Workflow}]"
aws s3 cp "$SCRIPT_DIR/data.csv" "s3://$BUCKET_NAME/data.csv" --region "$REGION"

if ! aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" >/dev/null 2>&1; then
  aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=id,AttributeType=S \
    --key-schema AttributeName=id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --tags Key=Module,Value=Workflow \
    --region "$REGION"
  aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
fi

cat > "$TRUST_FILE" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

if ! aws iam get-role --role-name "$LAMBDA_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$LAMBDA_ROLE_NAME" --assume-role-policy-document "file://$TRUST_FILE" >/dev/null
fi

cat > "$POLICY_FILE" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::$BUCKET_NAME/*"
    },
    {
      "Effect": "Allow",
      "Action": ["dynamodb:PutItem", "dynamodb:BatchWriteItem"],
      "Resource": "arn:aws:dynamodb:$REGION:$ACCOUNT_ID:table/$TABLE_NAME"
    }
  ]
}
JSON

aws iam put-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-name workflow-transform-policy --policy-document "file://$POLICY_FILE"
LAMBDA_ROLE_ARN="$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --query Role.Arn --output text)"
sleep 10

python3 - "$SCRIPT_DIR/lambda_function.py" "$ZIP_FILE" <<'PY'
import sys
import zipfile

source, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
    z.write(source, "lambda_function.py")
PY

if aws lambda get-function --function-name "$LAMBDA_NAME" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$LAMBDA_NAME" --zip-file "fileb://$ZIP_FILE" --region "$REGION" >/dev/null
  aws lambda update-function-configuration --function-name "$LAMBDA_NAME" --timeout 60 --environment "Variables={TABLE_NAME=$TABLE_NAME}" --region "$REGION" >/dev/null
else
  aws lambda create-function \
    --function-name "$LAMBDA_NAME" \
    --runtime python3.12 \
    --role "$LAMBDA_ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --timeout 60 \
    --zip-file "fileb://$ZIP_FILE" \
    --environment "Variables={TABLE_NAME=$TABLE_NAME}" \
    --tags Module=Workflow \
    --region "$REGION" >/dev/null
fi

LAMBDA_ARN="$(aws lambda get-function --function-name "$LAMBDA_NAME" --region "$REGION" --query Configuration.FunctionArn --output text)"

cat > "$TRUST_FILE" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "states.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

if ! aws iam get-role --role-name "$SFN_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$SFN_ROLE_NAME" --assume-role-policy-document "file://$TRUST_FILE" >/dev/null
fi

cat > "$SFN_POLICY_FILE" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "lambda:InvokeFunction",
      "Resource": "$LAMBDA_ARN"
    }
  ]
}
JSON

aws iam put-role-policy --role-name "$SFN_ROLE_NAME" --policy-name workflow-state-machine-policy --policy-document "file://$SFN_POLICY_FILE"
SFN_ROLE_ARN="$(aws iam get-role --role-name "$SFN_ROLE_NAME" --query Role.Arn --output text)"

cat > "$STATE_FILE" <<JSON
{
  "Comment": "WSC 2026 workflow pipeline",
  "StartAt": "ValidateInput",
  "States": {
    "ValidateInput": {
      "Type": "Pass",
      "Next": "TransformAndSave"
    },
    "TransformAndSave": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "$LAMBDA_ARN",
        "Payload.$": "$"
      },
      "Next": "Success"
    },
    "Success": {
      "Type": "Succeed"
    }
  }
}
JSON

if aws stepfunctions describe-state-machine --state-machine-arn "arn:aws:states:$REGION:$ACCOUNT_ID:stateMachine:$STATE_MACHINE_NAME" --region "$REGION" >/dev/null 2>&1; then
  STATE_MACHINE_ARN="arn:aws:states:$REGION:$ACCOUNT_ID:stateMachine:$STATE_MACHINE_NAME"
  aws stepfunctions update-state-machine --state-machine-arn "$STATE_MACHINE_ARN" --definition "file://$STATE_FILE" --role-arn "$SFN_ROLE_ARN" --region "$REGION" >/dev/null
else
  STATE_MACHINE_ARN="$(aws stepfunctions create-state-machine \
    --name "$STATE_MACHINE_NAME" \
    --type STANDARD \
    --role-arn "$SFN_ROLE_ARN" \
    --definition "file://$STATE_FILE" \
    --tags key=Module,value=Workflow \
    --region "$REGION" \
    --query stateMachineArn \
    --output text)"
fi

aws stepfunctions start-execution \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --input "{\"bucket\":\"$BUCKET_NAME\",\"key\":\"data.csv\"}" \
  --region "$REGION"

echo "Workflow module started."
echo "Check DynamoDB table: $TABLE_NAME"
