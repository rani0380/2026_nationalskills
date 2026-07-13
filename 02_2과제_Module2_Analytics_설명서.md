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
