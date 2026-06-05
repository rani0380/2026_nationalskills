#!/bin/bash
REGION="ap-northeast-1"

# 1. VPC 및 서브넷 정보 조회
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=wsc2026-db-vpc" --query "Vpcs[0].{VpcId:VpcId,CIDR:CidrBlock}" --output table --region $REGION
aws ec2 describe-subnets --filters "Name=tag:Name,Values=wsc2026-db-sn-a,wsc2026-db-sn-c,wsc2026-pub-sn-a,wsc2026-pub-sn-c" --query "Subnets[*].{Name:Tags[?Key=='Name']|[0].Value,SubnetId:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone}" --output table --region $REGION

# 2. RDS 인스턴스 및 프록시 정보 조회
aws rds describe-db-instances --db-instance-identifier wsc2026-rds-instance --query "DBInstances[0].DBInstanceStatus" --output text --region $REGION
aws rds describe-db-proxies --db-proxy-name wsc2026-rds-proxy --query "DBProxies[0].{Name:DBProxyName,Status:Status,Endpoint:Endpoint}" --output table --region $REGION
aws rds describe-db-instances --db-instance-identifier wsc2026-rds-instance --query "DBInstances[0].{Engine:Engine,Version:EngineVersion,Class:DBInstanceClass,PublicAccess:PubliclyAccessible,SubnetGroup:DBSubnetGroup.DBSubnetGroupName,Subnets:DBSubnetGroup.Subnets[*].SubnetIdentifier}" --output table --region $REGION

# 3. Lambda 함수 상태 및 설정 조회
aws lambda get-function --function-name wsc2026-db-client --query "Configuration.{FunctionName:FunctionName,State:State}" --output table --region $REGION
aws lambda get-function-configuration --function-name wsc2026-db-client --query "{Runtime:Runtime,State:State}" --output table --region $REGION

# 4. Lambda 함수 호출 및 결과 출력 (로그 숨김 및 임시 파일 삭제)
aws lambda invoke --function-name wsc2026-db-client --payload '{"action":"read","username":"test_user"}' --cli-binary-format raw-in-base64-out /tmp/out.json --region $REGION >/dev/null 2>&1
if [ -f /tmp/out.json ]; then
    cat /tmp/out.json && echo ""
    rm -f /tmp/out.json
fi