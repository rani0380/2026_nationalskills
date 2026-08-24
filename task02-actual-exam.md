# 제2과제 실제 출제본 콘솔 + CLI 만점 풀이

기준: 2026-08-24 실제 시험지, 실제 채점표 30점, 현장 공지, 실제 배포파일.

> 정정: 삭제된 것은 종전 Cloud Event Handling입니다. 현재 시험은 Workflow, Real-time Data Analytics, MSK, CDN Service Setup, Legacy System Operation의 5개 모듈입니다.

| 번호 | 모듈 | 리전 | 배점 |
|---:|---|---|---:|
| 1 | Workflow | ap-southeast-1 | 7 |
| 2 | Real-time Data Analytics | ap-northeast-2 | 7 |
| 3 | MSK | ap-northeast-1 | 7 |
| 4 | CDN Service Setup | us-east-1 | 3 |
| 5 | Legacy System Operation | eu-central-1 | 6 |
| | 합계 | | 30 |

## 현장 공지 반영

- 현재 시험지를 기준으로 작업합니다.
- CDN 시간은 KST, 채점 페이지는 https://d2lvw397wb43zq.cloudfront.net 입니다.
- CloudShell과 Bastion 접근을 유지하고 채점 전 테스트 부하를 중지합니다.

    aws sts get-caller-identity
    export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    export NUM=<비번호>

---
## Module 1. Workflow

### 1.1 목표

학생 성적 CSV가 S3 `input/` 경로에 업로드되면 Step Functions가 실행되고, Lambda가 CSV를 검증하여 정상 데이터는 DynamoDB에 저장하고 오류 데이터는 S3 `error/`에 JSON으로 저장합니다. 처리 후 원본 CSV는 `processed/`로 이동합니다.

### 1.2 필수 리소스

| 항목 | 값 |
|---|---|
| Region | `ap-southeast-1` |
| S3 Bucket | `wsc2026-student-score-bucket-<비번호>` |
| Prefix | `input/`, `processed/`, `error/` |
| DynamoDB Table | `wsc2026-student-score` |
| Key | PK `studentId`, SK `examDate` |
| Processing Lambda | `wsc2026-student-score-function` |
| Runtime | `python3.12` |
| Lambda Env | `S3_BUCKET`, `DDB_TABLE` |
| Trigger Lambda | 선수 직접 작성 |
| Step Functions | `wsc2026-student-score-workflow`, `STANDARD` |
| Lambda Role | `wsc2026-lambda-student-role` |
| Step Functions Role | `wsc2026-stepfunction-student-role` |

### 1.3 S3 버킷과 폴더

```bash
aws configure set region ap-southeast-1
export BUCKET_NAME=wsc2026-student-score-bucket-${NUM}

aws s3api create-bucket \
  --bucket ${BUCKET_NAME} \
  --region ap-southeast-1 \
  --create-bucket-configuration LocationConstraint=ap-southeast-1

aws s3api put-object --bucket ${BUCKET_NAME} --key input/
aws s3api put-object --bucket ${BUCKET_NAME} --key processed/
aws s3api put-object --bucket ${BUCKET_NAME} --key error/
```

채점 전에는 `processed/`, `error/`가 비어 있어야 하며, 제공된 `test.csv`를 `input/test.csv`에 업로드합니다.

```bash
aws s3 rm s3://${BUCKET_NAME}/processed/ --recursive
aws s3 rm s3://${BUCKET_NAME}/error/ --recursive
aws s3 cp test.csv s3://${BUCKET_NAME}/input/test.csv
```

### 1.4 DynamoDB

```bash
aws dynamodb create-table \
  --table-name wsc2026-student-score \
  --attribute-definitions AttributeName=studentId,AttributeType=S AttributeName=examDate,AttributeType=S \
  --key-schema AttributeName=studentId,KeyType=HASH AttributeName=examDate,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST
```

채점 전 데이터 정리:

```bash
aws dynamodb scan --table-name wsc2026-student-score \
  --projection-expression "studentId, examDate" \
  --query "Items[]" --output json
```

데이터가 남아 있으면 키를 기준으로 삭제합니다.

### 1.5 성적 처리 Lambda TODO 완성

제공 `lambda-function.py`의 `calculate_grade`, `save_student`를 채워야 합니다.

핵심 구현:

```python
def calculate_grade(average):
    if average >= 90:
        return "A"
    if average >= 80:
        return "B"
    if average >= 70:
        return "C"
    if average >= 60:
        return "D"
    return "F"


def save_student(table, row):
    scores = [int(row[field].strip()) for field in SCORE_FIELDS]
    average = Decimal(str(round(sum(scores) / len(scores), 1)))
    grade = calculate_grade(float(average))
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    table.put_item(
        Item={
            "studentId": row["studentId"].strip(),
            "examDate": row["examDate"].strip(),
            "name": row["name"].strip(),
            "className": row["className"].strip(),
            "korean": int(row["korean"]),
            "english": int(row["english"]),
            "math": int(row["math"]),
            "science": int(row["science"]),
            "history": int(row["history"]),
            "average": average,
            "grade": grade,
            "createdAt": now,
        }
    )
```

`STU1020`은 `100, 98, 92, 97, 96`이므로 평균 `96.6`, 등급 `A`가 나와야 합니다. 채점 스크립트가 이 값을 직접 조회합니다.

### 1.6 Lambda 배포

```bash
zip function.zip lambda-function.py

aws lambda create-function \
  --function-name wsc2026-student-score-function \
  --runtime python3.12 \
  --handler lambda-function.handler \
  --zip-file fileb://function.zip \
  --role arn:aws:iam::${ACCOUNT_ID}:role/wsc2026-lambda-student-role \
  --timeout 30 \
  --environment Variables="{S3_BUCKET=${BUCKET_NAME},DDB_TABLE=wsc2026-student-score}"
```

함수명 파일에 하이픈이 있으면 Python import가 불편하므로 실제 배포 시에는 `index.py`로 이름을 바꾸고 `--handler index.handler`를 쓰는 편이 안전합니다.

### 1.7 Step Functions 정의

State Machine 이름은 `wsc2026-student-score-workflow`, 타입은 `STANDARD`입니다.

흐름:

1. `CheckS3File`: S3 HeadObject
2. `ProcessStudentData`: Lambda invoke
3. `CheckResult`: `statusCode == 200`이면 processed 이동
4. `MoveToProcessed`: `input/test.csv`를 `processed/test.csv`로 복사 후 원본 삭제
5. 실패 시 `MoveToError`

State Machine 정의의 핵심 형태:

