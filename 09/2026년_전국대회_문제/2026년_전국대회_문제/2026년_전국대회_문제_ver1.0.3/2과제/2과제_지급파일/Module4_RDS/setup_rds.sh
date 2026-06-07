#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:-ap-northeast-3}"
CLUSTER_ID="${CLUSTER_ID:-rds-aurora-cluster}"
INSTANCE_ID="${INSTANCE_ID:-rds-aurora-cluster-instance-1}"
DB_NAME="${DB_NAME:-appdb}"
MASTER_USER="${MASTER_USER:-admin}"
SECRET_NAME="${SECRET_NAME:-rds/aurora/admin}"
LAMBDA_NAME="${LAMBDA_NAME:-rds-query-function}"
LAMBDA_ROLE_NAME="${LAMBDA_ROLE_NAME:-rds-query-function-role}"
ENGINE_VERSION="${ENGINE_VERSION:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ZIP_FILE="$(mktemp --suffix=.zip)"
TRUST_FILE="$(mktemp)"
POLICY_FILE="$(mktemp)"
SECRET_FILE="$(mktemp)"
RESPONSE_FILE="$(mktemp)"

cleanup() {
  rm -f "$ZIP_FILE" "$TRUST_FILE" "$POLICY_FILE" "$SECRET_FILE" "$RESPONSE_FILE"
}
trap cleanup EXIT

if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" >/dev/null 2>&1; then
  SECRET_ARN="$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" --query ARN --output text)"
  MASTER_PASSWORD="$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --query SecretString --output text | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')"
else
  MASTER_PASSWORD="$(python3 - <<'PY'
import random
import string
alphabet = string.ascii_letters + string.digits
print("Aa1" + "".join(random.choice(alphabet) for _ in range(21)))
PY
)"
  cat > "$SECRET_FILE" <<JSON
{"username":"$MASTER_USER","password":"$MASTER_PASSWORD","engine":"mysql","dbname":"$DB_NAME"}
JSON
  SECRET_ARN="$(aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --secret-string "file://$SECRET_FILE" \
    --tags Key=Module,Value=RDSConnection \
    --region "$REGION" \
    --query ARN \
    --output text)"
fi

if ! aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" --region "$REGION" >/dev/null 2>&1; then
  if [[ -z "$ENGINE_VERSION" ]]; then
    ENGINE_VERSION="$(aws rds describe-db-engine-versions \
      --engine aurora-mysql \
      --region "$REGION" \
      --query "reverse(sort_by(DBEngineVersions[?starts_with(EngineVersion, '8.0.mysql_aurora.3.')], &EngineVersion))[0].EngineVersion" \
      --output text)"
  fi

  CREATE_ARGS=(
    --db-cluster-identifier "$CLUSTER_ID"
    --engine aurora-mysql
    --engine-version "$ENGINE_VERSION"
    --database-name "$DB_NAME"
    --master-username "$MASTER_USER"
    --master-user-password "$MASTER_PASSWORD"
    --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=4
    --enable-http-endpoint
    --tags Key=Module,Value=RDSConnection
    --region "$REGION"
  )
  aws rds create-db-cluster "${CREATE_ARGS[@]}" >/dev/null
fi

if ! aws rds describe-db-instances --db-instance-identifier "$INSTANCE_ID" --region "$REGION" >/dev/null 2>&1; then
  aws rds create-db-instance \
    --db-instance-identifier "$INSTANCE_ID" \
    --db-cluster-identifier "$CLUSTER_ID" \
    --engine aurora-mysql \
    --db-instance-class db.serverless \
    --tags Key=Module,Value=RDSConnection \
    --region "$REGION" >/dev/null
fi

aws rds wait db-instance-available --db-instance-identifier "$INSTANCE_ID" --region "$REGION"
aws rds wait db-cluster-available --db-cluster-identifier "$CLUSTER_ID" --region "$REGION"
aws rds enable-http-endpoint --resource-arn "arn:aws:rds:$REGION:$ACCOUNT_ID:cluster:$CLUSTER_ID" --region "$REGION" >/dev/null || true

CLUSTER_ARN="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" --region "$REGION" --query 'DBClusters[0].DBClusterArn' --output text)"

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
      "Action": "rds-data:ExecuteStatement",
      "Resource": "$CLUSTER_ARN"
    },
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "$SECRET_ARN"
    }
  ]
}
JSON

aws iam put-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-name rds-query-function-policy --policy-document "file://$POLICY_FILE"
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
  aws lambda update-function-configuration \
    --function-name "$LAMBDA_NAME" \
    --timeout 60 \
    --environment "Variables={CLUSTER_ARN=$CLUSTER_ARN,SECRET_ARN=$SECRET_ARN,DB_NAME=$DB_NAME}" \
    --region "$REGION" >/dev/null
else
  aws lambda create-function \
    --function-name "$LAMBDA_NAME" \
    --runtime python3.12 \
    --role "$LAMBDA_ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --timeout 60 \
    --zip-file "fileb://$ZIP_FILE" \
    --environment "Variables={CLUSTER_ARN=$CLUSTER_ARN,SECRET_ARN=$SECRET_ARN,DB_NAME=$DB_NAME}" \
    --tags Module=RDSConnection \
    --region "$REGION" >/dev/null
fi

aws lambda wait function-active-v2 --function-name "$LAMBDA_NAME" --region "$REGION"
aws lambda invoke --function-name "$LAMBDA_NAME" --region "$REGION" "$RESPONSE_FILE" >/dev/null
cat "$RESPONSE_FILE"
echo
echo "RDS module is ready."
echo "Cluster ARN: $CLUSTER_ARN"
echo "Secret ARN: $SECRET_ARN"
