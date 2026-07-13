# 02_2과제 Module 3 설명서: Cloud Event Handling

## 목표

EC2 중지, EC2 종료, 보안 그룹 SSH 개방, 태그 누락 같은 운영/보안 이벤트를 감지하고 Lambda로 자동 복구 또는 SNS 알림을 수행합니다.

## 핵심 아키텍처

```text
EC2 / Security Group / Tag 변경
  -> CloudTrail 또는 AWS Config 평가
  -> EventBridge Rule 또는 Config Rule
  -> Lambda
  -> EC2 start, SG ingress revoke, SNS alert
```

## 필수 리소스

| 항목 | 값 |
|---|---|
| Region | `eu-west-1` |
| VPC | `event-vpc`, `172.16.0.0/16` |
| EC2 | `wsc2026-event-ec2`, `t3.micro` |
| EC2 Role | `wsc2026-event-ec2-role` |
| Security Group | `wsc2026-event-sg` |
| CloudTrail | `wsc2026-event-trail` |
| SNS | `wsc2026-event-alert` |
| Lambda Role | `wsc2026-event-lambda-role` |
| Runtime | `python3.12` |
| Config Rules | `wsc2026-sg-ssh-rule`, `wsc2026-required-tags-rule` |

## Lambda 함수

| Function | Trigger | Action |
|---|---|---|
| `wsc2026-ec2-stop-remediation` | `wsc2026-ec2-stop-rule` | stopped EC2 재시작 |
| `wsc2026-ec2-terminate-alert` | `wsc2026-ec2-terminate-rule` | SNS 알림 |
| `wsc2026-sg-remediation` | `wsc2026-sg-ssh-rule` | SSH 22 open rule 제거 |
| `wsc2026-tag-alert` | `wsc2026-required-tags-rule` | SNS 알림 |

## 이론 설명

### EventBridge

EventBridge는 AWS 서비스 이벤트를 조건에 따라 Lambda 같은 target으로 전달합니다. EC2 stopped/terminated 같은 상태 변화는 EventBridge rule로 감지하기 좋습니다.

### CloudTrail

CloudTrail은 API 호출 이력을 남깁니다. EventBridge가 관리 이벤트를 안정적으로 감지하려면 CloudTrail management event 기록이 필요합니다.

### AWS Config

AWS Config는 리소스가 정책을 만족하는지 평가합니다. “SSH가 전 세계에 열려 있는가”, “필수 태그가 있는가”처럼 현재 상태 기반 검사에 적합합니다.

### 자동 복구와 알림의 차이

| 이벤트 | 대응 |
|---|---|
| EC2 stopped | 다시 start 가능하므로 자동 복구 |
| EC2 terminated | 원상 복구가 어려우므로 알림 |
| SG SSH open | ingress rule 삭제 가능하므로 자동 복구 |
| Tag missing | 어떤 값을 넣을지 모를 수 있으므로 알림 |

## 구축 순서

1. `eu-west-1` 리전 설정
2. VPC, public subnet, EC2, SG 생성
3. SNS topic 생성
4. Lambda role 생성
5. 4개 Lambda 함수 작성 및 배포
6. CloudTrail 생성
7. EventBridge rule 2개 생성
8. AWS Config recorder 구성
9. Config rule 2개 생성
10. 복구 테스트

## Lambda 핵심 코드

EC2 stop 복구:

```python
ec2_client.start_instances(InstanceIds=[instance_id])
publish_alert("EC2_STOPPED", f"EC2 instance {instance_id} was stopped and restarted", "RESTORED")
```

SG SSH open 제거:

```python
ec2_client.revoke_security_group_ingress(
    GroupId=sg_id,
    IpPermissions=[
        {
            "IpProtocol": "tcp",
            "FromPort": 22,
            "ToPort": 22,
            "IpRanges": [{"CidrIp": "0.0.0.0/0"}],
        }
    ],
)
```

## EventBridge Rule

EC2 stopped:

```json
{
  "source": ["aws.ec2"],
  "detail-type": ["EC2 Instance State-change Notification"],
  "detail": {
    "state": ["stopped"]
  }
}
```

EC2 terminated:

```json
{
  "source": ["aws.ec2"],
  "detail-type": ["EC2 Instance State-change Notification"],
  "detail": {
    "state": ["terminated"]
  }
}
```

## 채점 확인

```bash
aws sns get-topic-attributes \
  --topic-arn arn:aws:sns:eu-west-1:${ACCOUNT_ID}:wsc2026-event-alert \
  --query "Attributes.TopicArn" \
  --output text
```

```bash
for fn in wsc2026-ec2-stop-remediation wsc2026-ec2-terminate-alert wsc2026-sg-remediation wsc2026-tag-alert; do
  aws lambda get-function --function-name $fn \
    --query "Configuration.[FunctionName,Runtime]" \
    --output text
done
```

복구 결과:

```bash
sleep 30
aws ec2 describe-instances --instance-ids ${INSTANCE_ID} \
  --query "Reservations[0].Instances[0].State.Name" \
  --output text

aws ec2 describe-security-groups --group-ids ${SG_ID} \
  --query "SecurityGroups[0].IpPermissions | length(@)" \
  --output text
```

기대값:

- EC2 state: `running`
- SG inbound count: `0`

## 자주 틀리는 부분

| 실수 | 해결 |
|---|---|
| Config recorder 미구성 | recorder와 delivery channel 먼저 생성 |
| Lambda handler를 모두 `index.handler`로 둠 | 함수별 handler를 분리 |
| SNS_TOPIC_ARN 환경변수 누락 | 모든 Lambda에 topic ARN 설정 |
| SG revoke 예외로 Lambda 실패 | 이미 삭제된 경우를 고려해 예외 처리 |
| EventBridge target 권한 누락 | `lambda:add-permission`으로 events.amazonaws.com 허용 |
