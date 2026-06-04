
echo "============================="
rm -rf ~/.aws
mkdir -p ~/.aws
echo "사전준비 시작!"

export DistributionID="<CloudFront_Distribution_ID>"
export BUCKET="gj2026-static-<비번호>"
export CF_DOMAIN=$(aws cloudfront get-distribution --id ${DistributionID} --query "Distribution.DomainName" --output text)
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws configure set default.region ap-northeast-2
aws eks update-kubeconfig --name gj2026-eks-cluster >/dev/null 2>&1
aws ecr get-login-password --region ap-northeast-2 2>/dev/null | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.ap-northeast-2.amazonaws.com >/dev/null 2>&1
export InvalidationID=$(aws cloudfront create-invalidation --distribution-id ${DistributionID} --paths "/*" --query "Invalidation.Id" --output text)
aws cloudfront wait invalidation-completed --distribution-id ${DistributionID} --id ${InvalidationID}

echo "사전준비 완료! 채점 시작!"

echo -e "============1-1-A============"
aws ec2 describe-vpcs --filter Name=tag:Name,Values=gj2026-vpc --query Vpcs[0].CidrBlock
aws ec2 describe-subnets --filters Name=vpc-id,Values=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=gj2026-vpc --query 'Vpcs[0].VpcId' --output text) --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,CidrBlock,AvailabilityZone]'   --output text | sort

echo -e "\n============1-2-A============"
aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=gj2026-private-subnet-a,gj2026-private-subnet-b --query 'Subnets[].SubnetId' --output text | xargs | sed 's/ /,/g')" --query 'sort_by(RouteTables,&Tags[?Key==`Name`]|[0].Value)[].{RT:Tags[?Key==`Name`]|[0].Value,Routes:Routes[].DestinationCidrBlock}' --output text

echo -e "\n============1-3-A============"
aws ec2 describe-nat-gateways --query 'length(NatGateways)'
aws ec2 describe-internet-gateways --query 'InternetGateways[].Tags[?Key==`Name`].Value[]' --output text

echo -e "\n============2-1-A============"
aws ecr describe-repositories --repository-names "book" --query 'repositories[0].repositoryName' --output text

echo -e "\n============2-2-A============"
book_size_bytes=$(aws ecr describe-images --repository-name "book" --query 'imageDetails[?imageTags[0]==`latest`].imageSizeInBytes' --output text)
book_size_mb=$(awk "BEGIN {printf \"%.2f\", $book_size_bytes / 1024 / 1024}")
echo "${book_size_mb}mb"

echo -e "\n============3-1-A============"
aws dynamodb describe-table --table-name books --query "{TablePK:Table.KeySchema[0].AttributeName,GSI:Table.GlobalSecondaryIndexes[*].{IndexName:IndexName,PK:KeySchema[0].AttributeName}}" --output text

echo -e "\n============3-2-A============"
aws kms list-aliases --query "Aliases[?TargetKeyId=='$(aws dynamodb describe-table --table-name books --query 'Table.SSEDescription.KMSMasterKeyArn' --output text | awk -F'/' '{print $2}')'].AliasName" --output text

echo -e "\n============3-3-A============"
aws dynamodb put-item --table-name books --item '{"booking_id":{"S":"score-test-001"},"client_id":{"S":"D002"},"username":{"S":"David"},"email":{"S":"lim@example.com"},"concert_name":{"S":"Busan2025"}}' --region ap-northeast-2

echo -e "\n============4-1-A============"
aws eks describe-cluster --name gj2026-eks-cluster --query "cluster.[name,version,status,resourcesVpcConfig.endpointPublicAccess,resourcesVpcConfig.endpointPrivateAccess]" --output text && aws kms list-aliases --query "Aliases[?TargetKeyId=='$(aws eks describe-cluster --name gj2026-eks-cluster --query 'cluster.encryptionConfig[0].provider.keyArn' --output text | cut -d/ -f2)'].AliasName" --output text

echo -e "\n============4-2-A============"
for ng in $(aws eks list-nodegroups --cluster-name gj2026-eks-cluster --query 'nodegroups[*]' --output text); do aws eks describe-nodegroup --cluster-name gj2026-eks-cluster --nodegroup-name $ng --query "nodegroup.[nodegroupName,amiType,instanceTypes[0],scalingConfig.desiredSize]" --output text; done

