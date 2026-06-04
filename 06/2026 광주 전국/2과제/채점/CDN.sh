#!/bin/bash

echo =====1-0=====
sudo dnf install ImageMagick -y
echo

echo =====1-1=====
for fn in gj2026-cdn-rotate gj2026-cdn-request gj2026-cdn-response; do aws \
  lambda get-function --function-name $fn --region us-east-1 \
  --query 'Configuration.[FunctionName,Runtime,State]'; done; \
aws lambda get-function-url-config --function-name gj2026-cdn-rotate \
  --region us-east-1 --query '[FunctionUrl,AuthType]'
EXPECTED_HASH="b9e2027f47e6697ea180bbec0e31e438515050bfbdebef720d3a7b65c58c1a2e"
DOMAIN=$(aws cloudfront list-distributions \
  --query 'DistributionList.Items[0].DomainName' --output text)
ACTUAL_HASH=$(curl -s "https://$DOMAIN/images?image=dog&rotate=0" | sha256sum | cut -d' ' -f1)
[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] && echo "일치" || echo "불일치 (actual: $ACTUAL_HASH)"
echo

echo =====1-2=====
DIST_ID=$(aws cloudfront list-distributions \
  --query 'DistributionList.Items[0].Id' --output text); \
aws cloudfront list-distributions \
  --query 'DistributionList.Items[0].[Id,DomainName,Status]' --output text; \
aws cloudfront get-distribution-config --id $DIST_ID \
  --query 'DistributionConfig.CacheBehaviors.Items[?PathPattern==`/images`].LambdaFunctionAssociations' \
  | grep -o "gj2026-cdn-[a-z]*"
echo

echo =====1-3=====
DOMAIN=$(aws cloudfront list-distributions \
  --query 'DistributionList.Items[0].DomainName' --output text); \
curl -so /dev/null -w "rotate=0 1st: %header{x-cache}\n" \
  "https://$DOMAIN/images?image=dog&rotate=0"; \
curl -so /dev/null -w "rotate=0 2nd: %header{x-cache}\n" \
  "https://$DOMAIN/images?image=dog&rotate=0"; \
curl -so /dev/null -w "rotate=90 1st: %header{x-cache}\n" \
  "https://$DOMAIN/images?image=dog&rotate=90"
echo

echo =====1-4=====
DOMAIN=$(aws cloudfront list-distributions \
  --query 'DistributionList.Items[0].DomainName' --output text); \
curl -so /dev/null -w "1st : %{time_total}s | %header{x-cache}\n" \
  "https://$DOMAIN/images?image=dog&rotate=180"; \
curl -so /dev/null -w "2nd : %{time_total}s | %header{x-cache}\n" \
  "https://$DOMAIN/images?image=dog&rotate=180"
echo

echo =====1-5=====
DOMAIN=$(aws cloudfront list-distributions \
  --query 'DistributionList.Items[0].DomainName' --output text); \
curl -s "https://$DOMAIN/images?image=dog&rotate=0" > /tmp/orig.png; \
curl -s "https://$DOMAIN/images?image=dog&rotate=90" | convert - -rotate -90 /tmp/rot90_restored.png; \
compare -metric MAE /tmp/orig.png /tmp/rot90_restored.png /dev/null 2>&1 \
  | awk '{print "rotate=90 diff: "$1}'; \
curl -s "https://$DOMAIN/images?image=dog&rotate=180" | convert - -rotate 180 /tmp/rot180_restored.png; \
compare -metric MAE /tmp/orig.png /tmp/rot180_restored.png /dev/null 2>&1 \
  | awk '{print "rotate=180 diff: "$1}'
echo
