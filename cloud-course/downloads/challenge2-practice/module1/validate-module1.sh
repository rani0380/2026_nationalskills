#!/usr/bin/env bash
set -u

REGION="ap-northeast-2"
PASS=0
FAIL=0

check() {
  local title="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'PASS  %s\n' "$title"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %s\n' "$title"
    FAIL=$((FAIL + 1))
  fi
}

table_active() {
  aws dynamodb describe-table --region "$REGION" --table-name "$1" \
    --query 'Table.TableStatus' --output text | grep -qx ACTIVE
}

index_active() {
  aws dynamodb describe-table --region "$REGION" --table-name "$1" \
    --query "Table.GlobalSecondaryIndexes[?IndexName=='$2'].IndexStatus|[0]" \
    --output text | grep -qx ACTIVE
}

count_at_least() {
  local count
  count=$(aws dynamodb scan --region "$REGION" --table-name "$1" \
    --select COUNT --query Count --output text)
  [ "$count" -ge "$2" ]
}

echo "Module 1 자체 점검을 시작합니다. 리전: $REGION"
check "VPC practice-orders-vpc" bash -c \
  "aws ec2 describe-vpcs --region $REGION --filters Name=tag:Name,Values=practice-orders-vpc --query 'Vpcs[?CidrBlock==\`10.81.0.0/16\`].VpcId|[0]' --output text | grep -q '^vpc-'"
check "Client EC2 running, t3.micro, Public IP" bash -c \
  "aws ec2 describe-instances --region $REGION --filters Name=tag:Name,Values=practice-orders-client Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].[InstanceType,PublicIpAddress]' --output text | grep -Eq 't3.micro[[:space:]]+[0-9]'"
check "practice-orders ACTIVE" table_active practice-orders
check "practice-products ACTIVE" table_active practice-products
check "practice-sessions ACTIVE" table_active practice-sessions
check "CustomerCreatedAtIndex ACTIVE" index_active practice-orders CustomerCreatedAtIndex
check "WarehouseStockIndex ACTIVE" index_active practice-products WarehouseStockIndex
check "Sessions TTL ENABLED" bash -c \
  "aws dynamodb describe-time-to-live --region $REGION --table-name practice-sessions --query 'TimeToLiveDescription.[TimeToLiveStatus,AttributeName]' --output text | grep -Eq 'ENABLED[[:space:]]+expiresAt'"
check "Orders PITR ENABLED" bash -c \
  "aws dynamodb describe-continuous-backups --region $REGION --table-name practice-orders --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus' --output text | grep -qx ENABLED"
check "Orders customer-managed KMS" bash -c \
  "aws dynamodb describe-table --region $REGION --table-name practice-orders --query 'Table.SSEDescription.[Status,SSEType,KMSMasterKeyArn]' --output text | grep -Eq 'ENABLED.*KMS.*arn:aws:kms'"
check "Orders 8개 이상" count_at_least practice-orders 8
check "Products 6개 이상" count_at_least practice-products 6
check "Sessions 3개 이상" count_at_least practice-sessions 3

CLIENT_IP=$(aws ec2 describe-instances --region "$REGION" \
  --filters Name=tag:Name,Values=practice-orders-client Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null || true)
if [ -n "$CLIENT_IP" ] && [ "$CLIENT_IP" != "None" ]; then
  check "GET /health" curl -fsS -m 10 "http://${CLIENT_IP}:8080/health"
  check "GET /v1/orders/O-2001" curl -fsS -m 10 "http://${CLIENT_IP}:8080/v1/orders/O-2001"
  check "GET /v1/customers/C101/orders" curl -fsS -m 10 "http://${CLIENT_IP}:8080/v1/customers/C101/orders"
  check "GET /v1/products/low-stock" curl -fsS -m 10 "http://${CLIENT_IP}:8080/v1/products/low-stock?warehouseId=WH-A"
else
  printf 'FAIL  Client Public IP 확인\n'
  FAIL=$((FAIL + 4))
fi

echo
printf '결과: PASS %d / FAIL %d / TOTAL %d\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