```json
{
  "StartAt": "CheckS3File",
  "States": {
    "CheckS3File": {
      "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:s3:headObject",
      "Parameters": {
        "Bucket": "wsc2026-student-score-bucket-<비번호>",
        "Key.$": "$.key"
      },
      "Next": "ProcessStudentData"
    },
    "ProcessStudentData": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "wsc2026-student-score-function",
        "Payload.$": "$"
      },
      "OutputPath": "$.Payload",
      "Retry": [
        {
          "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2
        }
      ],
      "Next": "CheckResult"
    },
    "CheckResult": {
      "Type": "Choice",
      "Choices": [
        {
          "Variable": "$.statusCode",
          "NumericEquals": 200,
          "Next": "MoveToProcessed"
        }
      ],
      "Default": "MoveToError"
    }
  }
}
```

Copy/Delete 작업은 `arn:aws:states:::aws-sdk:s3:copyObject`, `deleteObject`를 사용합니다. Step Functions role에는 S3와 Lambda invoke 권한이 필요합니다.

### 1.8 S3 Trigger Lambda

S3 `input/*.csv` 업로드 이벤트를 받아 Step Functions를 시작합니다.

```python
import json
import os
import urllib.parse
import boto3

sf = boto3.client("stepfunctions")
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]


def handler(event, context):
    for record in event.get("Records", []):
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        if not key.startswith("input/") or not key.endswith(".csv"):
            continue
        sf.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            input=json.dumps({"key": key}),
        )
    return {"started": True}
```

S3 notification:

- Event: `s3:ObjectCreated:*`
- Prefix: `input/`
- Suffix: `.csv`

### 1.9 채점 확인

```bash
aws dynamodb get-item \
  --table-name wsc2026-student-score \
  --key '{"studentId":{"S":"STU1020"},"examDate":{"S":"2026-05-30"}}' \
  --query "Item.[studentId.S,average.N,grade.S]" \
  --output text

aws s3 ls s3://${BUCKET_NAME}/processed/test.csv
aws s3 ls s3://${BUCKET_NAME}/error/ | grep "error_"
```

기대값:

- `STU1020 96.6 A`
- `processed/test.csv` 존재
- `error/error_...json` 존재

---

## Module 2. Real-time Data Analytics

### 2.1 목표

Private subnet의 EC2에서 Flask 앱을 systemd 서비스로 실행합니다. ALB가 `/order`, `/health` 요청을 EC2로 전달하고, 앱은 주문 로그를 Kinesis Data Stream에 기록합니다. Managed Apache Flink Studio Notebook에서 SQL로 실시간 분석합니다.

### 2.2 필수 리소스

| 항목 | 값 |
|---|---|
| Region | `ap-northeast-2` |
| VPC | `analytics-vpc`, `10.20.0.0/16` |
| EC2 | `wsc2026-analytics-ec2`, `t3.small`, private subnet |
| EC2 Role | `wsc2026-analytics-ec2-role` |
| ALB | `wsc2026-analytics-alb`, HTTP 80 |
| Target Group | `wsc2026-analytics-tg`, port `5000` |
| Kinesis Stream | `wsc2026-order-stream`, ON_DEMAND |
| Flink App | `wsc2026-analytics-flink`, Apache Flink 1.19 |
| Flink Role | `wsc2026-analytics-flink-role` |

RC 문제지 기준 EC2 Role 이름은 `wsc2026-analytics-ec2-role`입니다.

### 2.3 네트워크

| Subnet | CIDR | Route |
|---|---|---|
| `analytics-pub-a` | `10.20.0.0/24` | IGW |
| `analytics-pub-b` | `10.20.1.0/24` | IGW |
| `analytics-priv-a` | `10.20.100.0/24` | NAT |
| `analytics-priv-b` | `10.20.101.0/24` | NAT |

EC2는 private subnet에 배치해야 합니다. 채점 스크립트는 EC2가 속한 subnet의 Name 태그를 확인합니다.

### 2.4 Kinesis Data Stream

```bash
aws configure set region ap-northeast-2

aws kinesis create-stream \
  --stream-name wsc2026-order-stream \
  --stream-mode-details StreamMode=ON_DEMAND

aws kinesis wait stream-exists --stream-name wsc2026-order-stream
```

확인:

```bash
aws kinesis describe-stream-summary \
  --stream-name wsc2026-order-stream \
  --query "StreamDescriptionSummary.[StreamName,StreamStatus,StreamModeDetails.StreamMode]" \
  --output text
```

기대값: `wsc2026-order-stream ACTIVE ON_DEMAND`

### 2.5 EC2 앱 배포

제공 앱 환경변수:

| 변수 | 값 |
|---|---|
| `STREAM_NAME` | `wsc2026-order-stream` |
| `AWS_REGION` | `ap-northeast-2` |

설치 예시:

```bash
sudo mkdir -p /opt/app
sudo cp app.py requirements.txt /opt/app/
cd /opt/app
sudo python3 -m venv venv
sudo /opt/app/venv/bin/pip install -r requirements.txt
```

systemd 서비스:

```ini
[Unit]
Description=WSC2026 Analytics App
After=network-online.target

[Service]
WorkingDirectory=/opt/app
Environment=STREAM_NAME=wsc2026-order-stream
Environment=AWS_REGION=ap-northeast-2
ExecStart=/opt/app/venv/bin/gunicorn -b 0.0.0.0:5000 app:app
Restart=always
User=ec2-user

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now app
sudo systemctl status app
```

EC2 role에는 Kinesis `PutRecord`, `PutRecords` 권한이 필요합니다.

### 2.6 ALB

ALB는 public subnet, EC2 target은 private subnet입니다.

| 항목 | 값 |
|---|---|
| ALB | `wsc2026-analytics-alb` |
| Listener | HTTP 80 |
| Target Group | `wsc2026-analytics-tg` |
| Target Group Port | `5000` |
| Health Check | `/health` |

채점 스크립트는 target group 이름과 port를 직접 확인합니다.

### 2.7 Managed Apache Flink

Flink Studio Notebook:

| 항목 | 값 |
|---|---|
| Application Name | `wsc2026-analytics-flink` |
| Runtime | `ZEPPELIN-FLINK-3_0` 또는 Flink 1.19 계열 |
| Status | `READY` |

Notebook에서 실행해야 하는 SQL:

```sql
SELECT COUNT(*) as order_count
FROM order_stream
WHERE event_time > CURRENT_TIMESTAMP - INTERVAL '1' MINUTE;
```

```sql
SELECT product_name, SUM(price * quantity) as total_revenue
FROM order_stream
GROUP BY product_name;
```

채점은 애플리케이션 상태와 런타임을 봅니다.

```bash
aws kinesisanalyticsv2 describe-application \
  --application-name wsc2026-analytics-flink \
  --query "ApplicationDetail.[ApplicationName,ApplicationStatus,RuntimeEnvironment]" \
  --output text
```

### 2.8 채점 확인

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names wsc2026-analytics-alb \
  --query "LoadBalancers[0].DNSName" \
  --output text)

