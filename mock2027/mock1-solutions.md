# 2027 지방대회 대비 모의고사 1회 · 문제 해설집

제1과제와 제2과제의 구축 순서, 핵심 설정, 예시 코드와 검증 방법을 정리했습니다. 문제의 이름·리전·배점이 기준이며 아래 코드는 필요한 부분을 치환해 적용하는 구현 예입니다. AWS 실계정 배포 검증은 수행하지 않았습니다.

## 제1과제 · 전체 흐름

사용자 → cafe-alb → cafe-order-svc의 Private Fargate Task → cafe-db:3307 순서입니다. ALB와 NAT는 Public, Task는 App, Aurora는 인터넷 경로 없는 DB 서브넷에 둡니다.

### 1. 네트워크부터 구축

1. cafe-vpc(10.10.0.0/16)에 DNS resolution과 DNS hostnames를 켭니다.
2. 문제의 여섯 서브넷을 A·C존에 만듭니다. Public은 cafe-pub-rt의 IGW 기본 경로를 공유합니다.
3. cafe-nat-a/c를 각각 같은 AZ Public 서브넷에 만들고 EIP를 연결합니다. cafe-app-rt-a/c는 같은 AZ NAT로 0.0.0.0/0을 보냅니다.
4. cafe-db-rt는 local 경로만 유지합니다. DB가 외부로 나가도록 NAT 경로를 추가하지 않습니다.
5. Secrets Manager Interface endpoint에 Private DNS를 켜고 endpoint SG의 443을 App SG에서 허용합니다. S3 Gateway endpoint는 App 라우팅 테이블에 연결합니다.
6. VPC Flow Logs용 IAM 역할에 CloudWatch Logs 전송 권한을 주고 /cafe/vpc/flowlog로 전송합니다.

| 보안 그룹 | 필요한 인바운드 |
| --- | --- |
| ALB | 사용자 HTTP 80 |
| cafe-app-sg | ALB SG에서 TCP 8080 |
| DB | App SG에서 TCP 3307, 초기 SQL 작업용 Bastion SG에서 TCP 3307 |
| Bastion | 실습자 공인 IP에서 TCP 2222 |
| Secrets endpoint | App SG에서 TCP 443 |

Bastion의 sshd 설정에 Port 2222를 적용하고 설정 검사 후 재시작합니다. 새 연결 성공을 확인한 뒤 기존 세션을 닫습니다. EIP와 종료 방지도 켭니다. 채점용 AdministratorAccess 인스턴스 프로파일을 연결합니다.

### 2. DB·계정·Secret

Aurora MySQL 8.0 호환 cafe-db를 DB subnet group으로 생성합니다. 포트 3307, CMK alias/cafe-db-key, 백업 7일, 삭제 방지, error·slowquery 로그 내보내기를 설정합니다. Writer와 Reader는 서로 다른 AZ에 두고 각각 db.t3.medium을 지정합니다.

Bastion의 mysql 클라이언트로 Writer endpoint:3307에 접속해 문제의 cafe.orders 테이블을 생성하고 별도 앱 계정을 만듭니다. 비밀번호는 실제 실습용 값으로 바꾸며 셸 이력·제출물에 남기지 않습니다.

```sql
CREATE DATABASE IF NOT EXISTS cafe;
CREATE TABLE IF NOT EXISTS cafe.orders (
  order_id INT AUTO_INCREMENT PRIMARY KEY,
  menu VARCHAR(50) NOT NULL,
  qty INT NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE USER 'cafeapp'@'%' IDENTIFIED BY '<앱비밀번호>';
GRANT SELECT, INSERT ON cafe.* TO 'cafeapp'@'%';
```

cafe/db-secret에 username=cafeapp, password, host=Writer endpoint, port=3307, dbname=cafe를 JSON으로 저장합니다. CMK는 alias/cafe-secret-key입니다. Reader endpoint를 쓰면 INSERT가 실패합니다.

### 3. 이미지·Task Definition

문제 부록의 app.py와 requirements.txt는 그대로 사용합니다.

```dockerfile
FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
EXPOSE 8080
CMD ["python","app.py"]
```

ECR cafe-order 생성 시 KMS 암호화, IMMUTABLE, scanOnPush를 설정합니다. ECR 로그인 후 이미지 URI에 v1.0.0 태그를 붙여 push합니다. 불변 태그이므로 같은 태그 재업로드를 전제로 작업하지 않습니다.

Task family cafe-order-td는 FARGATE/awsvpc, CPU 512, memory 1024로 등록합니다. 로그 그룹 /cafe/ecs/order를 미리 만들고 retention 14일을 설정합니다.

- Execution Role: ECR pull·로그 전송, 해당 Secret의 GetSecretValue와 Secret CMK의 kms:Decrypt.
- Task Role: ECS Exec용 ssmmessages 채널 생성·열기 권한.
- 컨테이너 포트: 8080. awslogs region은 ap-northeast-2.
- 환경 변수 DB_HOST·DB_PORT·DB_USER·DB_PASSWORD·DB_NAME은 Secret JSON key를 secrets 항목으로 매핑합니다.

