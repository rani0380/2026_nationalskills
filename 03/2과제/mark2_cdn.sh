#!/bin/bash

echo =====1-1=====
CN=$(aws s3api list-buckets --query "Buckets[?contains(Name,'wsc2026-cdn-asset')].Name|[0]" --output text | sed 's/wsc2026-cdn-asset-//'); B="wsc2026-cdn-asset-$CN"
echo $B
aws s3api get-bucket-versioning --bucket $B --query Status --output text
aws s3api get-public-access-block --bucket $B --query '[PublicAccessBlockConfiguration.BlockPublicAcls,PublicAccessBlockConfiguration.BlockPublicPolicy,PublicAccessBlockConfiguration.IgnorePublicAcls,PublicAccessBlockConfiguration.RestrictPublicBuckets]' --output text
aws s3 ls s3://$B/origin/ 2>/dev/null | awk '$3>0{print $4}'
echo

echo =====1-2=====
CF_ID=$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Name,Values=wsc2026-cdn --resource-type-filters cloudfront --query "ResourceTagMappingList[0].ResourceARN" --output text | sed 's:.*/::'); CF_DOMAIN=$(aws cloudfront get-distribution --id $CF_ID --query "Distribution.DomainName" --output text)
echo "$CF_DOMAIN"; aws cloudfront get-distribution --id $CF_ID --query 'Distribution.DistributionConfig.Origins.Items[0].DomainName' --output text; aws cloudfront get-distribution --id $CF_ID --query 'Distribution.DistributionConfig.PriceClass' --output text
echo

echo =====1-3=====
aws cloudfront list-functions --query "FunctionList.Items[?contains(Name,'wsc2026')].{Name:Name,Stage:FunctionMetadata.Stage}" --output text | grep LIVE
echo

echo =====1-4=====
aws cloudfront get-distribution --id $CF_ID --query "Distribution.DistributionConfig.DefaultCacheBehavior.FunctionAssociations.Items[].[EventType,FunctionARN]" --output text
echo

echo =====1-5=====
aws lambda get-function --function-name wsc2026-resize --query "Configuration.[FunctionName,Runtime]" --output text 2>/dev/null
RN=$(aws lambda get-function --function-name wsc2026-resize --query "Configuration.Role" --output text 2>/dev/null | awk -F/ '{print $NF}'); echo "$RN"; aws iam list-attached-role-policies --role-name "$RN" --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null
aws cloudfront get-distribution --id $CF_ID --query "Distribution.DistributionConfig.DefaultCacheBehavior.LambdaFunctionAssociations.Items[].[EventType,LambdaFunctionARN]" --output text 2>/dev/null
echo

echo =====1-6=====
OF="origin/$(aws s3 ls s3://$B/origin/ 2>/dev/null | awk '$3>0{print $4}' | head -1)"; echo "$OF	$(aws s3api head-object --bucket $B --key "$OF" --query ContentLength --output text 2>/dev/null)"
NOW_UTC=$(date -u +%s); NOW_KST=$(date +%s); ME=113209; DE=121900; BUST=$(date +%s)
curl -s -o /tmp/m.png -D /tmp/m.txt -A "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" "https://$CF_DOMAIN/$OF?w=480&h=320&type=mobile&bust=$BUST"; echo "mobile	$(wc -c</tmp/m.png)	$(grep -i x-device-type /tmp/m.txt 2>/dev/null|awk '{print $2}'|tr -d '\r')	$(grep -i x-resized /tmp/m.txt 2>/dev/null|awk '{print $2}'|tr -d '\r')"
curl -s -o /tmp/d.png -D /tmp/d.txt -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0" "https://$CF_DOMAIN/$OF?w=1920&h=1080&type=desktop&bust=$BUST"; echo "desktop	$(wc -c</tmp/d.png)	$(grep -i x-device-type /tmp/d.txt 2>/dev/null|awk '{print $2}'|tr -d '\r')	$(grep -i x-resized /tmp/d.txt 2>/dev/null|awk '{print $2}'|tr -d '\r')"
aws s3 ls s3://$B/resized/ 2>/dev/null | awk '$3>0{print $1,$2,$4}' | tail -2 | while read D T F; do SD=$(( NOW_UTC - $(date -u -d "$D $T" +%s) )); TS=$(echo $F|grep -oP '\d{8}_\d{6}'|sed 's/\(....\)\(..\)\(..\)_\(..\)\(..\)\(..\)/\1-\2-\3 \4:\5:\6/'); FD=$(( NOW_KST - $(date -d "$TS" +%s) )); SZ=$(aws s3api head-object --bucket $B --key "resized/$F" --query ContentLength --output text 2>/dev/null); EX=$(echo $F|grep -q "^mobile" && echo $ME || echo $DE); [ "$SD" -le 60 ] && [ "$FD" -le 60 ] && [ "$SZ" -eq "$EX" ] && echo "$F : PASS" || echo "$F : FAIL (s3=${SD}s fname=${FD}s size=${SZ} expected=${EX})"; done
echo