curl -s http://${ALB_DNS}/health
curl -s -X POST http://${ALB_DNS}/order
```

Systemd 확인은 SSM으로 수행됩니다.

```bash
systemctl is-active app
systemctl is-enabled app
```

---

## Module 3. MSK


### 3.0 최신 공식 질의 답변 적용

- **채점기준 3-6:** `wsc2026-sensor-data`에서 최대 3개 Item의 `sensorId`와 `timestamp`를 조회합니다. `(timestamp)`라는 문자가 아니라 각 센서 메시지의 실제 생성 시각을 저장합니다.
- **Timestamp:** 문서의 `(timestamp)`는 고정 문자열이나 형식 예시가 아니라 메시지가 만들어진 **실제 시각**이어야 합니다.
- 출력 형식은 `YYYY-MM-DDTHH:mm:ss±HH:mm`입니다. 예: `2026-08-11T02:17:05+09:00`.
- Producer가 메시지를 만들 때마다 현재 시각을 새로 계산해야 하며 모든 레코드에 같은 샘플 Timestamp를 하드코딩하면 안 됩니다.




### 3.0-A 초보자용 8단계 구축 순서

#### 실행 장소 구분

| 장소 | 작업 |
|---|---|
| AWS CloudShell | AWS 리소스 생성·조회 |
| Producer EC2의 SSM Session | Kafka CLI, Topic, 시험 메시지, 제공 app |
| Lambda Console | 함수·환경변수·Trigger·로그 |

꺾쇠로 표시된 값은 본인이 만든 실제 ID로 바꿉니다. NUM을 쓰기 전에는 export NUM=<비번호>를 실행합니다.

#### 1. CloudShell 준비

    aws configure set region ap-northeast-1
    export NUM=<본인_비번호>
    aws sts get-caller-identity
    echo "$NUM"

Account와 비번호가 출력되면 정상입니다.

#### 2. 네트워크

msk-vpc와 2AZ Public/Private Subnet을 만든 뒤 Public은 IGW, Private은 NAT Route를 연결합니다. MSK와 Producer는 Private에 둡니다. MSK SG는 Producer SG에서 오는 TCP 9098을 허용합니다. NAT가 없으면 SSM·다운로드·AWS API가 실패할 수 있습니다.

#### 3. DynamoDB·S3·SNS·MSK

3.4 명령을 실행한 뒤 확인합니다.

    aws dynamodb wait table-exists --table-name wsc2026-sensor-data
    aws dynamodb describe-table --table-name wsc2026-sensor-data \
      --query 'Table.{Status:TableStatus,Keys:KeySchema}' --output table

ACTIVE, sensorId HASH(PK), timestamp RANGE(SK)가 정상입니다. MSK는 3.5 값으로 만든 뒤 State가 ACTIVE일 때만 다음 단계로 이동합니다.

#### 4. Kafka Topic

Producer EC2에 SSM 접속 후 3.12의 Java, Kafka, IAM Auth JAR, client.properties를 설치합니다. raw는 Partition 3/Replication 2, alert는 Partition 1/Replication 2로 생성합니다.

#### 5. Lambda와 Trigger

두 함수는 정확한 이름, Python 3.14, Private Subnet/SG, 3.8의 환경변수로 만듭니다. raw→sensor consumer, alert→alert consumer Trigger를 연결합니다.

    aws lambda list-event-source-mappings \
      --query 'EventSourceMappings[*].{Function:FunctionArn,Topics:Topics,State:State}' \
      --output table

두 State가 모두 Enabled여야 합니다.

#### 6. 실제 KST 메시지 시험

고정 샘플 시각을 쓰지 않고 메시지를 보낼 때마다 NOW를 다시 계산합니다.

    NOW=$(TZ=Asia/Seoul date --iso-8601=seconds)
    printf '{"sensorId":"SENSOR-NORMAL-001","timestamp":"%s","temperature":75.5,"humidity":45.2,"location":"factory-a"}\n' "$NOW" |
      /opt/kafka/bin/kafka-console-producer.sh \
      --bootstrap-server "$BOOTSTRAP_SERVERS" \
      --producer.config /opt/kafka/config/client.properties \
      --topic wsc2026-sensor-raw
    echo "$NOW"

ALERT 시험은 같은 명령에서 sensorId를 SENSOR-ALERT-001, temperature를 82.4로 바꿉니다.

#### 7. 채점 결과 확인

    aws dynamodb scan \
      --table-name wsc2026-sensor-data \
      --max-items 3 \
      --projection-expression 'sensorId,#ts,#st' \
      --expression-attribute-names '{"#ts":"timestamp","#st":"status"}' \
      --query 'Items[*].{sensorId:sensorId.S,timestamp:timestamp.S,status:status.S}' \
      --output table

합격 조건:
- timestamp라는 고정 문자가 아니라 실제 생성 시각.
- YYYY-MM-DDTHH:mm:ss+09:00 형식.
- 정상은 NORMAL, 82.4는 ALERT.
- 메시지를 새로 만들 때 Timestamp도 달라짐.

    aws s3 ls "s3://wsc2026-sensor-alert-bucket-$NUM/alert/" --recursive
    aws logs tail /aws/lambda/wsc2026-sensor-consumer --since 10m
    aws logs tail /aws/lambda/wsc2026-sensor-alert-consumer --since 10m

#### 8. 제공 Producer 상시 실행

수동 시험이 성공한 뒤 실행합니다.

    sudo systemctl enable --now sensor-producer
    sudo systemctl is-enabled sensor-producer
    sudo systemctl is-active sensor-producer
    sudo journalctl -u sensor-producer -n 50 --no-pager

enabled, active, SENSOR 로그가 계속 증가하면 정상입니다.

| 증상 | 먼저 확인 |
|---|---|
| Kafka timeout | TCP 9098 SG, IAM Bootstrap 주소, 같은 VPC |
| Access denied | EC2 Role의 kafka-cluster 권한 |
| Trigger 미활성 | Lambda VPC/SG, Topic, IAM |
| DynamoDB 비어 있음 | sensor consumer CloudWatch Logs |
| Timestamp 동일 | 메시지 생성 루프 안에서 현재 시각 재계산 |
| ALERT 실패 | 임계값, alert Trigger, alert consumer 로그 |



### 3.1 목표

Private MSK 클러스터를 IAM 인증으로 구성하고, EC2 Producer가 센서 데이터를 `wsc2026-sensor-raw` 토픽으로 발행합니다. Lambda consumer가 데이터를 처리해 DynamoDB에 저장하고, 이상 데이터는 `wsc2026-sensor-alert` 토픽으로 넘깁니다. Alert consumer는 SNS 알림과 S3 로그 저장을 수행합니다.

### 3.2 필수 리소스

| 항목 | 값 |
|---|---|
| Region | `ap-northeast-1` |
| VPC | `msk-vpc`, `192.168.0.0/16` |
| MSK Cluster | `wsc2026-msk-cluster` |
| Kafka Version | `3.6.0` |
| Broker Type | `kafka.t3.small` |
| Auth | IAM enabled |
| Topic 1 | `wsc2026-sensor-raw`, partitions 3, replication 2 |
| Topic 2 | `wsc2026-sensor-alert`, partitions 1, replication 2 |
| Producer EC2 | `wsc2026-sensor-producer`, `t3.small` |
| EC2 Role | `wsc2026-msk-ec2-role` |
| Lambda Role | `wsc2026-msk-lambda-role` |
| Lambda Runtime | `python3.14` |
| DynamoDB | `wsc2026-sensor-data`, PK `sensorId`, SK `timestamp` |
| S3 Bucket | `wsc2026-sensor-alert-bucket-<비번호>` |
| SNS Topic | `wsc2026-sensor-alert` |

### 3.3 네트워크

| Subnet | CIDR | Route |
|---|---|---|
| `msk-pub-a` | `192.168.0.0/24` | IGW |
| `msk-pub-d` | `192.168.1.0/24` | IGW |
| `msk-priv-a` | `192.168.10.0/24` | NAT |
| `msk-priv-d` | `192.168.11.0/24` | NAT |

MSK와 Producer EC2는 private 환경에 둡니다. Producer가 MSK broker에 접근할 수 있도록 보안 그룹에서 broker port를 허용합니다.

### 3.4 DynamoDB, S3, SNS

```bash
aws configure set region ap-northeast-1
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