echo -e "\n============4-3-A============"
kubectl get nodes -o custom-columns=NAME:.metadata.name --no-headers | while read n; do id=$(echo $n | cut -d. -f2);   aws ec2 describe-instances --instance-ids $id --filters Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text | grep -q $id && echo $n; done

echo -e "\n============4-4-A============"
kubectl get deployment -n skills book

echo -e "\n============4-5-A============"
docker pull ${ACCOUNT_ID}.dkr.ecr.ap-northeast-2.amazonaws.com/ecr-public/nginx/nginx:latest >/dev/null 2>&1 && kubectl run nginx-test -n skills --image=${ACCOUNT_ID}.dkr.ecr.ap-northeast-2.amazonaws.com/ecr-public/nginx/nginx:latest --restart=Never 2>/dev/null && sleep 3 && kubectl exec -n skills nginx-test -- curl -m 5 -sS http://book-svc:8080/health 2>&1 | grep -v '^Defaulted container'

echo -e "\n============5-1-A============"
aws elbv2 describe-load-balancers --names gj2026-alb \
 --query 'LoadBalancers[0].Scheme' --output text && \
aws ec2 describe-tags \
 --filters "Name=resource-id,Values=$(aws elbv2 describe-load-balancers --names gj2026-alb --query 'LoadBalancers[0].VpcId' --output text)" \
 --query "Tags[?Key=='Name'].Value | [0]" --output text

echo -e "\n============6-1-A============"
aws s3api list-objects-v2 --bucket $BUCKET --query 'Contents[?contains(Key, `/`)==`false`].Key' --output text

echo -e "\n============6-2-A============"
aws kms list-aliases --query "Aliases[?TargetKeyId=='$(aws s3api get-bucket-encryption --bucket $BUCKET --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID' --output text | awk -F'/' '{print $NF}')'].AliasName" --output text

echo -e "\n============7-1-A============"
aws lambda get-function --function-name gj2026-book-reservation --query 'Configuration.[FunctionName,Runtime,State]' --output text

echo -e "\n============8-1-A============"
curl -s -o /dev/null -w "%{http_code} %header{x-cache}\n" https://${CF_DOMAIN}
curl -s -o /dev/null -w "%{http_code} %header{x-cache}\n" https://${CF_DOMAIN}/main.jpeg
curl -s -o /dev/null -w "%{http_code} %header{x-cache}\n" https://${CF_DOMAIN}/index.html

echo -e "\n============8-2-A============"
curl -X POST \
     -H "Content-Type: application/json" \
     -d '{"client_id": "C001", "username": "Alice", "email": "kim@example.com", "concert_name": "Busan2025"}' \
     https://${CF_DOMAIN}/v1/book
curl -X POST \
     -H "Content-Type: application/json" \
     -d '{"client_id": "C002", "username": "Bob", "email": "han@example.com", "concert_name": "Seoul2025"}' \
     https://${CF_DOMAIN}/v1/book

echo -e "\n============8-3-A============"
date
curl https://${CF_DOMAIN}/reservation

echo -e "\n============8-4-A============"
curl https://${CF_DOMAIN}/reservation?client_id=C001

echo -e "\n============9-1-A============"
curl -s -w " %{http_code}" https://${CF_DOMAIN}/v1/book

echo -e "\n============9-2-A============"
curl -s -w " %{http_code}" "https://${CF_DOMAIN}/reservation?client_id=123abc"; 
curl -s -w " %{http_code}" "https://${CF_DOMAIN}/reservation?client_id=C#001"; 
curl -s -w " %{http_code}" "https://${CF_DOMAIN}/reservation?client_id=홍길동"; 

echo -e "\n============10-1-A============"
aws logs delete-log-group --log-group-name /eks/book-svc/access 2>/dev/null
kubectl -n logging rollout restart ds/aws-for-fluent-bit
for i in {1..10}; do curl -sX POST https://$CF_DOMAIN/v1/book > /dev/null; sleep 1; done
sleep 3
for s in $(aws logs describe-log-streams --log-group-name /eks/book-svc/access --query 'logStreams[].logStreamName' --output text); do
  echo "(stream: $s ip: $(aws logs get-log-events --log-group-name /eks/book-svc/access --log-stream-name "$s" --limit 1 --query 'events[0].message' --output text | jq -r '.remote_addr|split(":")[0]'))"
done

echo -e "\n============10-2-A============"
echo "${CF_DOMAIN}"/grafana
echo "수동채점"