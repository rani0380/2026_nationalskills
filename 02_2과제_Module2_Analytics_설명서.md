# 02_2과제 Module 2 설명서: Real-time Data Analytics

## 목표

Private subnet의 EC2에서 주문 로그 생성 애플리케이션을 실행하고, ALB를 통해 외부 요청을 받아 Kinesis Data Stream으로 이벤트를 전송합니다. Managed Apache Flink Studio Notebook에서 Kinesis 데이터를 SQL로 실시간 분석합니다.

## 핵심 아키텍처

```text
Client
  -> ALB HTTP 80
  -> Private EC2 Flask/Gunicorn app:5000
  -> Kinesis Data Stream
  -> Managed Apache Flink Studio Notebook
  -> SQL 분석
```

## 필수 리소스

| 항목 | 값 |
|---|---|
| Region | `ap-northeast-2` |
| VPC | `analytics-vpc`, `10.20.0.0/16` |
| EC2 | `wsc2026-analytics-ec2`, `t3.small` |
| EC2 Role | `wsc2026-alaytics-ec2-role` |
| ALB | `wsc2026-analytics-alb`, HTTP 80 |
| Target Group | `wsc2026-analytics-tg`, port `5000` |
| Kinesis | `wsc2026-order-stream`, ON_DEMAND |
| Flink | `wsc2026-analytics-flink` |
| Flink Role | `wsc2026-analytics-flink-role` |

## 이론 설명

### 왜 EC2는 Private Subnet에 두는가

애플리케이션 서버를 직접 인터넷에 노출하지 않고, ALB만 public subnet에 둡니다. 이렇게 하면 보안 그룹과 ALB health check를 기준으로 진입점을 통제할 수 있습니다.

### ALB와 Target Group

ALB는 HTTP 요청을 받고 target group은 실제 애플리케이션 포트로 요청을 전달합니다. 제공 Flask 앱은 Gunicorn으로 `5000` 포트에서 실행되므로 target group port도 `5000`이어야 합니다.

### Kinesis Data Stream

Kinesis는 실시간 이벤트 수집 파이프입니다. `/order` API가 호출될 때마다 주문 JSON이 Kinesis record로 저장됩니다.

| 개념 | 설명 |
|---|---|
| Stream | 이벤트가 들어가는 논리적 파이프 |
| Record | 주문 JSON 1건 |
| PartitionKey | record 분산 기준 |
| ON_DEMAND | shard 수를 직접 관리하지 않는 용량 모드 |

### Managed Apache Flink

Flink는 스트림 데이터를 지속적으로 처리하는 분석 엔진입니다. 이 과제에서는 Flink 애플리케이션 코딩이 아니라 Studio Notebook SQL 실행이 핵심입니다.

## 구축 순서

1. `ap-northeast-2` 리전 설정
2. `analytics-vpc`와 public/private subnet 생성
3. NAT Gateway 구성
4. Kinesis Data Stream 생성
5. EC2 Role에 Kinesis write 권한 부여
6. Private subnet에 EC2 생성
7. `/opt/app`에 제공 앱 배포
8. systemd 서비스 `app` 등록
9. ALB와 target group 구성
10. Managed Flink Studio Notebook 생성
11. SQL 쿼리 실행

## 앱 환경변수

| 변수 | 값 |
|---|---|
| `STREAM_NAME` | `wsc2026-order-stream` |
| `AWS_REGION` | `ap-northeast-2` |

## systemd 예시

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
systemctl is-active app
systemctl is-enabled app
```

## Kinesis 생성

```bash
aws configure set region ap-northeast-2

aws kinesis create-stream \
  --stream-name wsc2026-order-stream \
  --stream-mode-details StreamMode=ON_DEMAND

aws kinesis wait stream-exists --stream-name wsc2026-order-stream
```

## Flink SQL

최근 1분 주문 수:

```sql
SELECT COUNT(*) as order_count
FROM order_stream
WHERE event_time > CURRENT_TIMESTAMP - INTERVAL '1' MINUTE;
```

상품별 누적 매출:

```sql
SELECT product_name, SUM(price * quantity) as total_revenue
FROM order_stream
GROUP BY product_name;
```

## 채점 확인

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names wsc2026-analytics-alb \
  --query "LoadBalancers[0].DNSName" \
  --output text)

curl -s http://${ALB_DNS}/health
curl -s -X POST http://${ALB_DNS}/order
```