### 3.5 MSK Cluster

MSK 설정:

- Cluster name: `wsc2026-msk-cluster`
- Kafka version: `3.6.0`
- Instance type: `kafka.t3.small`
- Broker subnets: private a/d
- SASL IAM authentication: enabled
- Public access: disabled

채점 확인:

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

기대값: `wsc2026-msk-cluster ACTIVE 3.6.0 kafka.t3.small True`

### 3.6 Topic 생성

MSK client EC2나 Producer EC2에서 Kafka CLI를 사용합니다.

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

`client.properties`에는 IAM auth 설정을 넣습니다.

```properties
security.protocol=SASL_SSL
sasl.mechanism=AWS_MSK_IAM
sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;
sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler
```

### 3.7 Producer EC2

제공 `Application.md` 기준 환경변수:

| 변수 | 값 |
|---|---|
| `BOOTSTRAP_SERVERS` | MSK IAM bootstrap broker endpoint |
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

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now sensor-producer
sudo journalctl -u sensor-producer -f
```

로그에 `SENSOR-001`, `SENSOR-002` 같은 출력이 계속 나오면 producer가 실행 중입니다.

### 3.8 Lambda Consumer

채점 스크립트는 다음 두 Lambda의 런타임과 event source mapping 상태를 확인합니다.

| Function | Trigger topic |
|---|---|
| `wsc2026-sensor-consumer` | `wsc2026-sensor-raw` |
| `wsc2026-sensor-alert-consumer` | `wsc2026-sensor-alert` |

Sensor consumer 처리:

1. MSK event에서 메시지를 읽습니다.
2. temperature/humidity 임계치를 확인합니다.
3. 정상 데이터는 DynamoDB에 `status=NORMAL`로 저장합니다.
4. 이상 데이터는 `status=ALERT`, `alert_reason`을 붙이고 alert topic으로 발행합니다.

이상 기준:

| 조건 | status |
|---|---|
| `temperature > 80` | ALERT |
| `temperature < 10` | ALERT |
| `humidity > 90` | ALERT |
| `humidity < 20` | ALERT |
| otherwise | NORMAL |

Alert consumer 처리:

1. `wsc2026-sensor-alert` topic 메시지 수신
2. SNS `wsc2026-sensor-alert`로 알림 발송
3. S3 `alert/{sensorId}/{date}/{timestamp}.json` 경로에 로그 저장

환경변수:

| Function | Env |
|---|---|
| sensor consumer | `DDB_TABLE=wsc2026-sensor-data`, `ALERT_TOPIC=wsc2026-sensor-alert`, `BOOTSTRAP_SERVER=<broker>` |
| alert consumer | `SNS_TOPIC_ARN=<SNS ARN>`, `S3_BUCKET=wsc2026-sensor-alert-bucket-<비번호>` |

### 3.9 Event Source Mapping

MSK Lambda trigger를 두 함수에 연결합니다.

```bash
aws lambda create-event-source-mapping \
  --function-name wsc2026-sensor-consumer \
  --event-source-arn ${CLUSTER_ARN} \
  --topics wsc2026-sensor-raw \
  --starting-position LATEST \
  --source-access-configurations Type=VPC_SUBNET,URI=subnet:<PRIVATE_SUBNET_ID> Type=VPC_SECURITY_GROUP,URI=security_group:<LAMBDA_SG_ID>

aws lambda create-event-source-mapping \
  --function-name wsc2026-sensor-alert-consumer \
  --event-source-arn ${CLUSTER_ARN} \
  --topics wsc2026-sensor-alert \
  --starting-position LATEST \
  --source-access-configurations Type=VPC_SUBNET,URI=subnet:<PRIVATE_SUBNET_ID> Type=VPC_SECURITY_GROUP,URI=security_group:<LAMBDA_SG_ID>
```

채점 확인:

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

### 3.10 Data Processing 확인

```bash
aws dynamodb scan \
  --table-name wsc2026-sensor-data \
  --max-items 1 \
  --query "Items[0].{sensorId:sensorId.S,temperature:temperature.S,status:status.S}" \
  --output table
```

```bash
aws dynamodb scan \
  --table-name wsc2026-sensor-data \
  --max-items 3 \
  --query "Items[*].{sensorId:sensorId.S,timestamp:timestamp.S}" \
  --output table
```

Producer가 계속 실행 중이면 데이터가 쌓이고, 위 명령에서 sensorId와 timestamp가 표시됩니다.


### 3.11 Timestamp 구현과 검증

Python Producer에서는 timezone이 포함된 실제 현재 시각을 다음처럼 생성합니다.

```python
from datetime import datetime, timezone

timestamp = datetime.now().astimezone().isoformat(timespec="seconds")
# 예: 2026-08-11T02:17:05+09:00

message = {
    "sensorId": sensor_id,
    "temperature": temperature,
    "humidity": humidity,
    "timestamp": timestamp,
}
```

채점표는 KST Offset `+09:00`을 명시적으로 요구합니다. 코드에서 KST를 지정해야 하며 `+00:00`이면 3-6에서 오답 처리될 수 있습니다.

```bash
aws dynamodb scan \
  --table-name wsc2026-sensor-data \
  --projection-expression "sensorId,#ts" \
  --expression-attribute-names '{"#ts":"timestamp"}' \
  --query "Items[*].[sensorId.S,timestamp.S]" \
  --output table