Secret 주입 형식 예시입니다. 실제 ARN 전체와 key를 사용합니다.

```json
{"name":"DB_PASSWORD","valueFrom":"<Secret ARN>:password::"}
```

### 4. ALB·서비스·관측

cafe-order-tg는 ip 유형, 포트 8080, health /health로 만듭니다. cafe-alb는 두 Public 서브넷에 internet-facing으로 만들고 HTTP 80 기본 동작은 fixed-response 404, text/plain, not found로 둡니다. 별도 규칙의 path-pattern에 /v1/*와 /health를 넣어 TG로 전달합니다.

cafe-cluster의 Container Insights를 켭니다. 서비스 cafe-order-svc는 두 App 서브넷, Public IP 비활성, Desired 2, ECS Exec 활성입니다. Auto Scaling의 리소스 ID는 service/cafe-cluster/cafe-order-svc이며 Min 2, Max 6, ECSServiceAverageCPUUtilization 목표 60입니다.

cafe-dashboard에 ALB RequestCount, HTTPCode_Target_5XX_Count, ECS 서비스 CPUUtilization을 추가합니다. cafe-5xx-alarm은 5분 Sum 10 이상, SNS cafe-alert 연결입니다. ALB 지표 dimension은 ARN 전체가 아니라 app/이름/ID 형식의 LoadBalancer 값입니다.

### 5. 최종 검증과 오류 해석

```bash
BASE="http://<ALB-DNS>"
curl -i "$BASE/health"
curl -sS -H 'Content-Type: application/json' -d '{"menu":"latte","qty":2}' "$BASE/v1/orders"
# 앞 응답에서 실제 order_id를 확인해 치환
curl -i "$BASE/v1/orders?order_id=<생성된ID>"
curl -i "$BASE/unknown"
```

/health 500은 DB 연결 실패입니다. DB SG의 3307, Secret key 매핑, 계정 비밀번호, cafe DB 생성 여부를 순서대로 확인합니다. 이미지 pull 실패는 NAT·Execution Role·ECR URI를 확인합니다. ALB 503은 정상 타깃이 없는 경우가 많으므로 /health와 SG를 먼저 봅니다. 비정상 경로는 ALB가 직접 404 not found를 반환해야 합니다.

## 제2과제 · 1. Static website with CDN

1. 서울에 cafe-web-<비번호>를 생성하고 퍼블릭 액세스 차단 네 항목을 모두 켭니다. index.html과 error.html의 본문을 문제대로 업로드합니다.
2. CloudFront Origin은 S3 REST endpoint를 선택하고 OAC를 생성해 요청 서명을 켭니다. S3 website endpoint는 OAC 대상이 아닙니다.
3. 버킷 정책에서 cloudfront.amazonaws.com의 s3:GetObject를 해당 배포 SourceArn 조건으로만 허용합니다.
4. Default root index.html, viewer protocol redirect-to-https, PriceClass_All을 설정합니다.
5. Custom error response를 403과 404 각각 등록합니다. Response page /error.html, response code 404입니다.
6. WAF는 CLOUDFRONT scope로 만들며 API·콘솔 관리 리전은 us-east-1입니다. cafe-web-acl에 AWSManagedRulesCommonRuleSet과 cafe-rate-limit을 추가합니다. Rate rule은 IP, Limit 100, 평가 기간 300초, Block입니다.
7. 배포에 Web ACL을 연결하고 배포 완료를 기다립니다.

버킷 정책 Allow 문 예시입니다.

```json
{"Effect":"Allow","Principal":{"Service":"cloudfront.amazonaws.com"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::cafe-web-<비번호>/*","Condition":{"StringEquals":{"AWS:SourceArn":"arn:aws:cloudfront::<계정ID>:distribution/<배포ID>"}}}
```

CloudFront의 /는 정상 메뉴, HTTP는 HTTPS 리다이렉트, 없는 경로는 404와 Oops 본문이어야 합니다. S3 객체 직접 URL은 403이어야 합니다.

## 제2과제 · 2. Serverless workflow

cafe-order-status는 PK order_id(String), On-demand입니다. Python 3.12 Lambda cafe-make-coffee는 입력 order_id를 유지하고 DONE을 반환합니다.

```python
def lambda_handler(event, context):
    return {"order_id": event["order_id"], "status": "DONE"}
```

Standard 상태 머신 cafe-order-flow의 ASL 예시입니다. Lambda ARN의 계정ID를 치환합니다. 두 경로 모두 DynamoDB 서비스 통합을 통과하고 최종 output은 order_id와 status 두 값입니다.

```json
{
  "StartAt":"CheckQty",
  "States":{
    "CheckQty":{"Type":"Choice","Choices":[{"Variable":"$.qty","NumericGreaterThan":10,"Next":"Reject"}],"Default":"Make"},
    "Make":{"Type":"Task","Resource":"arn:aws:states:::lambda:invoke","Parameters":{"FunctionName":"arn:aws:lambda:ap-northeast-2:<계정ID>:function:cafe-make-coffee","Payload.$":"$"},"OutputPath":"$.Payload","Next":"Save"},
    "Reject":{"Type":"Pass","Parameters":{"order_id.$":"$.order_id","status":"REJECTED"},"Next":"Save"},
    "Save":{"Type":"Task","Resource":"arn:aws:states:::dynamodb:putItem","Parameters":{"TableName":"cafe-order-status","Item":{"order_id":{"S.$":"$.order_id"},"status":{"S.$":"$.status"}}},"ResultPath":null,"End":true}
  }
}
```

실행 역할에는 Lambda InvokeFunction, 테이블 PutItem, Step Functions 로그 전달 권한을 줍니다. /aws/vendedlogs/states/cafe-order-flow에 로그 ALL을 설정합니다. o-1/qty=2와 o-2/qty=30을 실행하고 output과 두 DynamoDB 항목을 모두 확인합니다.

## 제2과제 · 3. Event-driven automation

도쿄에서 dev-web-1/2는 Env=dev, prod-web-1은 Env=prod로 생성합니다. stop-dev-instances는 running과 Env=dev를 함께 필터링하며 페이지네이션을 처리합니다.

```python
import boto3
ec2 = boto3.client("ec2", region_name="ap-northeast-1")
def lambda_handler(event, context):
    ids = []
    pages = ec2.get_paginator("describe_instances").paginate(Filters=[
        {"Name":"tag:Env","Values":["dev"]},
        {"Name":"instance-state-name","Values":["running"]}
    ])
    for page in pages:
        for reservation in page["Reservations"]:
            ids.extend(i["InstanceId"] for i in reservation["Instances"])
    if ids:
        ec2.stop_instances(InstanceIds=ids)
    return ids
```

DescribeInstances는 Resource *, StopInstances는 도쿄 본인 계정 instance ARN에 ec2:ResourceTag/Env=dev 조건을 설정합니다. 로그 권한 외 다른 서비스 관리 권한을 붙이지 않습니다.

Scheduler stop-dev-schedule은 cron(0 22 * * ? *), timezone Asia/Seoul, Flexible window OFF로 설정합니다. Scheduler 실행 역할은 scheduler.amazonaws.com 신뢰와 함수 InvokeFunction을 갖습니다.

ec2-stopped-rule 패턴은 아래와 같습니다. SNS 대상 ec2-state-topic에는 EventBridge의 sns:Publish를 허용하는 topic policy가 필요합니다.

```json
{"source":["aws.ec2"],"detail-type":["EC2 Instance State-change Notification"],"detail":{"state":["stopped"]}}
```

채점 전에 세 대 모두 running으로 맞춥니다. 채점은 dev 인스턴스를 실제 중지하므로 재채점 전에 두 dev를 다시 시작합니다. prod는 running을 유지해야 합니다.

## 제2과제 · 4. Conditional IAM policy

cafe-share-<비번호>에 비 TLS 요청을 명시적으로 Deny합니다. 정책 Resource에는 버킷 ARN과 객체 ARN을 모두 넣습니다. intern-role의 신뢰 Principal은 본인 계정 root ARN으로 지정해 계정의 user/role에 위임하며 호출 주체에도 sts:AssumeRole 권한이 필요합니다.

intern-policy를 하나만 연결하고 다음 세 문장을 분리합니다.

```json
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::cafe-share-<비번호>/intern/*"},
 {"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::cafe-share-<비번호>/intern/*","Condition":{"StringEquals":{"s3:x-amz-server-side-encryption":"aws:kms"}}},
 {"Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::cafe-share-<비번호>","Condition":{"StringLike":{"s3:prefix":"intern/*"}}}
]}
```

SSE-KMS 쓰기에는 해당 키의 kms:GenerateDataKey, 읽기에는 kms:Decrypt가 필요할 수 있습니다. 실제 사용하는 키 ARN으로 같은 intern-policy 안에 필요한 권한을 추가하고 키 정책도 확인합니다. 버킷 기본 암호화만 켜는 것으로 요청 헤더 조건을 대신할 수 없습니다.\n\nAssumeRole 임시 세션에서 문제의 네 요청을 실행해 순서대로 성공·거부·거부·거부인지 확인합니다. 관리자 세션에서 테스트하면 역할의 제한을 검증할 수 없습니다.\n\n## 채점과 정리\n\n제1과제는 cafe-bastion, 제2과제는 서울 CloudShell에서 문제 페이지의 채점 스크립트를 실행합니다. 결과 저장 후 ECS·ALB·Aurora, CloudFront·WAF, 워크플로우·Lambda·EC2와 NAT·EIP 등 본인 실습 자원을 정리합니다. Aurora 삭제 방지와 Bastion 종료 방지는 정리 시 해제하고 Secret·KMS 키의 의존 관계를 확인합니다.
