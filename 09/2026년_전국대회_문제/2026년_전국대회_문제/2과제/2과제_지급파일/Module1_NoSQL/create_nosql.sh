#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:-ap-northeast-2}"
TABLE_NAME="${TABLE_NAME:-nosql-products}"

if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "DynamoDB table already exists: $TABLE_NAME"
else
  aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions \
      AttributeName=product_id,AttributeType=S \
      AttributeName=category,AttributeType=S \
      AttributeName=price,AttributeType=N \
    --key-schema \
      AttributeName=product_id,KeyType=HASH \
      AttributeName=category,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --global-secondary-indexes '[
      {
        "IndexName": "category-price-index",
        "KeySchema": [
          {"AttributeName": "category", "KeyType": "HASH"},
          {"AttributeName": "price", "KeyType": "RANGE"}
        ],
        "Projection": {"ProjectionType": "ALL"}
      }
    ]' \
    --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
    --tags Key=Module,Value=NoSQL \
    --region "$REGION"

  aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
  echo "Created DynamoDB table: $TABLE_NAME"
fi

aws dynamodb update-table \
  --table-name "$TABLE_NAME" \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
  --region "$REGION" >/dev/null || true

echo "NoSQL module table is ready."
