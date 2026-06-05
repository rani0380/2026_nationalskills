#!/bin/bash

# 1. VPC 정보 조회 및 ID 저장 (서브넷 조회 시 재사용)
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=wsc2026-vpn-vpc" --query "Vpcs[0].VpcId" --output text)

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    aws ec2 describe-vpcs \
      --filters "Name=vpc-id,Values=$VPC_ID" \
      --query "Vpcs[*].{VpcId:VpcId, Name:Tags[?Key=='Name'].Value | [0], CidrBlock:CidrBlock}" \
      --output table

    # 2. 서브넷 정보 조회
    aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$VPC_ID" \
      --query "Subnets[*].{SubnetId:SubnetId, Name:Tags[?Key=='Name'].Value | [0], CidrBlock:CidrBlock, AZ:AvailabilityZone}" \
      --output table
fi

# 3. EC2 인스턴스 정보 조회
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=vpn-ec2" \
  --query "Reservations[*].Instances[*].{InstanceId:InstanceId, Name:Tags[?Key=='Name'].Value | [0], Type:InstanceType, SubnetId:SubnetId, Status:State.Name}" \
  --output table

# 4. ACM 인증서 조회
aws acm list-certificates \
  --query "CertificateSummaryList[?DomainName=='cve.wsc' || DomainName=='client.wsc'].{CertificateArn:CertificateArn, DomainName:DomainName}" \
  --output table

# 5. 확인 문구 출력
echo "ssh 접속으로 확인"