#!/bin/bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "ACCOUNT ID: $ACCOUNT_ID"
aws configure set region ap-northeast-2

ALB_DNS=$(aws elbv2 describe-load-balancers --names wsc2026-analytics-alb --query "LoadBalancers[0].DNSName" --output text)
EC2_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=wsc2026-analytics-ec2" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text)

# 1-1 EC2 Instance
echo ====================
echo "  1-1 EC2 Instance"
echo ====================
aws ec2 describe-subnets --subnet-ids $(aws ec2 describe-instances --instance-ids $EC2_ID --query "Reservations[0].Instances[0].SubnetId" --output text) --query "Subnets[0].Tags[?Key=='Name'].Value|[0]" --output text

# 2-1 ALB Resources
echo ====================
echo "  2-1 ALB Resources"
echo ====================
echo "$(aws elbv2 describe-listeners --load-balancer-arn $(aws elbv2 describe-load-balancers --names wsc2026-analytics-alb --query "LoadBalancers[0].LoadBalancerArn" --output text) --query "Listeners[0].[Port,Protocol]" --output text) | TG: $(aws elbv2 describe-target-groups --names wsc2026-analytics-tg --query "TargetGroups[0].[TargetGroupName,Port]" --output text)"

# 3-1 Kinesis Stream
echo ====================
echo "  3-1 Kinesis Stream"
echo ====================
aws kinesis describe-stream-summary --stream-name wsc2026-order-stream --query "StreamDescriptionSummary.[StreamName,StreamStatus,StreamModeDetails.StreamMode]" --output text

# 3-2 Kinesis Data
echo ====================
echo "  3-2 Kinesis Data"
echo ====================
curl -s -X POST http://$ALB_DNS/order

# 4-1 Flink Application
echo ""
echo ====================
echo "  4-1 Flink Application"
echo ====================
aws kinesisanalyticsv2 describe-application --application-name wsc2026-analytics-flink --query "ApplicationDetail.[ApplicationName,ApplicationStatus,RuntimeEnvironment]" --output text

# 5-1 Application Health
echo ====================
echo "  5-1 Application Health"
echo ====================
curl -s http://$ALB_DNS/health

# 6-1 Systemd Service
echo ""
echo ====================
echo "  6-1 Systemd Service"
echo ====================
CMD_ID=$(aws ssm send-command --instance-ids $EC2_ID --document-name "AWS-RunShellScript" --parameters '{"commands":["systemctl is-active app && systemctl is-enabled app"]}' --query "Command.CommandId" --output text) && sleep 3 && aws ssm get-command-invocation --command-id $CMD_ID --instance-id $EC2_ID --query "StandardOutputContent" --output text