```bash
aws kinesis describe-stream-summary \
  --stream-name wsc2026-order-stream \
  --query "StreamDescriptionSummary.[StreamName,StreamStatus,StreamModeDetails.StreamMode]" \
  --output text
```

기대값:

```text
wsc2026-order-stream ACTIVE ON_DEMAND
```

## 자주 틀리는 부분

| 실수 | 해결 |
|---|---|
| EC2를 public subnet에 생성 | private subnet으로 생성하고 ALB만 public 배치 |
| target group port를 80으로 설정 | `wsc2026-analytics-tg` port는 `5000` |
| 앱을 수동 실행만 함 | `app.service` systemd 등록 및 enable |
| EC2 Role 이름 오타 수정 | 채점 기준상 `wsc2026-alaytics-ec2-role` 그대로 사용 |
| Kinesis provisioned mode 사용 | ON_DEMAND 모드로 생성 |

## 2.9 한 번에 보는 정답 구성표

| 계층 | 리소스 | 정답 |
|---|---|---|
| Network | analytics-vpc | 10.20.0.0/16 |
| Public | analytics-pub-a / b | 10.20.0.0/24, 10.20.1.0/24 |
| Private | analytics-priv-a / b | 10.20.100.0/24, 10.20.101.0/24 |
| EC2 | wsc2026-analytics-ec2 | t3.small, Private Subnet, Public IP 없음 |
| EC2 IAM | wsc2026-alaytics-ec2-role | Kinesis write + AmazonSSMManagedInstanceCore |
| App | app.service | active, enabled, Gunicorn :5000 |
| ALB | wsc2026-analytics-alb | internet-facing, HTTP 80 |
| Target Group | wsc2026-analytics-tg | Instance / HTTP 5000 / health /health |
| Kinesis | wsc2026-order-stream | ACTIVE, ON_DEMAND |
| Flink | wsc2026-analytics-flink | Studio, ZEPPELIN-FLINK-3_0, READY |
| Flink IAM | wsc2026-analytics-flink-role | Kinesis read + Glue Catalog |

EC2 Role 이름의 alaytics 오타는 채점 기준이므로 고치지 않습니다.

## 2.10 지급파일과 변수 준비

[Module 2 지급파일 다운로드](downloads/task02-modules/module2.zip)

압축파일에는 app.py, requirements.txt, Application.md가 들어 있습니다.

```bash
aws configure set region ap-northeast-2
export REGION=ap-northeast-2
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AZ_A=ap-northeast-2a
export AZ_B=ap-northeast-2b

printf 'ACCOUNT=%s REGION=%s\n' "$ACCOUNT_ID" "$REGION"
```

## 2.11 VPC 전체 구축

### VPC와 Subnet

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.20.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=analytics-vpc}]' \
  --query Vpc.VpcId --output text)

aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'

export PUB_A=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --availability-zone "$AZ_A" \
  --cidr-block 10.20.0.0/24 \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=analytics-pub-a}]' \
  --query Subnet.SubnetId --output text)

export PUB_B=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --availability-zone "$AZ_B" \
  --cidr-block 10.20.1.0/24 \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=analytics-pub-b}]' \
  --query Subnet.SubnetId --output text)

export PRIV_A=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --availability-zone "$AZ_A" \
  --cidr-block 10.20.100.0/24 \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=analytics-priv-a}]' \
  --query Subnet.SubnetId --output text)

export PRIV_B=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --availability-zone "$AZ_B" \
  --cidr-block 10.20.101.0/24 \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=analytics-priv-b}]' \
  --query Subnet.SubnetId --output text)

aws ec2 modify-subnet-attribute --subnet-id "$PUB_A" --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id "$PUB_B" --map-public-ip-on-launch
```

### IGW, NAT Gateway, Route Table

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=analytics-igw}]' \
  --query InternetGateway.InternetGatewayId --output text)

aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

export EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=analytics-nat-eip}]' \
  --query AllocationId --output text)

export NAT_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUB_A" --allocation-id "$EIP_ALLOC" \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=analytics-nat}]' \
  --query NatGateway.NatGatewayId --output text)

aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID"

export RT_PUB=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=analytics-rt-pub}]' \
  --query RouteTable.RouteTableId --output text)

aws ec2 create-route --route-table-id "$RT_PUB" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"
aws ec2 associate-route-table --route-table-id "$RT_PUB" --subnet-id "$PUB_A"
aws ec2 associate-route-table --route-table-id "$RT_PUB" --subnet-id "$PUB_B"

export RT_PRIV=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=analytics-rt-priv}]' \
  --query RouteTable.RouteTableId --output text)

aws ec2 create-route --route-table-id "$RT_PRIV" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID"
aws ec2 associate-route-table --route-table-id "$RT_PRIV" --subnet-id "$PRIV_A"
aws ec2 associate-route-table --route-table-id "$RT_PRIV" --subnet-id "$PRIV_B"
```

