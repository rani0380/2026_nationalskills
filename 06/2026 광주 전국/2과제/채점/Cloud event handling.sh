#!/bin/bash

echo =====3-1=====
echo "Service: $(sudo systemctl is-active gj2026-app)"; echo "Health: $(curl -s http://localhost:8080/health)"
echo

sleep 10

echo =====3-2=====
sleep 10
aws logs filter-log-events \
  --log-group-name "/gj2026/event/app-logs" \
  --start-time $(date -d '3 minutes ago' +%s000) \
  --filter-pattern "health" \
  --region ap-northeast-2 \
  --query 'events[0].message' \
  --output text


echo =====3-3=====
PARAM=$(aws ssm get-parameter --name "/gj2026/event/app-py" \
  --query "Parameter.Value" --output text | sed 's/[[:space:]]*$//')
FILE=$(sed 's/[[:space:]]*$//' /home/ec2-user/app.py)
diff <(echo "$PARAM") <(echo "$FILE")


echo =====3-4=====
aws cloudwatch describe-alarms --alarm-names "gj2026-event-app-alarm" \
  --query "MetricAlarms[0].StateValue" --output text
sudo systemctl stop gj2026-app
sleep 60
aws cloudwatch describe-alarms --alarm-names "gj2026-event-app-alarm" \
  --query "MetricAlarms[0].StateValue" --output text
echo

sleep 30

echo =====3-5=====
echo -e "\ndef broken" >> /home/ec2-user/app.py
sudo systemctl restart gj2026-app
sleep 100
curl http://localhost:8080 -w "\n"
aws logs filter-log-events \
  --log-group-name "/aws/lambda/gj2026-event-recovery" \
  --start-time $(date -d '3 minutes ago' +%s000) \
  --region ap-northeast-2 \
  --query 'length(events)' \
  --output text --no-paginate
echo


echo =====3-6=====
sed -i 's/"WorldSkills 2026"/"hello!"/' /home/ec2-user/app.py
sudo systemctl restart gj2026-app
sleep 60
aws ssm get-parameter --name "/gj2026/event/app-py" \
  --query "Parameter.Value" --output text | grep "hello!"
aws logs filter-log-events \
  --log-group-name "/aws/lambda/gj2026-event-updater" \
  --start-time $(date -d '3 minutes ago' +%s000) \
  --region ap-northeast-2 \
  --query 'length(events)' \
  --output text --no-paginate
echo


echo =====3-7=====
echo -e "\ndef broken" >> /home/ec2-user/app.py
sudo systemctl restart gj2026-app
sleep 100
curl http://localhost:8080 -w "\n"
aws logs filter-log-events \
  --log-group-name "/aws/lambda/gj2026-event-recovery" \
  --start-time $(date -d '3 minutes ago' +%s000) \
  --region ap-northeast-2 \
  --query 'length(events)' \
  --output text --no-paginate
echo


echo =====3-8=====
aws logs filter-log-events \
  --log-group-name "/gj2026/event/recovery" \
  --start-time $(date -d '10 minutes ago' +%s000) \
  --region ap-northeast-2 \
  --query 'events[-1].message' \
  --output text | grep -v "^None$"