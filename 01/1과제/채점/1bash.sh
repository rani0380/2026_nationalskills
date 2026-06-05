#!/bin/bash

export AWS_DEFAULT_REGION=ap-northeast-2


# =============================================================================
# 1-1 : VPC & Subnet
echo "[ 1-1 ] VPC & Subnet"
# =============================================================================
export VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=wsc-vpc" --query Vpcs[0].VpcId --output text)

aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=wsc-vpc" \
    --query 'Vpcs[*].{Name:Tags[?Key==`Name`]|[0].Value, CIDR:CidrBlock}'

aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[*].[Tags[?Key==`Name`]|[0].Value,CidrBlock]' \
    --output text


# =============================================================================
# 1-2 : Routing Table
echo "[ 1-2 ] Routing Table"
# =============================================================================
aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[?Tags[?Key==`Name`] && (Tags[?Value==`wsc-pub-rt`] || Tags[?Value==`wsc-priv-rt-a`] || Tags[?Value==`wsc-priv-rt-b`])].{
        Name: Tags[?Key==`Name`]|[0].Value,
        IGW_ID: Routes[?GatewayId!=null && GatewayId!=`local`]|[0].GatewayId,
        NatGW_ID: Routes[?NatGatewayId!=null]|[0].NatGatewayId}' \
    --output table


# =============================================================================
# 1-3 : IGW & NAT Gateway
echo "[ 1-3 ] IGW & NAT Gateway"
# =============================================================================
aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[*].{IGW_Name: Tags[?Key==`Name`]|[0].Value, IGW_ID: InternetGatewayId}' \
    --output table

aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=$VPC_ID" \
    --query 'NatGateways[*].{NatGW_Name: Tags[?Key==`Name`]|[0].Value, NatGW_ID: NatGatewayId}' \
    --output table


# =============================================================================
# 1-4 : Flow Logs
echo "[ 1-4 ] Flow Logs"
# =============================================================================
aws ec2 describe-flow-logs \
    --filter "Name=resource-id,Values=$VPC_ID" \
    --query 'FlowLogs[*].{Format: LogFormat, Destination: LogDestination, DestinationType: LogDestinationType, Status: FlowLogStatus}' \
    --output table


# =============================================================================
# 1-5 : Flow Logs KMS & Log Streams
echo "[ 1-5 ] Flow Logs KMS & Log Streams"
# =============================================================================
aws ec2 describe-flow-logs --query FlowLogs[*].LogGroupName --output text | tr $'\t' $'\n' | while read LOG_GROUP; do
    aws logs describe-log-groups \
        --log-group-name-prefix "$LOG_GROUP" \
        --query 'logGroups[*].{Name:logGroupName, KMS:kmsKeyId}'
done

aws ec2 describe-flow-logs --query FlowLogs[*].LogGroupName --output text | tr $'\t' $'\n' | while read LOG_GROUP; do
    aws logs describe-log-streams \
        --log-group-name "$LOG_GROUP" \
        --order-by LastEventTime --descending --max-items 1 \
        --query 'logStreams[*].{Stream:logStreamName, LastEvent:lastEventTimestamp}'
done


# =============================================================================
# 2-1 : S3 Bucket
echo "[ 2-1 ] S3 Bucket"
# =============================================================================
BUCKET_NAME=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, 'wsc-2026-bucket-')].Name" --output text)
echo "$BUCKET_NAME"

aws s3api get-public-access-block --bucket "$BUCKET_NAME"
aws s3api get-bucket-encryption --bucket "$BUCKET_NAME"


# =============================================================================
# 2-2A : CloudFront
echo "[ 2-2A ] CloudFront"
# =============================================================================
aws cloudfront list-distributions \
    --query "DistributionList.Items[].[Id,DomainName,Origins.Items[0].DomainName]" \
    --output table

DIST_ID=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(Origins.Items[0].DomainName, 'wsc-2026-bucket-')].Id" \
    --output text)