NAT Gateway는 Private EC2의 패키지 설치, Kinesis API, SSM 통신에 사용합니다. NAT를 사용하지 않으려면 SSM, ssmmessages, ec2messages, Kinesis 등의 Interface Endpoint가 별도로 필요합니다.

## 2.12 Security Group

```bash
export ALB_SG=$(aws ec2 create-security-group \
  --group-name wsc2026-analytics-alb-sg \
  --description "Public ALB" --vpc-id "$VPC_ID" \
  --query GroupId --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0

export APP_SG=$(aws ec2 create-security-group \
  --group-name wsc2026-analytics-app-sg \
  --description "App from ALB only" --vpc-id "$VPC_ID" \
  --query GroupId --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$APP_SG" --protocol tcp --port 5000 \
  --source-group "$ALB_SG"
```

EC2에 SSH 22를 Public으로 열 필요가 없습니다. Session Manager로 접속합니다. App SG의 5000 Source를 0.0.0.0/0로 지정하지 말고 ALB SG로 제한합니다.

## 2.13 Kinesis와 EC2 IAM Role

### Kinesis Stream

```bash
aws kinesis create-stream \
  --stream-name wsc2026-order-stream \
  --stream-mode-details StreamMode=ON_DEMAND

aws kinesis wait stream-exists --stream-name wsc2026-order-stream
```

### EC2 Role과 Instance Profile

trust-ec2.json:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
```

```bash
aws iam create-role \
  --role-name wsc2026-alaytics-ec2-role \
  --assume-role-policy-document file://trust-ec2.json

aws iam attach-role-policy \
  --role-name wsc2026-alaytics-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

ec2-kinesis-policy.json:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["kinesis:PutRecord", "kinesis:PutRecords"],
    "Resource": "arn:aws:kinesis:ap-northeast-2:<ACCOUNT_ID>:stream/wsc2026-order-stream"
  }]
}
```

```bash
sed -i "s/<ACCOUNT_ID>/${ACCOUNT_ID}/g" ec2-kinesis-policy.json

aws iam put-role-policy \
  --role-name wsc2026-alaytics-ec2-role \
  --policy-name wsc2026-kinesis-write \
  --policy-document file://ec2-kinesis-policy.json

aws iam create-instance-profile \
  --instance-profile-name wsc2026-alaytics-ec2-role

aws iam add-role-to-instance-profile \
  --instance-profile-name wsc2026-alaytics-ec2-role \
  --role-name wsc2026-alaytics-ec2-role
```

AmazonSSMManagedInstanceCore가 없으면 채점 스크립트의 SSM Run Command가 실패하여 app 서비스 점수를 받지 못합니다.

## 2.14 Private EC2 생성

Amazon Linux 2023 최신 x86_64 AMI를 조회합니다.

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)

export EC2_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.small \
  --subnet-id "$PRIV_A" \
  --security-group-ids "$APP_SG" \
  --iam-instance-profile Name=wsc2026-alaytics-ec2-role \
  --no-associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=wsc2026-analytics-ec2}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids "$EC2_ID"

aws ec2 describe-instances --instance-ids "$EC2_ID" \
  --query 'Reservations[0].Instances[0].[InstanceId,InstanceType,SubnetId,PublicIpAddress,IamInstanceProfile.Arn]' \
  --output table
```

PublicIpAddress는 None이어야 합니다. Instance Profile 전파가 늦으면 run-instances 전에 10초 정도 기다립니다.

SSM Online 확인:

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$EC2_ID" \
  --query 'InstanceInformationList[0].[InstanceId,PingStatus,AgentVersion]' \
  --output table
```

## 2.15 제공 앱 전체 코드와 배포

지급 app.py의 전체 내용입니다.

```python
import json
import os
import random
import uuid
from datetime import datetime, timezone

import boto3
from flask import Flask, jsonify

