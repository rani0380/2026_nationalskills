#!/bin/bash

ADMIN_PASSWORD="admin1234!"
DEV_PW="dev123!"
SEC_PW="sec123!"

echo =====4-0=====
AMI=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" --region eu-central-1 --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text); DEV=$(aws ec2 run-instances --image-id $AMI --instance-type t3.small --region eu-central-1 --tag-specifications 'ResourceType=instance,Tags=[{Key=team,Value=dev-team},{Key=Name,Value=gj2026-keycloak-dev-ec2}]' --query 'Instances[0].InstanceId' --output text); aws ec2 wait instance-running --instance-ids $DEV --region eu-central-1; aws ec2 stop-instances --instance-ids $DEV --region eu-central-1 > /dev/null; SEC=$(aws ec2 run-instances --image-id $AMI --instance-type t3.small --region eu-central-1 --tag-specifications 'ResourceType=instance,Tags=[{Key=team,Value=sec-team},{Key=Name,Value=gj2026-keycloak-sec-ec2}]' --query 'Instances[0].InstanceId' --output text)
echo

echo =====4-1=====
KEYCLOAK_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=gj2026-keycloak-ec2" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
ADMIN_TOKEN=$(curl -sk -X POST \
  "https://$KEYCLOAK_IP/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=admin" -d "password=$ADMIN_PASSWORD" \
  -d "grant_type=password" | jq -r '.access_token')
B="https://$KEYCLOAK_IP/admin/realms/team"
H="Authorization: Bearer $ADMIN_TOKEN"
curl -sk -H "$H" "https://$KEYCLOAK_IP/admin/realms/team" | jq '.realm'
curl -sk -H "$H" "$B/clients" | jq '[.[].clientId | select(startswith("gj2026-keycloak"))]'
SCOPE_ID=$(curl -sk -H "$H" "$B/client-scopes" | jq -r '.[] | select(.name=="gj2026-keycloak-claims") | .id')
curl -sk -H "$H" "$B/client-scopes/$SCOPE_ID/protocol-mappers/models" | jq '[.[].name]'
curl -sk -H "$H" "$B/groups" | jq '[.[].name]'
for user in dev-user sec-user; do
  USER_ID=$(curl -sk -H "$H" "$B/users?username=$user" | jq -r '.[0].id')
  echo -n "$user: "
  curl -sk -H "$H" "$B/users/$USER_ID/groups" | jq '[.[].name]'
done
echo

echo =====4-2=====
aws iam list-open-id-connect-providers \
  --query 'OpenIDConnectProviderList[*].Arn' | grep realms/team
for role in gj2026-keycloak-dev-role gj2026-keycloak-sec-role; do
  aws iam get-role --role-name $role \
    --query 'Role.AssumeRolePolicyDocument' \
    | grep -E "AssumeRoleWithWebIdentity|gj2026-keycloak-(dev|sec)\""
  aws iam list-attached-role-policies --role-name $role \
    --query 'AttachedPolicies[].PolicyName' | grep gj2026-keycloak
done
echo

echo =====4-3=====
aws configure list-profiles | grep gj2026-keycloak
aws sts get-caller-identity --profile gj2026-keycloak-dev
aws sts get-caller-identity --profile gj2026-keycloak-sec
echo

echo =====4-4=====
DEV_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=gj2026-keycloak-dev-ec2" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
SEC_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=gj2026-keycloak-sec-ec2" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ec2 start-instances --instance-ids $DEV_INSTANCE_ID \
  --region eu-central-1 --profile gj2026-keycloak-dev \
  | jq -r '.StartingInstances[0] | "gj2026-keycloak-dev-ec2: \(.PreviousState.Name) → \(.CurrentState.Name)"'
aws ec2 stop-instances --instance-ids $SEC_INSTANCE_ID \
  --region eu-central-1 --profile gj2026-keycloak-sec \
  | jq -r '.StoppingInstances[0] | "gj2026-keycloak-sec-ec2: \(.PreviousState.Name) → \(.CurrentState.Name)"'
echo

echo =====4-5=====
DEV_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=gj2026-keycloak-dev-ec2" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
SEC_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=gj2026-keycloak-sec-ec2" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ec2 stop-instances --instance-ids $SEC_INSTANCE_ID \
  --region eu-central-1 --profile gj2026-keycloak-dev 2>&1 | grep -o "UnauthorizedOperation"
aws ec2 start-instances --instance-ids $DEV_INSTANCE_ID \
  --region eu-central-1 --profile gj2026-keycloak-sec 2>&1 | grep -o "UnauthorizedOperation"
echo

echo =====4-6=====
KEYCLOAK_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=gj2026-keycloak-ec2" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
ADMIN_TOKEN=$(curl -sk -X POST \
  "https://$KEYCLOAK_IP/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=admin" -d "password=$ADMIN_PASSWORD" \
  -d "grant_type=password" | jq -r '.access_token')
curl -sk -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  "https://$KEYCLOAK_IP/admin/realms/team/users" \
  -d '{"username":"dev-user2","enabled":true,"emailVerified":true,"firstName":"dev","lastName":"user2","email":"dev-user2@example.com","credentials":[{"type":"password","value":"dev123!","temporary":false}]}'
NEW_USER_ID=$(curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
  "https://$KEYCLOAK_IP/admin/realms/team/users?username=dev-user2" | jq -r '.[0].id')
GROUP_ID=$(curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
  "https://$KEYCLOAK_IP/admin/realms/team/groups" | jq -r '.[] | select(.name=="dev-team") | .id')
curl -sk -X PUT \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "https://$KEYCLOAK_IP/admin/realms/team/users/$NEW_USER_ID/groups/$GROUP_ID"
DEV_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=gj2026-keycloak-dev-ec2" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
SEC_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=gj2026-keycloak-sec-ec2" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws configure set credential_process \
  "/home/cloudshell-user/.aws/gj2026-keycloak-creds.sh dev dev-user2" \
  --profile gj2026-keycloak-dev2
aws ec2 start-instances --instance-ids $DEV_INSTANCE_ID \
  --region eu-central-1 --profile gj2026-keycloak-dev2 | grep -o "StartingInstances"
aws ec2 stop-instances --instance-ids $SEC_INSTANCE_ID \
  --region eu-central-1 --profile gj2026-keycloak-dev2 2>&1 | grep -o "UnauthorizedOperation"
echo
