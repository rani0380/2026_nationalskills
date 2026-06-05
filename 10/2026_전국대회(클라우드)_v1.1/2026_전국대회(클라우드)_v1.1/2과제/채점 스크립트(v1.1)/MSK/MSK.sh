#!/bin/bash

echo ####################################
echo ###
echo ###    Module 3 : MSK
echo ###    채점 항목 6개 / 총 7.5점
echo ####################################

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws configure set region ap-northeast-2

#######################################################################
# 채점 전 아래 3개 변수를 반드시 수정하세요
#######################################################################
APP_ID="<App EC2 인스턴스 ID 입력 (i-xxxxxxxxx)>"
BOOTSTRAP_HOST="<MSK 부트스트랩 브로커 1개 호스트만, 포트 제외 (예: b-1.mskordercluster.xxxx.kafka.ap-northeast-2.amazonaws.com)>"
BOOTSTRAP="<부트스트랩 브로커 주소 입력 (포트 포함)>"


#######################################################################
echo "===== 3-1 VPC & Subnet (1.0) ====="
#######################################################################
VPC_ID=$(aws ec2 describe-vpcs \
  --filter Name=tag:Name,Values=wsc-msk-vpc \
  --query Vpcs[].VpcId --output text)
echo "VPC ID: $VPC_ID"

echo "[퍼블릭 서브넷]"
IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters Name=attachment.vpc-id,Values=$VPC_ID \
  --query "InternetGateways[0].InternetGatewayId" --output text)
PUBLIC_SUBNETS=$(aws ec2 describe-route-tables \
  --filters Name=vpc-id,Values=$VPC_ID \
  --query "RouteTables[?Routes[?GatewayId=='$IGW_ID']].Associations[].SubnetId" \
  --output text)
for SUBNET_ID in $PUBLIC_SUBNETS; do
  aws ec2 describe-subnets --subnet-ids $SUBNET_ID \
    --query "Subnets[].[AvailabilityZone,SubnetId]" --output text
done

echo "[프라이빗 서브넷]"
PRIVATE_SUBNETS=$(aws ec2 describe-route-tables \
  --filters Name=vpc-id,Values=$VPC_ID \
  --query "RouteTables[?Routes[?NatGatewayId!=null]].Associations[].SubnetId" \
  --output text)
for SUBNET_ID in $PRIVATE_SUBNETS; do
  aws ec2 describe-subnets --subnet-ids $SUBNET_ID \
    --query "Subnets[].[AvailabilityZone,SubnetId]" --output text
done
echo


#######################################################################
echo "===== 3-2 EC2 : type / ID / MSK 연결 (1.5) ====="
#######################################################################
aws ec2 describe-instances \
  --filters Name=tag:Name,Values=wsc-app-ec2 \
  --query "Reservations[0].Instances[0].InstanceType" --output text

aws ec2 describe-instances \
  --filters Name=tag:Name,Values=wsc-app-ec2 Name=instance-state-name,Values=running \
  --query "Reservations[].Instances[].InstanceId" --output text

CMD_ID=$(aws ssm send-command \
  --instance-ids $APP_ID \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"python3 -c \\\"import socket; s=socket.socket(); s.settimeout(5); r=s.connect_ex(('$BOOTSTRAP_HOST',9092)); print('연결 성공' if r==0 else f'연결 실패 (에러코드: {r})'); s.close()\\\"\"]" \
  --query "Command.CommandId" --output text)
sleep 5
aws ssm get-command-invocation \
  --command-id $CMD_ID \
  --instance-id $APP_ID \
  --query StandardOutputContent --output text
echo


#######################################################################
echo "===== 3-3 S3 : Bucket / UTC partition / Consumer stored (0.5) ====="
#######################################################################
aws s3 ls | grep "wsc-msk-order-data"

BUCKET=$(aws s3 ls | grep wsc-msk-order-data | awk '{print $3}')
echo "현재 UTC 날짜: $(date -u +'%Y-%m-%d')"
aws s3 ls s3://$BUCKET/orders/ --recursive \
  | grep $(date -u +"%Y") \
  | head -3

aws s3 ls s3://$BUCKET/orders/ --recursive | head -5
echo


#######################################################################
echo "===== 3-4 MSK : Active / Public Access / Topic (1.5) ====="
#######################################################################
aws kafka list-clusters \
  --query "ClusterInfoList[?ClusterName=='msk-order-cluster'].{Name:ClusterName,State:State}" \
  --output text

CLUSTER_ARN=$(aws kafka list-clusters \
  --query "ClusterInfoList[?ClusterName=='msk-order-cluster'].ClusterArn" \
  --output text)
aws kafka describe-cluster \
  --cluster-arn $CLUSTER_ARN \
  --query "ClusterInfo.BrokerNodeGroupInfo.ConnectivityInfo.PublicAccess.Type" \
  --output text

CMD_ID=$(aws ssm send-command \
  --instance-ids $APP_ID \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=['/home/ec2-user/kafka_2.13-3.5.1/bin/kafka-topics.sh --list --bootstrap-server $BOOTSTRAP']" \
  --query "Command.CommandId" --output text)
sleep 5
aws ssm get-command-invocation \
  --command-id $CMD_ID \
  --instance-id $APP_ID \
  --query StandardOutputContent --output text
echo


#######################################################################
echo "===== 3-5 Lambda : configuration / MSK Trigger (1.5) ====="
#######################################################################
aws lambda get-function \
  --function-name msk-order-consumer \
  --query Configuration.FunctionName --output text

echo "(왼쪽부터: BatchSize=100, Source=MSK ARN, State=Enabled)"
aws lambda list-event-source-mappings \
  --function-name msk-order-consumer \
  --query "EventSourceMappings[].{Source:EventSourceArn,State:State,BatchSize:BatchSize}" \
  --output text
echo


#######################################################################
echo "===== 3-6 DynamoDB : configuration / data / duplicate prevention (1.5) ====="
#######################################################################
aws dynamodb describe-table \
  --table-name order-records \
  --query Table.TableName --output text

aws dynamodb scan \
  --table-name order-records \
  --select COUNT \
  --query Count --output text

TEST_ORDER_ID="test-duplicate-$(date +%s)"
TEST_TIMESTAMP="2026-01-01T00:00:00.000Z"

aws dynamodb put-item \
  --table-name order-records \
  --item "{\"orderId\": {\"S\": \"$TEST_ORDER_ID\"}, \"timestamp\": {\"S\": \"$TEST_TIMESTAMP\"}}" \
  --condition-expression "attribute_not_exists(orderId)" 2>/dev/null \
  && echo "PUT 1: 성공"

aws dynamodb put-item \
  --table-name order-records \
  --item "{\"orderId\": {\"S\": \"$TEST_ORDER_ID\"}, \"timestamp\": {\"S\": \"$TEST_TIMESTAMP\"}}" \
  --condition-expression "attribute_not_exists(orderId)" 2>/dev/null \
  && echo "PUT 2: 성공 (중복 방지 실패)" \
  || echo "PUT 2: 조건 실패 (중복 방지 정상)"

aws dynamodb get-item \
  --table-name order-records \
  --key "{\"orderId\": {\"S\": \"$TEST_ORDER_ID\"}, \"timestamp\": {\"S\": \"$TEST_TIMESTAMP\"}}" \
  --query Item.orderId.S --output text
echo