app = Flask(__name__)

STREAM_NAME = os.environ.get("STREAM_NAME")
REGION = os.environ.get("AWS_REGION")

if not STREAM_NAME or not REGION:
    raise RuntimeError("STREAM_NAME and AWS_REGION environment variables are required")

kinesis = boto3.client("kinesis", region_name=REGION)

PRODUCTS = [
    {"name": "Laptop", "price": 1200000},
    {"name": "Mouse", "price": 25000},
    {"name": "Keyboard", "price": 55000},
    {"name": "Monitor", "price": 350000},
    {"name": "Headset", "price": 89000},
]


def generate_order():
    product = random.choice(PRODUCTS)
    return {
        "order_id": str(uuid.uuid4()),
        "product_name": product["name"],
        "price": product["price"],
        "quantity": random.randint(1, 5),
        "event_time": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S"),
    }


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "healthy"})


@app.route("/order", methods=["POST"])
def create_order():
    order = generate_order()
    kinesis.put_record(
        StreamName=STREAM_NAME,
        Data=json.dumps(order),
        PartitionKey=order["order_id"],
    )
    return jsonify(order), 201


@app.route("/orders/generate", methods=["POST"])
def generate_orders():
    count = 10
    orders = []
    for _ in range(count):
        order = generate_order()
        kinesis.put_record(
            StreamName=STREAM_NAME,
            Data=json.dumps(order),
            PartitionKey=order["order_id"],
        )
        orders.append(order)
    return jsonify({"generated": count, "orders": orders}), 201


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
```

Session Manager에서 다음을 실행합니다.

```bash
sudo dnf install -y python3 python3-pip unzip
sudo mkdir -p /opt/app
cd /tmp

curl -L -o module2.zip \
  https://rani0380.github.io/2026_nationalskills/downloads/task02-modules/module2.zip
unzip -o module2.zip

sudo cp module2/app.py module2/requirements.txt /opt/app/
sudo chown -R ec2-user:ec2-user /opt/app

cd /opt/app
python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install -r requirements.txt
```

서비스 파일 /etc/systemd/system/app.service:

```ini
[Unit]
Description=WSC2026 Analytics App
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/app
Environment=STREAM_NAME=wsc2026-order-stream
Environment=AWS_REGION=ap-northeast-2
ExecStart=/opt/app/venv/bin/gunicorn --workers 2 --bind 0.0.0.0:5000 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now app

