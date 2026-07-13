# 02_2과제 Module 4 설명서: MSK

## 목표

Amazon MSK로 Kafka 스트리밍 파이프라인을 구성합니다. EC2 Producer가 센서 데이터를 raw topic에 발행하고, Lambda consumer가 데이터를 처리하여 DynamoDB에 저장합니다. 이상 데이터는 alert topic으로 분리하고, 별도 Lambda가 SNS 알림과 S3 로그 저장을 수행합니다.

## 핵심 아키텍처

```text
Producer EC2
  -> MSK topic: wsc2026-sensor-raw
  -> Lambda: wsc2026-sensor-consumer
  -> DynamoDB: wsc2026-sensor-data
  -> MSK topic: wsc2026-sensor-alert
  -> Lambda: wsc2026-sensor-alert-consumer
  -> SNS + S3 alert logs
```

## 필수 리소스

| 항목 | 값 |
|---|---|
| Region | `ap-northeast-1` |
| VPC | `msk-vpc`, `192.168.0.0/16` |
| MSK Cluster | `wsc2026-msk-cluster` |
| Kafka Version | `3.6.0` |
| Broker Type | `kafka.t3.small` |
| Auth | IAM enabled |
| Raw Topic | `wsc2026-sensor-raw`, partitions 3, replication 2 |
| Alert Topic | `wsc2026-sensor-alert`, partitions 1, replication 2 |
| Producer EC2 | `wsc2026-sensor-producer`, `t3.small` |
| EC2 Role | `wsc2026-msk-ec2-role` |
| Lambda Role | `wsc2026-msk-lambda-role` |
| Lambda Runtime | `python3.14` |
| DynamoDB | `wsc2026-sensor-data`, PK `sensorId`, SK `timestamp` |
| S3 Bucket | `wsc2026-sensor-alert-bucket-<비번호>` |
| SNS Topic | `wsc2026-sensor-alert` |

## 이론 설명

### MSK와 Kafka

Amazon MSK는 AWS 관리형 Apache Kafka입니다. Kafka는 이벤트를 topic에 저장하고, consumer가 각자 필요한 topic을 읽는 구조입니다.

| 개념 | 설명 |
|---|---|
| Broker | 메시지를 저장하고 전달하는 서버 |
| Topic | 이벤트 종류별 채널 |
| Partition | 병렬 처리를 위한 topic 분할 단위 |
| Replication Factor | 장애 대비 복제 수 |
| Producer | topic에 메시지를 쓰는 애플리케이션 |
| Consumer | topic에서 메시지를 읽는 애플리케이션 |

### Topic 분리 이유

`raw` topic과 `alert` topic을 분리하면 원본 데이터 처리와 이상 데이터 후처리를 독립적으로 확장할 수 있습니다.

| Topic | 목적 |
|---|---|
| `wsc2026-sensor-raw` | 모든 센서 원본 이벤트 |
| `wsc2026-sensor-alert` | 이상 탐지된 이벤트 |

### IAM 인증

MSK IAM 인증은 Kafka 접속 권한을 IAM role로 통제합니다. EC2 Producer와 Lambda consumer 모두 필요한 topic 권한만 갖도록 구성합니다.

## 구축 순서

1. `ap-northeast-1` 리전 설정
2. `msk-vpc`와 public/private subnet 생성
3. MSK security group 구성
4. MSK Cluster 생성, IAM 인증 활성화
5. Kafka topic 2개 생성
6. DynamoDB, S3, SNS 생성
7. Producer EC2 생성 및 systemd 구성
8. Lambda 2개 생성
9. Lambda MSK event source mapping 연결
10. DynamoDB 데이터와 event mapping 상태 확인

## DynamoDB, S3, SNS

```bash
aws configure set region ap-northeast-1
export NUM=<비번호>
export ALERT_BUCKET=wsc2026-sensor-alert-bucket-${NUM}

aws dynamodb create-table \
  --table-name wsc2026-sensor-data \
  --attribute-definitions AttributeName=sensorId,AttributeType=S AttributeName=timestamp,AttributeType=S \
  --key-schema AttributeName=sensorId,KeyType=HASH AttributeName=timestamp,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST

aws s3api create-bucket \
  --bucket ${ALERT_BUCKET} \
  --region ap-northeast-1 \
  --create-bucket-configuration LocationConstraint=ap-northeast-1

aws sns create-topic --name wsc2026-sensor-alert
```