```

확인할 사항:

1. `timestamp`가 빈 값 또는 문자 `(timestamp)`가 아닌 실제 시각인지 확인합니다.
2. 메시지를 여러 번 생성했을 때 Timestamp가 계속 갱신되는지 확인합니다.
3. 날짜와 시각 사이에 `T`, 끝부분에 KST Offset `+09:00`이 있는지 확인합니다.
4. S3 Key의 `alert/{sensorId}/{date}/{timestamp}.json`에도 실제 Timestamp를 사용합니다. 파일명에 사용할 수 있도록 필요하면 `:`만 안전한 문자로 치환하되 JSON 본문은 원래 Timestamp를 보존합니다.

---



### 3.12 Kafka CLI 사용법 — IAM 인증

Kafka CLI는 MSK와 같은 VPC의 Producer EC2 또는 Bastion에서 실행합니다. CloudShell은 기본적으로 Private MSK Broker에 네트워크로 연결되지 않으므로 Topic 작업은 EC2의 SSM Session 안에서 수행합니다.

#### 1) Producer EC2 접속과 Java 확인

    export AWS_DEFAULT_REGION=ap-northeast-1
    aws ssm start-session --target <PRODUCER_INSTANCE_ID>

SSM 접속 후:

    sudo dnf install -y java-17-amazon-corretto-headless wget tar
    java -version

Broker 버전과 맞춰 Kafka 3.6.0 CLI를 설치합니다.

    cd /opt
    sudo wget -q https://archive.apache.org/dist/kafka/3.6.0/kafka_2.13-3.6.0.tgz
    sudo tar -xzf kafka_2.13-3.6.0.tgz
    sudo ln -sfn /opt/kafka_2.13-3.6.0 /opt/kafka
    sudo mkdir -p /opt/kafka/libs
    sudo chown -R ec2-user:ec2-user /opt/kafka_2.13-3.6.0 /opt/kafka

#### 2) AWS IAM 인증 플러그인

    cd /opt/kafka/libs
    wget -q https://github.com/aws/aws-msk-iam-auth/releases/download/v2.3.2/aws-msk-iam-auth-2.3.2-all.jar

    cat > /opt/kafka/config/client.properties <<'EOF'
    security.protocol=SASL_SSL
    sasl.mechanism=AWS_MSK_IAM
    sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;
    sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler
    EOF

    export CLASSPATH=/opt/kafka/libs/aws-msk-iam-auth-2.3.2-all.jar
    grep -v '^#' /opt/kafka/config/client.properties

EC2 Instance Role에는 최소한 kafka-cluster:Connect, DescribeCluster, DescribeTopic, CreateTopic, ReadData, WriteData, AlterGroup, DescribeGroup 권한이 있어야 합니다. Resource ARN은 실제 Cluster, Topic, Group으로 제한합니다.

#### 3) IAM Bootstrap Broker 조회

CloudShell 또는 EC2에서 Cluster ARN을 확인합니다.

    export AWS_DEFAULT_REGION=ap-northeast-1
    export CLUSTER_ARN=$(aws kafka list-clusters-v2 \
      --cluster-name-filter wsc2026-msk-cluster \
      --query 'ClusterInfoList[0].ClusterArn' --output text)

    export BOOTSTRAP_SERVERS=$(aws kafka get-bootstrap-brokers \
      --cluster-arn "$CLUSTER_ARN" \
      --query BootstrapBrokerStringSaslIam --output text)

    echo "$CLUSTER_ARN"
    echo "$BOOTSTRAP_SERVERS"

BootstrapBrokerString 또는 TLS 문자열이 아니라 반드시 BootstrapBrokerStringSaslIam 값과 9098 포트를 사용합니다.

#### 4) Topic 생성

    /opt/kafka/bin/kafka-topics.sh \
      --bootstrap-server "$BOOTSTRAP_SERVERS" \
      --command-config /opt/kafka/config/client.properties \
      --create --if-not-exists \
      --topic wsc2026-sensor-raw \
      --partitions 3 --replication-factor 2

    /opt/kafka/bin/kafka-topics.sh \
      --bootstrap-server "$BOOTSTRAP_SERVERS" \
      --command-config /opt/kafka/config/client.properties \
      --create --if-not-exists \
      --topic wsc2026-sensor-alert \
      --partitions 1 --replication-factor 2

채점 확인:

    /opt/kafka/bin/kafka-topics.sh \
      --bootstrap-server "$BOOTSTRAP_SERVERS" \
      --command-config /opt/kafka/config/client.properties \
      --describe --topic wsc2026-sensor-raw

    /opt/kafka/bin/kafka-topics.sh \
      --bootstrap-server "$BOOTSTRAP_SERVERS" \
      --command-config /opt/kafka/config/client.properties \
      --describe --topic wsc2026-sensor-alert

raw는 PartitionCount 3, ReplicationFactor 2이고 alert는 PartitionCount 1, ReplicationFactor 2여야 합니다.

#### 5) Console Producer로 시험 메시지 발행

    /opt/kafka/bin/kafka-console-producer.sh \
      --bootstrap-server "$BOOTSTRAP_SERVERS" \
      --producer.config /opt/kafka/config/client.properties \
      --topic wsc2026-sensor-raw

실행 후 한 줄짜리 JSON을 입력하고 Enter를 누릅니다.

    {"sensorId":"SENSOR-CLI-001","timestamp":"2026-08-24T11:30:00+09:00","temperature":82.4,"humidity":48.7,"location":"factory-a"}

입력이 끝나면 Ctrl+C로 종료합니다. sensorId가 DynamoDB PK이고 timestamp가 SK이므로 두 값은 빈 문자열이면 안 됩니다.

파일을 파이프로 전송할 수도 있습니다.

    printf '%s\n' '{"sensorId":"SENSOR-CLI-002","timestamp":"2026-08-24T11:31:00+09:00","temperature":75.5,"humidity":45.2,"location":"factory-b"}' |
      /opt/kafka/bin/kafka-console-producer.sh \
      --bootstrap-server "$BOOTSTRAP_SERVERS" \
      --producer.config /opt/kafka/config/client.properties \
      --topic wsc2026-sensor-raw

#### 6) Console Consumer로 메시지 확인

새 터미널에서 실행합니다.

    export CLASSPATH=/opt/kafka/libs/aws-msk-iam-auth-2.3.2-all.jar

    /opt/kafka/bin/kafka-console-consumer.sh \
      --bootstrap-server "$BOOTSTRAP_SERVERS" \
      --consumer.config /opt/kafka/config/client.properties \
      --topic wsc2026-sensor-raw \
      --from-beginning \
      --max-messages 5 \
      --property print.partition=true \
      --property print.offset=true

실시간 확인만 할 때는 --from-beginning과 --max-messages를 빼고 실행한 뒤 Ctrl+C로 종료합니다.

alert Topic 확인:

    /opt/kafka/bin/kafka-console-consumer.sh \
      --bootstrap-server "$BOOTSTRAP_SERVERS" \
      --consumer.config /opt/kafka/config/client.properties \
      --topic wsc2026-sensor-alert \
      --from-beginning --max-messages 5

#### 7) Consumer Group과 Lag 확인

    /opt/kafka/bin/kafka-consumer-groups.sh \
      --bootstrap-server "$BOOTSTRAP_SERVERS" \
      --command-config /opt/kafka/config/client.properties \
      --list

    /opt/kafka/bin/kafka-consumer-groups.sh \
      --bootstrap-server "$BOOTSTRAP_SERVERS" \
      --command-config /opt/kafka/config/client.properties \
      --describe --group <GROUP_ID>

LAG가 계속 증가하면 Lambda Event Source Mapping 상태, Lambda 오류, IAM 권한, VPC SG를 함께 확인합니다. Lambda managed MSK trigger의 내부 Group ID는 자동 생성될 수 있으므로 먼저 --list 결과에서 찾습니다.

#### 8) 제공 Producer 실행

    cd ~/day2_release_files/module3
    chmod +x app
    export BOOTSTRAP_SERVERS="$BOOTSTRAP_SERVERS"
    export TOPIC_RAW=wsc2026-sensor-raw
    ./app

재부팅 뒤에도 자동 실행되도록 systemd에 같은 두 환경변수를 넣고 enable --now 합니다. 로그 확인:

    sudo systemctl status sensor-producer --no-pager
    sudo journalctl -u sensor-producer -n 100 --no-pager

#### 9) 자주 발생하는 오류

| 오류 | 원인과 해결 |
|---|---|
| Connection to node could not be established | EC2가 MSK SG의 TCP 9098에 접근 가능한지 확인 |
| Access denied | EC2 Role의 kafka-cluster 권한과 Cluster/Topic/Group ARN 확인 |
| Class IAMClientCallbackHandler could not be found | CLASSPATH와 IAM auth JAR 경로 확인 |
| TimeoutException | Private DNS, Broker 상태, 올바른 IAM Bootstrap 주소 확인 |
| TopicExistsException | 정상입니다. --if-not-exists 사용 |
| Replication factor larger than available brokers | Broker가 2개 모두 Active인지 확인 |


## Module 4. CDN Service Setup (3점)

고정값: us-east-1, Comment wsk2026-cf, S3 wsk2026-encrypted-data-<비번호>, HTTP API wsk2026-api, Lambda wsk2026-now. 단일 CloudFront 주소에서 POST /now와 GET /static/image.png가 동작해야 합니다.

### 콘솔 구축

1. KMS Customer managed key 생성(DSSE 금지).
2. S3 버킷 생성 → 기본 암호화 CMK → static/image.png 업로드 → Public access 전부 차단.
3. Lambda wsk2026-now 생성. 매 호출마다 현재 KST 문장을 반환.
4. HTTP API wsk2026-api의 POST /now를 Lambda와 통합.
5. CloudFront S3 Origin은 OAI, 기본 동작은 CachingOptimized.
6. /now 동작은 API Origin, POST 허용, CachingDisabled, HTTPS only.
7. image.png 교체 뒤 invalidation을 생성하여 3분 내 반영.

### CloudShell

    export AWS_DEFAULT_REGION=us-east-1
    export NUM=<비번호>
    export BUCKET=wsk2026-encrypted-data-$NUM
    KEY_ID=$(aws kms create-key --description "wsk2026 CDN CMK" --query KeyMetadata.KeyId --output text)
    aws kms create-alias --alias-name alias/wsk2026-cdn-key --target-key-id "$KEY_ID"
    aws s3api create-bucket --bucket "$BUCKET"
    aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms","KMSMasterKeyID":"'"$KEY_ID"'"},"BucketKeyEnabled":true}]}'
    aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    aws s3 cp ~/day2_release_files/module4/image.png s3://$BUCKET/static/image.png --sse aws:kms --sse-kms-key-id "$KEY_ID"

Lambda 코드:

    from datetime import datetime, timezone, timedelta
    def lambda_handler(event, context):
        n=datetime.now(timezone(timedelta(hours=9)))
        body=f"현재 시각은 {n.year}년 {n.month}월 {n.day}일 {n.hour}시 {n.minute}분 {n.second}초입니다."
        return {"statusCode":200,"headers":{"content-type":"text/plain; charset=utf-8","cache-control":"no-store"},"body":body}

검증 및 파일 갱신:

    export DIST_ID=<배포ID>
    export CF_DOMAIN=$(aws cloudfront get-distribution --id "$DIST_ID" --query Distribution.DomainName --output text)
    curl -X POST https://$CF_DOMAIN/now
    sleep 2
    curl -X POST https://$CF_DOMAIN/now
    curl -I https://$CF_DOMAIN/static/image.png
    aws s3api get-bucket-encryption --bucket "$BUCKET"
    aws s3api get-public-access-block --bucket "$BUCKET"
    aws s3 cp ./image.png s3://$BUCKET/static/image.png --sse aws:kms --sse-kms-key-id "$KEY_ID"
    aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths /static/image.png
    aws cloudfront list-invalidations --distribution-id "$DIST_ID" --query 'InvalidationList.Items[0].{Status:Status,CreateTime:CreateTime}'

두 POST 결과 시간이 달라야 합니다. Lambda permission SourceArn은 해당 API POST /now로 제한합니다. S3는 비공개/OAI만 허용합니다.

---

## Module 5. Legacy System Operation (6점)

고정값: eu-central-1, ALB shgold-alb, ECS Cluster shgold-cluster, Lambda shgold-ingestion, Aurora shgold-mysql(MySQL 8.4.x). 모두 이름과 Name tag를 맞춥니다. 실제 root/stub은 ARM64 Linux 실행파일입니다.

### 콘솔 구축

1. 2AZ VPC: ALB Public, ECS/Aurora/Lambda Private.
2. SG: Internet→ALB:80, ALB→ECS:8080, ECS/Lambda→Aurora:3306, ECS→EFS:2049.
3. Aurora shgold-mysql과 Secrets Manager secret 생성.
4. EFS를 root의 /mnt/shgold-efs에 마운트.
5. ARM64 Fargate Task 한 개에 root:8080과 stub:8081을 함께 배치. root가 localhost:8081로 stub 호출.
6. Service desired count 2. ALB 기본 규칙은 root TG, /ingest는 Lambda TG.
7. Lambda 환경변수: DB_HOST, DB_PORT=3306, DB_NAME=shgold, DB_SECRET_NAME, TABLE_NAME=readings, HEALTH_PATH=/healthz.

DB:

    CREATE DATABASE IF NOT EXISTS shgold;
    USE shgold;
    CREATE TABLE IF NOT EXISTS readings (
      id CHAR(36) NOT NULL PRIMARY KEY,
      device_id VARCHAR(64) NOT NULL,
      metric VARCHAR(64) NOT NULL,
      value DOUBLE NOT NULL,
      recorded_at DATETIME NOT NULL,
      created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      INDEX idx_device_recorded (device_id, recorded_at)
    );

ECR과 ARM64 이미지:

    export AWS_DEFAULT_REGION=eu-central-1
    export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    aws ecr create-repository --repository-name shgold-root
    aws ecr create-repository --repository-name shgold-stub
    aws ecr get-login-password | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.eu-central-1.amazonaws.com
    docker buildx build --platform linux/arm64 -t shgold-root:latest ./module5/root --load
    docker buildx build --platform linux/arm64 -t shgold-stub:latest ./module5/stub --load

Dockerfile은 Amazon Linux 2023 기반, 실행파일/config.ini 복사, chmod +x, root는 8080/stub은 8081을 노출합니다. Task Definition은 Linux/ARM64, awsvpc, Fargate입니다.

Lambda 패키징:

    cd ~/day2_release_files/module5/shgold-ingestion
    python3 -m pip install -r requirements.txt -t package
    cp lambda_function.py package/
    (cd package && zip -qr ../shgold-ingestion.zip .)
    aws lambda create-function --function-name shgold-ingestion --runtime python3.12 --handler lambda_function.lambda_handler --role arn:aws:iam::$ACCOUNT_ID:role/shgold-ingestion-role --zip-file fileb://shgold-ingestion.zip --timeout 15 --memory-size 512
    aws lambda tag-resource --resource $(aws lambda get-function --function-name shgold-ingestion --query Configuration.FunctionArn --output text) --tags Name=shgold-ingestion
    aws lambda add-permission --function-name shgold-ingestion --statement-id alb-invoke --action lambda:InvokeFunction --principal elasticloadbalancing.amazonaws.com --source-arn <LAMBDA_TARGET_GROUP_ARN>

기능·1초 시험:

    export ALB_DNS=<shgold-alb-DNS>
    curl -sS -w '\nHTTP=%{http_code} TIME=%{time_total}s\n' http://$ALB_DNS/healthz
    ID=$(curl -sS -X POST http://$ALB_DNS/ingest -H 'Content-Type: application/json' -d '{"device_id":"category-stuff-1","metric":"temp","value":82.4}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
    curl -sS -w '\nHTTP=%{http_code} TIME=%{time_total}s\n' http://$ALB_DNS/v1/readings/$ID
    for i in $(seq 1 20); do curl -s -o /dev/null -w '%{http_code} %{time_total}\n' http://$ALB_DNS/v1/readings/$ID; done
    aws ecs describe-services --cluster shgold-cluster --services shgold-service --query 'services[0].{desired:desiredCount,running:runningCount}'
    aws rds describe-db-clusters --db-cluster-identifier shgold-mysql --query 'DBClusters[0].{Version:EngineVersion,Status:Status,Endpoint:Endpoint}'

모든 API는 1초 미만이 목표입니다. ECS 2개 이상, /healthz, Aurora 연결 재사용, id PK 조회, Secrets Manager 반복 호출 방지를 확인합니다.

---


## Module 5 보강 해설 — 처음부터 끝까지

### 5-A. 요청 흐름

| 요청 | ALB 규칙 | 대상 |
|---|---|---|
| GET /healthz | 기본 | ECS root:8080 |
| GET /v1/readings/{id} | 기본 | root → 같은 Task의 stub:8081 → Aurora |
| POST /ingest | /ingest | Lambda Target Group → Aurora |

root와 stub은 한 Fargate Task에 둡니다. 같은 Task는 localhost를 공유하므로 제공된 root 설정의 upstream 8081이 그대로 동작합니다. ALB에는 root:8080만 등록하며 stub은 외부에 공개하지 않습니다.

### 5-B. 네트워크와 보안그룹

    export AWS_DEFAULT_REGION=eu-central-1
    export VPC_ID=<VPC_ID>
    export PUB_A=<PUBLIC_A>
    export PUB_B=<PUBLIC_B>
    export PRIV_A=<PRIVATE_A>
    export PRIV_B=<PRIVATE_B>
    export ALB_SG=<ALB_SG>
    export ECS_SG=<ECS_SG>
    export DB_SG=<DB_SG>
    export EFS_SG=<EFS_SG>
    export LAMBDA_SG=<LAMBDA_SG>

    aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0
    aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 8080 --source-group "$ALB_SG"
    aws ec2 authorize-security-group-ingress --group-id "$DB_SG" --protocol tcp --port 3306 --source-group "$ECS_SG"
    aws ec2 authorize-security-group-ingress --group-id "$DB_SG" --protocol tcp --port 3306 --source-group "$LAMBDA_SG"
    aws ec2 authorize-security-group-ingress --group-id "$EFS_SG" --protocol tcp --port 2049 --source-group "$ECS_SG"

Private Subnet에는 ECR·CloudWatch Logs·Secrets Manager 접근용 NAT 또는 VPC Endpoint가 필요합니다. DB, EFS, stub 8081은 0.0.0.0/0으로 열지 않습니다.

### 5-C. Aurora·Secret·DB 초기화

콘솔에서 Private DB Subnet Group을 만들고 Aurora MySQL 8.4.x, identifier shgold-mysql, Public access No, DB_SG로 생성합니다. Secrets Manager에는 shgold/aurora/credentials 이름으로 username/password JSON을 저장합니다.

    export DB_ENDPOINT=$(aws rds describe-db-clusters --db-cluster-identifier shgold-mysql --query 'DBClusters[0].Endpoint' --output text)
    aws rds describe-db-clusters --db-cluster-identifier shgold-mysql --query 'DBClusters[0].{Engine:Engine,Version:EngineVersion,Status:Status,Encrypted:StorageEncrypted,Endpoint:Endpoint}'

VPC 내부 Bastion/SSM 서버에서 mysql로 접속하여 앞 절의 CREATE DATABASE/TABLE을 실행하고 SHOW CREATE TABLE readings로 PK와 형식을 확인합니다.

### 5-D. EFS

    export EFS_ID=$(aws efs create-file-system --encrypted --tags Key=Name,Value=shgold-efs --query FileSystemId --output text)
    aws efs create-mount-target --file-system-id "$EFS_ID" --subnet-id "$PRIV_A" --security-groups "$EFS_SG"
    aws efs create-mount-target --file-system-id "$EFS_ID" --subnet-id "$PRIV_B" --security-groups "$EFS_SG"
    export AP_ID=$(aws efs create-access-point --file-system-id "$EFS_ID" --posix-user Uid=0,Gid=0 --root-directory 'Path=/shgold,CreationInfo={OwnerUid=0,OwnerGid=0,Permissions=0777}' --query AccessPointId --output text)

두 AZ의 Mount Target이 available이어야 합니다. Task Definition에서 transit encryption을 켜고 root 컨테이너에 /mnt/shgold-efs로 마운트합니다.

### 5-E. 제공 설정파일

root/config.ini는 port 8080, upstream port 8081, shared_dir /mnt/shgold-efs를 유지합니다. stub/config.ini는 다음만 현장 값으로 변경합니다.

    [server]
    port = 8081
    [aws]
    region = eu-central-1
    [database]
    host = <AURORA_WRITER_ENDPOINT>
    port = 3306
    dbname = shgold
    user =
    password =
    secret_name = shgold/aurora/credentials

평문 password 대신 Secret을 사용합니다. Task는 Linux/ARM64, awsvpc, Fargate, root/stub 모두 essential, awslogs 사용, root가 stub START 이후 시작하도록 설정합니다.

### 5-F. IAM 핵심

- ECS execution role: AmazonECSTaskExecutionRolePolicy.
- ECS task role: 해당 Secret의 secretsmanager:GetSecretValue와 해당 KMS key의 kms:Decrypt.
- Lambda role: AWSLambdaBasicExecutionRole, AWSLambdaVPCAccessExecutionRole, 같은 Secret/KMS 최소권한.
- 과도한 AdministratorAccess 대신 ARN을 실제 Secret/Key로 제한합니다.

### 5-G. ALB와 ECS

    export ROOT_TG_ARN=$(aws elbv2 create-target-group --name shgold-root-tg --protocol HTTP --port 8080 --vpc-id "$VPC_ID" --target-type ip --health-check-path /healthz --query 'TargetGroups[0].TargetGroupArn' --output text)
    export LAMBDA_TG_ARN=$(aws elbv2 create-target-group --name shgold-ingestion-tg --target-type lambda --query 'TargetGroups[0].TargetGroupArn' --output text)
    export ALB_ARN=$(aws elbv2 create-load-balancer --name shgold-alb --type application --scheme internet-facing --subnets "$PUB_A" "$PUB_B" --security-groups "$ALB_SG" --tags Key=Name,Value=shgold-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)

    aws lambda add-permission --function-name shgold-ingestion --statement-id alb-invoke --action lambda:InvokeFunction --principal elasticloadbalancing.amazonaws.com --source-arn "$LAMBDA_TG_ARN"
    aws elbv2 register-targets --target-group-arn "$LAMBDA_TG_ARN" --targets Id=$(aws lambda get-function --function-name shgold-ingestion --query Configuration.FunctionArn --output text)

ALB Listener 80의 기본 action은 ROOT_TG_ARN, priority 10의 path /ingest 규칙은 LAMBDA_TG_ARN으로 지정합니다.

    aws ecs create-cluster --cluster-name shgold-cluster --tags key=Name,value=shgold-cluster
    aws ecs create-service --cluster shgold-cluster --service-name shgold-service --task-definition shgold-task --desired-count 2 --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[$PRIV_A,$PRIV_B],securityGroups=[$ECS_SG],assignPublicIp=DISABLED}" --load-balancers "targetGroupArn=$ROOT_TG_ARN,containerName=root,containerPort=8080" --health-check-grace-period-seconds 60
    aws ecs wait services-stable --cluster shgold-cluster --services shgold-service

### 5-H. Lambda 설정 확인

제공 Lambda는 ALB event/response, Secret 캐시, DB connection 재사용을 이미 구현하므로 새로 작성하지 않습니다.

    aws lambda update-function-configuration --function-name shgold-ingestion --vpc-config "SubnetIds=$PRIV_A,$PRIV_B,SecurityGroupIds=$LAMBDA_SG" --environment "Variables={DB_HOST=$DB_ENDPOINT,DB_PORT=3306,DB_NAME=shgold,DB_USER=<DB_USER>,DB_SECRET_NAME=shgold/aurora/credentials,TABLE_NAME=readings,HEALTH_PATH=/healthz}" --timeout 15 --memory-size 512
    aws lambda wait function-updated --function-name shgold-ingestion
    aws lambda get-function-configuration --function-name shgold-ingestion --query '{Runtime:Runtime,Vpc:VpcConfig,Env:Environment.Variables}'

### 5-I. 점수별 합격 증거

| 채점항목 | 합격 증거 |
|---|---|
| Service Provisioning 1 | ALB active, ECS 2/2, TG healthy, Aurora available |
| Data Ingestion 1 | POST /ingest 2xx, UUID 반환, DB row 존재 |
| Success Rate 1 | health/ingest/read 반복 호출 모두 2xx |
| Performance Tuning 1.5 | 각 time_total 1.000 미만 |
| Serverless Computing 1.5 | /ingest ALB 규칙 → Lambda TG → Aurora 저장 |

장애 진단:
- CannotPullContainerError: NAT/ECR Endpoint와 execution role.
- EFS timeout/root 즉시 종료: 두 AZ Mount Target, 2049 SG, /mnt/shgold-efs.
- root 502/504: stub 실행 여부, 8081, 같은 Task, stub config.
- Lambda DB 502: Lambda SG→DB SG 3306, Endpoint, Secret JSON.
- ALB Lambda 502: add-permission, Lambda target 등록, 제공 코드 유지.
- 1초 초과: Secret/NAT 지연, ECS CPU/Memory, Aurora 연결, id PK와 CloudWatch 로그 확인.


## 실제 채점표 30점 체크리스트

| 모듈 | 항목(점수) |
|---|---|
| Workflow 7 | S3 1, DynamoDB 1, Lambda+Runtime+Env 1, State Machine 1, Normal 1.5, Error 1.5 |
| Analytics 7 | EC2 0.5, ALB 1, Stream 1, Data 1, Flink 1, Health 1, Systemd 1.5 |
| MSK 7 | Resources 0.5, Lambdas 1.5, Cluster 1.5, Trigger Mapping 1.5, Processing 1, Producer 1 |
| CDN 3 | CloudFront OAI 1, Cache Invalidation 1, API Security 1 |
| Legacy 6 | Provisioning 1, Ingestion 1, Success Rate 1, Performance 1.5, Serverless 1.5 |
| 합계 | 30 |

채점 직전:

    aws sts get-caller-identity
    AWS_DEFAULT_REGION=ap-southeast-1 aws stepfunctions list-state-machines --query "stateMachines[?name=='wsc2026-student-score-workflow']"
    AWS_DEFAULT_REGION=ap-northeast-2 aws kinesis describe-stream-summary --stream-name wsc2026-order-stream --query StreamDescriptionSummary.StreamStatus
    AWS_DEFAULT_REGION=ap-northeast-1 aws lambda list-event-source-mappings --query 'EventSourceMappings[*].{State:State,Topics:Topics}'
    curl -X POST https://<CLOUDFRONT_DOMAIN>/now
    curl -I https://<CLOUDFRONT_DOMAIN>/static/image.png
    curl -fsS http://<SHGOLD_ALB_DNS>/healthz
