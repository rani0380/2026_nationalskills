#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:-us-east-1}"
TEAM_ID="${TEAM_ID:?Set TEAM_ID to your assigned number, for example: export TEAM_ID=1234}"
BUCKET_NAME="${BUCKET_NAME:-cdn-static-${TEAM_ID}}"
OAC_NAME="${OAC_NAME:-cdn-oac}"
FUNCTION_NAME="${FUNCTION_NAME:-cdn-add-security-header}"
DIST_COMMENT="${DIST_COMMENT:-cdn-${TEAM_ID}}"
CALLER_REFERENCE="wsc2026-cdn-${TEAM_ID}-$(date +%s)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION"
fi

aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3 sync "$SCRIPT_DIR" "s3://$BUCKET_NAME" \
  --exclude "setup_cdn.sh" \
  --exclude "cdn-add-security-header.js"

OAC_ID="$(aws cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id | [0]" \
  --output text)"

if [[ "$OAC_ID" == "None" || -z "$OAC_ID" ]]; then
  OAC_ID="$(aws cloudfront create-origin-access-control \
    --origin-access-control-config "Name=${OAC_NAME},Description=WSC 2026 OAC,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
    --query "OriginAccessControl.Id" \
    --output text)"
fi

if ! aws cloudfront describe-function --name "$FUNCTION_NAME" >/dev/null 2>&1; then
  aws cloudfront create-function \
    --name "$FUNCTION_NAME" \
    --function-config Comment="Add WSC custom response header",Runtime=cloudfront-js-2.0 \
    --function-code "fileb://${SCRIPT_DIR}/cdn-add-security-header.js" >/dev/null
fi

ETAG="$(aws cloudfront describe-function --name "$FUNCTION_NAME" --stage DEVELOPMENT --query ETag --output text)"
FUNCTION_ARN="$(aws cloudfront publish-function --name "$FUNCTION_NAME" --if-match "$ETAG" --query FunctionSummary.FunctionMetadata.FunctionARN --output text)"

DIST_CONFIG="$(mktemp)"
DIST_RESPONSE="$(mktemp)"
POLICY_FILE="$(mktemp)"
cleanup() {
  rm -f "$DIST_CONFIG" "$DIST_RESPONSE" "$POLICY_FILE"
}
trap cleanup EXIT

cat > "$DIST_CONFIG" <<JSON
{
  "CallerReference": "$CALLER_REFERENCE",
  "Aliases": {
    "Quantity": 0
  },
  "Comment": "$DIST_COMMENT",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "$BUCKET_NAME-origin",
        "DomainName": "$BUCKET_NAME.s3.$REGION.amazonaws.com",
        "OriginAccessControlId": "$OAC_ID",
        "S3OriginConfig": {
          "OriginAccessIdentity": ""
        }
      }
    ]
  },
  "OriginGroups": {
    "Quantity": 0
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "$BUCKET_NAME-origin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"],
      "CachedMethods": {
        "Quantity": 2,
        "Items": ["GET", "HEAD"]
      }
    },
    "TrustedSigners": {
      "Enabled": false,
      "Quantity": 0
    },
    "TrustedKeyGroups": {
      "Enabled": false,
      "Quantity": 0
    },
    "SmoothStreaming": false,
    "LambdaFunctionAssociations": {
      "Quantity": 0
    },
    "Compress": true,
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
    "FieldLevelEncryptionId": "",
    "FunctionAssociations": {
      "Quantity": 1,
      "Items": [
        {
          "EventType": "viewer-response",
          "FunctionARN": "$FUNCTION_ARN"
        }
      ]
    }
  },
  "CacheBehaviors": {
    "Quantity": 0
  },
  "CustomErrorResponses": {
    "Quantity": 0
  },
  "PriceClass": "PriceClass_100",
  "ViewerCertificate": {
    "CloudFrontDefaultCertificate": true
  },
  "Restrictions": {
    "GeoRestriction": {
      "RestrictionType": "none",
      "Quantity": 0
    }
  },
  "HttpVersion": "http2",
  "IsIPV6Enabled": true
}
JSON

aws cloudfront create-distribution --distribution-config "file://$DIST_CONFIG" > "$DIST_RESPONSE"
DIST_ID="$(python3 - "$DIST_RESPONSE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
print(data["Distribution"]["Id"])
PY
)"
DOMAIN_NAME="$(python3 - "$DIST_RESPONSE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
print(data["Distribution"]["DomainName"])
PY
)"

cat > "$POLICY_FILE" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontServicePrincipalReadOnly",
      "Effect": "Allow",
      "Principal": {
        "Service": "cloudfront.amazonaws.com"
      },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::$BUCKET_NAME/*",
      "Condition": {
        "StringEquals": {
          "AWS:SourceArn": "arn:aws:cloudfront::$ACCOUNT_ID:distribution/$DIST_ID"
        }
      }
    }
  ]
}
JSON

aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy "file://$POLICY_FILE"
aws cloudfront tag-resource --resource "arn:aws:cloudfront::$ACCOUNT_ID:distribution/$DIST_ID" --tags "Items=[{Key=Module,Value=CDN}]"

echo "Distribution ID: $DIST_ID"
echo "Domain: https://$DOMAIN_NAME"
echo "Verify after deployment:"
echo "curl -sI \"https://$DOMAIN_NAME/index.html?v=1\" | grep -i X-Custom-Header"