## MSK 확인

```bash
CLUSTER_ARN=$(aws kafka list-clusters \
  --cluster-name-filter wsc2026-msk-cluster \
  --query "ClusterInfoList[0].ClusterArn" \
  --output text)

aws kafka describe-cluster \
  --cluster-arn ${CLUSTER_ARN} \
  --query "ClusterInfo.[ClusterName,State,CurrentBrokerSoftwareInfo.KafkaVersion,BrokerNodeGroupInfo.InstanceType,ClientAuthentication.Sasl.Iam.Enabled]" \
  --output text
```

기대값:

```text
wsc2026-msk-cluster ACTIVE 3.6.0 kafka.t3.small True
```

## Topic 생성

```bash
BOOTSTRAP=$(aws kafka get-bootstrap-brokers \
  --cluster-arn ${CLUSTER_ARN} \
  --query BootstrapBrokerStringSaslIam \
  --output text)

kafka-topics.sh --bootstrap-server ${BOOTSTRAP} \
  --command-config client.properties \
  --create --topic wsc2026-sensor-raw \
  --partitions 3 --replication-factor 2

kafka-topics.sh --bootstrap-server ${BOOTSTRAP} \
  --command-config client.properties \
  --create --topic wsc2026-sensor-alert \
  --partitions 1 --replication-factor 2
```

## Producer 환경변수

| 변수 | 값 |
|---|---|
| `BOOTSTRAP_SERVERS` | MSK IAM bootstrap endpoint |
| `TOPIC_RAW` | `wsc2026-sensor-raw` |

systemd 예시:

```ini
[Unit]
Description=WSC2026 Sensor Producer
After=network-online.target

[Service]
WorkingDirectory=/opt/sensor
Environment=BOOTSTRAP_SERVERS=<MSK_BOOTSTRAP_SERVERS>
Environment=TOPIC_RAW=wsc2026-sensor-raw
ExecStart=/opt/sensor/app
Restart=always
User=ec2-user

[Install]
WantedBy=multi-user.target
```

## Lambda Consumer

| Function | Trigger Topic | 역할 |
|---|---|---|
| `wsc2026-sensor-consumer` | `wsc2026-sensor-raw` | 정상/이상 판단, DynamoDB 저장, alert topic 발행 |
| `wsc2026-sensor-alert-consumer` | `wsc2026-sensor-alert` | SNS 알림, S3 alert log 저장 |

이상 판단 기준:

| 조건 | 결과 |
|---|---|
| `temperature > 80` | ALERT |
| `temperature < 10` | ALERT |
| `humidity > 90` | ALERT |
| `humidity < 20` | ALERT |
| 그 외 | NORMAL |

## Event Source Mapping 확인

```bash
for fn in wsc2026-sensor-consumer wsc2026-sensor-alert-consumer; do
  aws lambda list-event-source-mappings \
    --function-name $fn \
    --query "EventSourceMappings[0].[State]" \
    --output text
done
```

기대값:

```text
Enabled
Enabled
```

## 데이터 처리 확인

```bash
aws dynamodb scan \
  --table-name wsc2026-sensor-data \
  --max-items 1 \
  --query "Items[0].{sensorId:sensorId.S,temperature:temperature.S,status:status.S}" \
  --output table
```

## 자주 틀리는 부분

| 실수 | 해결 |
|---|---|
| MSK IAM 인증 비활성화 | `ClientAuthentication.Sasl.Iam.Enabled=True` 확인 |
| topic partition/replication 불일치 | raw는 `3/2`, alert는 `1/2` |
| Lambda가 MSK VPC에 접근 못함 | event source mapping에 subnet/security group 지정 |
| Producer가 foreground로만 실행 | systemd로 지속 실행 |
| DynamoDB key를 하나만 생성 | PK `sensorId`, SK `timestamp` 모두 설정 |