systemctl is-active app
systemctl is-enabled app
curl -s http://127.0.0.1:5000/health
sudo journalctl -u app -n 50 --no-pager
```

기대값은 active, enabled, {"status":"healthy"}입니다.

## 2.16 Target Group과 ALB

```bash
export TG_ARN=$(aws elbv2 create-target-group \
  --name wsc2026-analytics-tg \
  --protocol HTTP --port 5000 \
  --target-type instance \
  --vpc-id "$VPC_ID" \
  --health-check-protocol HTTP \
  --health-check-path /health \
  --matcher HttpCode=200 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets Id="$EC2_ID",Port=5000

export ALB_ARN=$(aws elbv2 create-load-balancer \
  --name wsc2026-analytics-alb \
  --type application --scheme internet-facing \
  --subnets "$PUB_A" "$PUB_B" \
  --security-groups "$ALB_SG" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"

aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN"

export ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names wsc2026-analytics-alb \
  --query 'LoadBalancers[0].DNSName' --output text)
```

Target 상태:

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
  --output table
```

healthy가 아니면 app.service, 5000 Listener, /health, App SG Source를 순서대로 확인합니다.

## 2.17 ALB와 Kinesis Record 검증

```bash
curl -i "http://${ALB_DNS}/health"
curl -i -X POST "http://${ALB_DNS}/order"
curl -i -X POST "http://${ALB_DNS}/orders/generate"
```

/health는 200, /order와 /orders/generate는 201이어야 합니다.

Kinesis에 실제 Record가 들어갔는지 확인합니다.

```bash
export SHARD_ID=$(aws kinesis list-shards \
  --stream-name wsc2026-order-stream \
  --query 'Shards[0].ShardId' --output text)

export ITERATOR=$(aws kinesis get-shard-iterator \
  --stream-name wsc2026-order-stream \
  --shard-id "$SHARD_ID" \
  --shard-iterator-type TRIM_HORIZON \
  --query ShardIterator --output text)

aws kinesis get-records \
  --shard-iterator "$ITERATOR" --limit 10 \
  --query 'Records[*].Data' --output text
```

Data는 Base64입니다. 주문 응답 JSON에 order_id, product_name, price, quantity, event_time이 있으면 앱 형식은 정상입니다.

## 2.18 Flink Studio IAM과 생성

### Glue Database와 Role

```bash
aws glue create-database \
  --database-input '{"Name":"wsc2026_analytics"}'
```

trust-flink.json:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "kinesisanalytics.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
```

```bash
aws iam create-role \
  --role-name wsc2026-analytics-flink-role \
  --assume-role-policy-document file://trust-flink.json
```

flink-policy.json:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kinesis:DescribeStreamSummary",
        "kinesis:ListShards",
        "kinesis:GetShardIterator",
        "kinesis:GetRecords"
      ],
      "Resource": "arn:aws:kinesis:ap-northeast-2:<ACCOUNT_ID>:stream/wsc2026-order-stream"
    },
    {
      "Effect": "Allow",
      "Action": [
        "glue:GetDatabase", "glue:GetDatabases",
        "glue:GetTable", "glue:GetTables",
        "glue:CreateTable", "glue:UpdateTable", "glue:DeleteTable"
      ],
      "Resource": "*"
    }
  ]
}
```

```bash
sed -i "s/<ACCOUNT_ID>/${ACCOUNT_ID}/g" flink-policy.json
aws iam put-role-policy \
  --role-name wsc2026-analytics-flink-role \
  --policy-name wsc2026-flink-inline \
  --policy-document file://flink-policy.json

export FLINK_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/wsc2026-analytics-flink-role"
```

### Studio Notebook 생성

Console에서는 Managed Service for Apache Flink -> Studio -> Create Studio notebook에서 다음을 선택합니다.

| 항목 | 설정 |
|---|---|
| Name | wsc2026-analytics-flink |
| Runtime | ZEPPELIN-FLINK-3_0 |
| Application mode | INTERACTIVE |
| Glue database | wsc2026_analytics |
| Service role | wsc2026-analytics-flink-role |

CLI 최소 구성:

```bash
aws kinesisanalyticsv2 create-application \
  --application-name wsc2026-analytics-flink \
  --runtime-environment ZEPPELIN-FLINK-3_0 \
  --application-mode INTERACTIVE \
  --service-execution-role "$FLINK_ROLE_ARN" \
  --application-configuration \
  "ZeppelinApplicationConfiguration={MonitoringConfiguration={LogLevel=INFO},CatalogConfiguration={GlueDataCatalogConfiguration={DatabaseARN=arn:aws:glue:ap-northeast-2:${ACCOUNT_ID}:database/wsc2026_analytics}}}"

aws kinesisanalyticsv2 start-application \
  --application-name wsc2026-analytics-flink
```

Status 확인:

```bash
aws kinesisanalyticsv2 describe-application \
  --application-name wsc2026-analytics-flink \
  --query 'ApplicationDetail.[ApplicationName,ApplicationStatus,RuntimeEnvironment,ApplicationMode]' \
  --output table
```

채점 시 ApplicationName, 상태, RuntimeEnvironment가 출력되어야 합니다.

## 2.19 Flink Studio SQL

Notebook에서 먼저 Kinesis Source Table을 만듭니다.

```sql
%flink.ssql

CREATE TABLE order_stream (
  order_id STRING,
  product_name STRING,
  price BIGINT,
  quantity INT,
  event_time STRING,
  event_ts AS TO_TIMESTAMP(event_time),
  WATERMARK FOR event_ts AS event_ts - INTERVAL '5' SECOND
) WITH (
  'connector' = 'kinesis',
  'stream' = 'wsc2026-order-stream',
  'aws.region' = 'ap-northeast-2',
  'scan.stream.initpos' = 'LATEST',
  'format' = 'json'
);
```

Table 생성 후 ALB에 주문을 다시 넣어야 LATEST 이후 Record가 보입니다.

```bash
for i in $(seq 1 5); do
  curl -s -X POST "http://${ALB_DNS}/orders/generate" >/dev/null
done
```

최근 1분 주문 수:

```sql
%flink.ssql

SELECT COUNT(*) AS order_count
FROM order_stream
WHERE event_ts > CURRENT_TIMESTAMP - INTERVAL '1' MINUTE;
```

상품별 누적 매출:

```sql
%flink.ssql

SELECT
  product_name,
  SUM(price * quantity) AS total_revenue
FROM order_stream
GROUP BY product_name;
```

No data이면 Notebook Role의 Kinesis 읽기 권한, Stream 이름/Region, Source Table 생성 이후 주문 발생 여부를 확인합니다.

## 2.20 채점 스크립트와 동일한 최종 검증

```bash
export ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names wsc2026-analytics-alb \
  --query 'LoadBalancers[0].DNSName' --output text)

export EC2_ID=$(aws ec2 describe-instances \
  --filters 'Name=tag:Name,Values=wsc2026-analytics-ec2' \
            'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

aws ec2 describe-subnets \
  --subnet-ids $(aws ec2 describe-instances --instance-ids "$EC2_ID" \
    --query 'Reservations[0].Instances[0].SubnetId' --output text) \
  --query "Subnets[0].Tags[?Key=='Name'].Value|[0]" --output text

curl -s "http://${ALB_DNS}/health"
curl -s -X POST "http://${ALB_DNS}/order"

aws kinesis describe-stream-summary \
  --stream-name wsc2026-order-stream \
  --query 'StreamDescriptionSummary.[StreamName,StreamStatus,StreamModeDetails.StreamMode]' \
  --output text

aws kinesisanalyticsv2 describe-application \
  --application-name wsc2026-analytics-flink \
  --query 'ApplicationDetail.[ApplicationName,ApplicationStatus,RuntimeEnvironment]' \
  --output text

CMD_ID=$(aws ssm send-command \
  --instance-ids "$EC2_ID" \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["systemctl is-active app && systemctl is-enabled app"]}' \
  --query Command.CommandId --output text)

sleep 3
aws ssm get-command-invocation \
  --command-id "$CMD_ID" --instance-id "$EC2_ID" \
  --query StandardOutputContent --output text
```

기대 출력:

- Subnet Name: analytics-priv-a 또는 analytics-priv-b
- Listener: 80 HTTP
- Target Group: wsc2026-analytics-tg / 5000
- Kinesis: wsc2026-order-stream ACTIVE ON_DEMAND
- Flink: wsc2026-analytics-flink과 Runtime 출력
- /health: {"status":"healthy"}
- systemd: active, enabled

## 2.21 장애 진단표

| 증상 | 확인 및 해결 |
|---|---|
| SSM Managed Node가 안 보임 | Instance Profile, AmazonSSMManagedInstanceCore, NAT/443 확인 |
| pip/curl 실패 | Private Route가 NAT를 향하는지 확인 |
| app.service failed | journalctl -u app, 환경변수, requirements 설치 확인 |
| /health 직접은 성공, Target unhealthy | App SG 5000 Source가 ALB SG인지 확인 |
| ALB 502/503 | Target 등록, Port 5000, /health 200 확인 |
| /order 500 | EC2 Role의 kinesis:PutRecord와 Stream Region 확인 |
| Kinesis 데이터 없음 | 앱 로그에서 AccessDenied, STREAM_NAME 확인 |
| Flink No data | Role 읽기 권한, LATEST 이후 새 주문 생성 |
| Flink 생성 실패 | Glue Database ARN과 Trust Principal 확인 |
| 채점 SSM 실패 | app active여도 SSM Role/Network가 없으면 실패 |
| EC2 점수 실패 | Name 태그와 Private Subnet Name 확인 |
| TG 점수 실패 | 이름 wsc2026-analytics-tg와 Port 5000 확인 |

## 2.22 제출 직전 체크리스트

- Region은 ap-northeast-2이다.
- EC2 이름은 wsc2026-analytics-ec2이며 t3.small이다.
- EC2는 analytics-priv-a 또는 b에 있고 Public IP가 없다.
- Role 이름은 오타를 포함한 wsc2026-alaytics-ec2-role이다.
- SSM에서 EC2가 Online이다.
- app.service는 active와 enabled다.
- ALB는 Public Subnet 2개, Listener HTTP 80이다.
- Target Group 이름과 Port는 wsc2026-analytics-tg / 5000이다.
- Target 상태는 healthy다.
- /health는 200, /order는 201이다.
- Kinesis는 ACTIVE / ON_DEMAND다.
- Flink 이름은 wsc2026-analytics-flink이며 조회 가능하다.
- Notebook SQL에서 주문 데이터가 보인다.
- 테스트용 반복 요청을 중지했다.