CF_DOMAIN=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(Origins.Items[0].DomainName, 'wsc-2026-bucket-')].DomainName" \
    --output text)
echo "$DIST_ID"
echo "$CF_DOMAIN"


# =============================================================================
# 2-2B : CloudFront curl & Functions
echo "[ 2-2B ] CloudFront curl & Functions"
# =============================================================================
curl -I "https://$CF_DOMAIN/index"
curl -I "https://$CF_DOMAIN/main"

aws cloudfront list-functions \
    --query "FunctionList.Items[?Name=='wsc-2026-functions'].[Name,FunctionConfig.Runtime,Status]" \
    --output table

aws cloudfront get-distribution-config \
    --id "$DIST_ID" \
    --query 'DistributionConfig.DefaultCacheBehavior.FunctionAssociations' \
    --output json


# =============================================================================
# 3-1A : ECR
echo "[ 3-1A ] ECR"
# =============================================================================
aws ecr describe-repositories \
    --repository-names book-ecr \
    --query 'repositories[0].{Name: repositoryName, Encryption: encryptionConfiguration, Mutability: imageTagMutability}' \
    --output table


# =============================================================================
# 3-1B : ECR Scan
echo "[ 3-1B ] ECR Scan"
# =============================================================================
aws ecr describe-repositories \
    --repository-names book-ecr \
    --query 'repositories[0].imageScanningConfiguration'

aws ecr describe-image-scan-findings \
    --repository-name book-ecr \
    --image-id imageTag=latest \
    --query 'imageScanFindings.findingSeverityCounts.{CRITICAL: CRITICAL || `0`, HIGH: HIGH || `0`}'


# =============================================================================
# 4-1 : DynamoDB
echo "[ 4-1 ] DynamoDB"
# =============================================================================
aws dynamodb describe-table \
    --table-name wsc-dynamo \
    --query 'Table.{TableName:TableName,BillingMode:BillingModeSummary.BillingMode,SSEStatus:SSEDescription.Status,SSEType:SSEDescription.SSEType,DeletionProtection:DeletionProtectionEnabled}' \
    --output table

aws dynamodb describe-continuous-backups \
    --table-name wsc-dynamo \
    --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription' \
    --output table


# =============================================================================
# 4-2 : AWS Backup
echo "[ 4-2 ] AWS Backup"
# =============================================================================
PLAN_ID=$(aws backup list-backup-plans --query 'BackupPlansList[0].BackupPlanId' --output text)
RULE_NAME=$(aws backup get-backup-plan --backup-plan-id "$PLAN_ID" --query 'BackupPlan.Rules[0].RuleName' --output text)
VAULT_NAME=$(aws backup get-backup-plan --backup-plan-id "$PLAN_ID" --query 'BackupPlan.Rules[0].TargetBackupVaultName' --output text)

aws backup update-backup-plan \
    --backup-plan-id "$PLAN_ID" \
    --backup-plan "{\"BackupPlanName\":\"wsc-dynamo-backup-plan\",\"Rules\":[{\"RuleName\":\"$RULE_NAME\",\"TargetBackupVaultName\":\"$VAULT_NAME\",\"ScheduleExpression\":\"cron(0 0 * * ? *)\",\"Lifecycle\":{\"MoveToColdStorageAfterDays\":30,\"DeleteAfterDays\":120}}]}"

aws backup list-backup-selections \
    --backup-plan-id "$PLAN_ID" \
    --query 'BackupSelectionsList[*].{SelectionName:SelectionName,IamRoleArn:IamRoleArn}' \
    --output table

aws backup describe-backup-vault \
    --backup-vault-name "$VAULT_NAME" \
    --query '{VaultName:BackupVaultName,VaultArn:BackupVaultArn,EncryptionKeyArn:EncryptionKeyArn,RecoveryPoints:NumberOfRecoveryPoints}' \
    --output table


