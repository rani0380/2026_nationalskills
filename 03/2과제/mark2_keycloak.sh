#!/bin/bash


echo =====2-1=====
VID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=wsc2026-keycloak-vpc --query 'Vpcs[0].VpcId' --output text --region ap-northeast-2)
aws ec2 describe-vpcs --vpc-ids $VID --query 'Vpcs[0].[CidrBlock,Tags[?Key==`Name`]|[0].Value]' --output text --region ap-northeast-2
aws ec2 describe-subnets --filters Name=vpc-id,Values=$VID --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,CidrBlock,AvailabilityZone]' --output text --region ap-northeast-2 | sort
echo

echo =====2-2=====
IID=$(aws ec2 describe-instances --filters Name=tag:Name,Values=wsc2026-keycloak Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].InstanceId' --output text --region ap-northeast-2)
aws ec2 describe-instances --instance-ids $IID --query 'Reservations[0].Instances[0].[Tags[?Key==`Name`]|[0].Value,InstanceType,State.Name]' --output text --region ap-northeast-2
SID=$(aws ec2 describe-instances --instance-ids $IID --query 'Reservations[0].Instances[0].SubnetId' --output text --region ap-northeast-2)
echo "Subnet: $(aws ec2 describe-subnets --subnet-ids $SID --query 'Subnets[0].Tags[?Key==`Name`]|[0].Value' --output text --region ap-northeast-2)"
EC2SG=$(aws ec2 describe-instances --instance-ids $IID --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text --region ap-northeast-2)
echo "EC2-SG: $([ "$(aws ec2 describe-security-groups --group-ids $EC2SG --query 'SecurityGroups[0].GroupName' --output text --region ap-northeast-2)" = wsc2026-keycloak-sg ] && echo PASS || echo FAIL)"
echo

echo =====2-3=====
ALB=$(aws elbv2 describe-load-balancers --names wsc2026-keycloak-alb --query 'LoadBalancers[0]' --output json --region ap-northeast-2)
echo "$ALB" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['LoadBalancerName']+'\t'+d['Scheme'])"
ALBARN=$(echo "$ALB" | python3 -c "import sys,json;print(json.load(sys.stdin)['LoadBalancerArn'])")
TG=$(aws elbv2 describe-target-groups --names wsc2026-keycloak-tg --query 'TargetGroups[0].TargetGroupArn' --output text --region ap-northeast-2)
echo "Listener: $(aws elbv2 describe-listeners --load-balancer-arn $ALBARN --query 'Listeners[?Port==`80`].Port' --output text --region ap-northeast-2)"
echo "TargetGroup: wsc2026-keycloak-tg"
echo "TargetHealth: $(aws elbv2 describe-target-health --target-group-arn $TG --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text --region ap-northeast-2)"
ALBSG=$(echo "$ALB" | python3 -c "import sys,json;print(json.load(sys.stdin)['SecurityGroups'][0])")
echo "ALB-SG: $([ "$(aws ec2 describe-security-groups --group-ids $ALBSG --query 'SecurityGroups[0].GroupName' --output text --region ap-northeast-2)" = wsc2026-keycloak-alb-sg ] && echo PASS || echo FAIL)"
echo

echo =====2-4=====
URL=http://$(aws elbv2 describe-load-balancers --names wsc2026-keycloak-alb --query 'LoadBalancers[0].DNSName' --output text --region ap-northeast-2)
TOKEN=$(curl -s -X POST "$URL/realms/master/protocol/openid-connect/token" -d "client_id=admin-cli&grant_type=password&username=admin&password=Skill53#!!@#" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
echo "wsc2026-aws Realm: $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" $URL/admin/realms/wsc2026-aws)"
echo "Groups:"
curl -s -H "Authorization: Bearer $TOKEN" "$URL/admin/realms/wsc2026-aws/groups" | python3 -c "import sys,json;[print('  '+g['name']) for g in json.load(sys.stdin)]"
echo "Users:"
for U in dev-user infra-user; do
  echo "  $U: $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$URL/admin/realms/wsc2026-aws/users?username=$U&exact=true")"
done
echo "Login:"
echo "  dev-user: $(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/realms/wsc2026-aws/protocol/openid-connect/token" -d "client_id=admin-cli&grant_type=password&username=dev-user&password=Skills_dev53%25%24%25")"
echo "  infra-user: $(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/realms/wsc2026-aws/protocol/openid-connect/token" -d "client_id=admin-cli&grant_type=password&username=infra-user&password=Skills_infra53%23%40%23")"
echo

echo =====2-5=====
echo "SAML: $(aws iam list-saml-providers --query 'SAMLProviderList[0].Arn' --output text | awk -F/ '{print $NF}')"
echo "Roles:"
aws iam get-role --role-name wsc2026-dev-role --query 'Role.RoleName' --output text | sed 's/^/  /'
aws iam get-role --role-name wsc2026-infra-role --query 'Role.RoleName' --output text | sed 's/^/  /'
echo "Policies:"
aws iam list-policies --scope Local --query "Policies[?PolicyName=='wsc2026-dev-policy'].PolicyName" --output text | sed 's/^/  /'
aws iam list-policies --scope Local --query "Policies[?PolicyName=='wsc2026-infra-policy'].PolicyName" --output text | sed 's/^/  /'
echo

echo =====2-6=====
aws ec2 run-instances --image-id $(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text --region ap-northeast-2) --instance-type t3.micro --subnet-id $(aws ec2 describe-subnets --filters Name=tag:Name,Values=wsc2026-private-subnet-a --query 'Subnets[0].SubnetId' --output text) --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=wsc2026-protected-ec2},{Key=protected,Value=true}]' --region ap-northeast-2 --no-cli-pager > /dev/null 2>&1
echo "[수동] Login URL: $URL/realms/wsc2026-aws/protocol/saml/clients/amazon-aws"
echo "dev-user(Skills_dev53%\$%) → ap-northeast-2 EC2/S3만 조회 가능"
echo "infra-user(Skills_infra53#@#) → EC2/S3/VPC/IAM 조회 가능"
echo "                                protected=true 태그 EC2 중지 거부 확인"