# =============================================================================
# 5-1A : EKS Cluster (Cloud Shell VPC 프라이빗 서브넷 환경)
echo "[ 5-1A ] EKS Cluster  ※ Cloud Shell VPC 프라이빗 서브넷 환경"
# =============================================================================
aws eks describe-cluster --name wsc-eks-cluster \
    --query 'cluster.{Name:name, Version:version, Status:status}' --output table

aws eks describe-cluster --name wsc-eks-cluster \
    --query 'cluster.encryptionConfig' --output json

aws eks describe-cluster --name wsc-eks-cluster \
    --query 'cluster.logging.clusterLogging' --output json

aws eks describe-cluster --name wsc-eks-cluster \
    --query 'cluster.{PublicEndpoint:resourcesVpcConfig.endpointPublicAccess, PrivateEndpoint:resourcesVpcConfig.endpointPrivateAccess}' \
    --output table

SUBNET_IDS=$(aws eks describe-cluster --name wsc-eks-cluster \
    --query 'cluster.resourcesVpcConfig.subnetIds' --output text)
aws ec2 describe-subnets \
    --subnet-ids $SUBNET_IDS \
    --query 'Subnets[*].{ID:SubnetId, Name:Tags[?Key==`Name`]|[0].Value, AZ:AvailabilityZone, CIDR:CidrBlock}' \
    --output table


# =============================================================================
# 5-1B : EKS Nodegroups
echo "[ 5-1B ] EKS Nodegroups"
# =============================================================================
CLUSTER="wsc-eks-cluster"
aws eks list-nodegroups --cluster-name "$CLUSTER" --output table

for NG in wsc-app-nodegroup wsc-addon-nodegroup; do
    aws eks describe-nodegroup \
        --cluster-name "$CLUSTER" \
        --nodegroup-name "$NG" \
        --query 'nodegroup.{Status:status, InstanceType:instanceTypes, AmiType:amiType, Labels:labels, Taints:taints, CapacityType:capacityType}' \
        --output json
done


# =============================================================================
# 5-2A : Pods
echo "[ 5-2A ] Pods"
# =============================================================================
aws eks update-kubeconfig --name wsc-eks-cluster
kubectl get pods -n book -l app=book


# =============================================================================
# 5-2B : Pods on app node
echo "[ 5-2B ] Pods on app node"
# =============================================================================
kubectl get pods -A -o wide | grep -E "$(kubectl get nodes -l node=app -o name | cut -d'/' -f2 | tr '\n' '|' | sed 's/|$//')"


# =============================================================================
# 6-1 : ALB
echo "[ 6-1 ] ALB"
# =============================================================================
aws elbv2 describe-load-balancers --names wsc-alb \
    --query 'LoadBalancers[*].[LoadBalancerName, Scheme, DNSName]' --output table

ALB_ARN=$(aws elbv2 describe-load-balancers --names wsc-alb \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[*].[Port, Protocol, DefaultActions[0].Type]' --output table

ALB_DNS=$(aws elbv2 describe-load-balancers --names wsc-alb \
    --query 'LoadBalancers[0].DNSName' --output text)
curl -I "http://$ALB_DNS/health"
curl -X POST "http://$ALB_DNS/v1/book" \
    -H "Content-Type: application/json" \
    -d '{"client_id": "C001", "username": "Alice", "email": "kim@example.com", "concert_name": "Seoul2025"}'


# =============================================================================
# 7-1A : Prometheus
echo "[ 7-1A ] Prometheus"
# =============================================================================
kubectl get prometheus -n prometheus -o yaml | grep -E "scrapeInterval|evaluationInterval"


# =============================================================================
# 7-1B : 웹페이지에서 확인
echo "[ 7-1B ] 웹페이지에서 확인"
# =============================================================================
echo "웹페이지에서 확인: http://localhost:9090/alerts"