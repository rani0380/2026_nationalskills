# 07_1과제 Release Candidate 상세 풀이

대상: Unicorn Tickets Solution Architecture / 제1과제 / 4시간

첨부 과제지, 30점 채점기준, 저장소의 mark.sh를 대조해 실제 채점 순서로 정리한 풀이입니다. 이름·경로·출력 조건은 채점 명령을 우선합니다.

## 배점과 권장 순서

| 영역 | 배점 | 핵심 |
|---|---:|---|
| Networking | 3.0 | 3개 AZ, Route, Endpoint, Flow Log |
| KMS / S3 / DB / ECR | 4.5 | 암호화, Rotation, PITR, Scan |
| EKS / Lambda | 5.5 | Private EKS, Node 분리, Pod Identity |
| Service Endpoint | 7.0 | Internal ALB, VPC Origin, WAF |
| Security / Application | 3.5 | External ID, health, env, graceful |
| Observability / Runtime / Grafana | 6.5 | JSON 로그, Rate test, 5개 패널 |
| 합계 | 30.0 | |

구축 순서: Network → KMS → S3/DynamoDB/ECR → EKS → App/Pod Identity → Lambda → ALB → CloudFront → WAF → Logging/Monitoring → Runtime test.

## 1. 공통 변수

```bash
export AWS_REGION=ap-northeast-2
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export NUMBER=<선수등번호>
export BUCKET=unicorn-web-$ACCOUNT_ID
aws configure set region $AWS_REGION
```

채점은 Private Subnet의 CloudShell VPC Environment unicorn-mark에서 진행됩니다. 여기서 source kubectl-connect unicorn-eks-cluster가 성공해야 합니다.

## 2. Networking - 3점

VPC는 unicorn-vpc, CIDR은 10.97.0.0/16입니다.

| Subnet | AZ | CIDR |
|---|---|---|
| unicorn-subnet-pub-a | 2a | 10.97.0.0/24 |
| unicorn-subnet-pub-b | 2b | 10.97.1.0/24 |
| unicorn-subnet-pub-c | 2c | 10.97.2.0/24 |
| unicorn-subnet-priv-a | 2a | 10.97.10.0/24 |
| unicorn-subnet-priv-b | 2b | 10.97.11.0/24 |
| unicorn-subnet-priv-c | 2c | 10.97.12.0/24 |

Public 세 개는 unicorn-rt-pub에 연결하고 0.0.0.0/0을 unicorn-igw로 보냅니다. Private은 unicorn-rt-priv-a/b/c로 분리해 같은 AZ의 unicorn-nat-a/b/c로 보냅니다. Public Association은 3, 각 Private은 1이어야 합니다.

반드시 포함할 VPC Endpoint:

- com.amazonaws.ap-northeast-2.s3
- com.amazonaws.ap-northeast-2.ecr.api
- com.amazonaws.ap-northeast-2.ecr.dkr

Private DNS와 Endpoint SG의 HTTPS 허용을 확인하고 VPC Flow Log를 1개 이상 활성화합니다.

## 3. KMS - 1점

| Alias | 사용처 |
|---|---|
| alias/unicorn-kms-app | Secrets Manager, DynamoDB |
| alias/unicorn-kms-data | S3, ECR |
| alias/unicorn-kms-platform | EKS, EBS, Logs |

세 키 모두 Rotation을 켜고 RotationPeriodInDays를 정확히 90으로 설정합니다. WAF 로그용 Platform Key는 us-east-1 다중 리전 요구도 확인합니다.

```bash
for a in app data platform; do
  aws kms get-key-rotation-status --key-id alias/unicorn-kms-$a     --query '[KeyRotationEnabled,RotationPeriodInDays]' --output text
done
```

세 줄 모두 True 90이어야 합니다.

## 4. S3 - 1점

버킷은 unicorn-web-$ACCOUNT_ID입니다.

- Block Public Access 4개 true
- Versioning Enabled
- Default encryption aws:kms, Data CMK
- 지급파일 index.html과 main.jpeg 업로드
- OAC만 허용
- Bucket Policy Principal은 cloudfront.amazonaws.com
- SourceArn은 현재 Distribution ARN

## 5. DynamoDB - 1.5점

| 항목 | 값 |
|---|---|
| Table | unicorn-concert-db |
| Billing | PAY_PER_REQUEST |
| PK | booking_id String |
| GSI | client-id-created-at-index |
| GSI PK / SK | client_id / created_at |
| Projection | ALL |
| Encryption | App CMK |
| PITR / 삭제 방지 | ENABLED / true |

## 6. ECR - 1점

Repository 이름은 unicorn-concert-app입니다. 채점은 단순히 이미지가 보이는지만 확인하지 않고 Repository 설정, 두 tag, v1.0.0 스캔 이력, 취약점 개수를 함께 검사합니다.

### 6.1 정답 설정표

| 항목 | 값 |
|---|---|
| Repository | unicorn-concert-app |
| Scan on push | true |
| Encryption | KMS |
| KMS key | alias/unicorn-kms-data |
| Tag mutability | IMMUTABLE_WITH_EXCLUSION |
| Mutable exclusion | WILDCARD / latest |
| 필수 tag | v1.0.0, latest |
| v1.0.0 scan | 완료 이력 존재 |
| 허용 취약점 | CRITICAL/HIGH/MEDIUM/LOW/INFORMATIONAL 모두 0 |

IMMUTABLE_WITH_EXCLUSION은 기본적으로 모든 tag 덮어쓰기를 막되 exclusion에 일치하는 latest만 다시 push할 수 있게 합니다. v1.0.0은 최초 한 번만 정확히 push하세요.

### 6.2 콘솔에서 Repository 생성

1. AWS Console에서 Elastic Container Registry → Private registry → Repositories → Create repository로 이동합니다.
2. Repository name에 unicorn-concert-app을 입력합니다.
3. Image tag mutability는 Immutable을 선택합니다.
4. Exclusion filter를 추가하고 Filter type은 Wildcard, Filter는 latest로 지정합니다.
5. Scan on push를 활성화합니다.
6. Encryption configuration은 KMS를 선택합니다.
7. KMS key는 alias/unicorn-kms-data를 선택합니다.
8. 생성 후 Repository 상세의 Mutability가 IMMUTABLE_WITH_EXCLUSION인지 다시 확인합니다.

콘솔에 exclusion UI가 보이지 않거나 설정 결과가 다르면 아래 CLI 방식이 더 확실합니다.

### 6.3 CLI로 Repository 생성

아직 Repository가 없을 때:

```bash
aws ecr create-repository   --repository-name unicorn-concert-app   --region ap-northeast-2   --image-scanning-configuration scanOnPush=true   --encryption-configuration encryptionType=KMS,kmsKey=alias/unicorn-kms-data   --image-tag-mutability IMMUTABLE_WITH_EXCLUSION   --image-tag-mutability-exclusion-filters     filterType=WILDCARD,filter=latest
```

이미 Repository를 만들었다면 tag 정책을 다음처럼 교정합니다.

```bash
aws ecr put-image-tag-mutability   --repository-name unicorn-concert-app   --image-tag-mutability IMMUTABLE_WITH_EXCLUSION   --image-tag-mutability-exclusion-filters     filterType=WILDCARD,filter=latest
```

Scan on push가 false라면 다음 명령으로 켭니다.

```bash
aws ecr put-image-scanning-configuration   --repository-name unicorn-concert-app   --image-scanning-configuration scanOnPush=true
```

KMS 암호화 방식과 KMS key는 Repository 생성 후 변경할 수 없으므로 잘못 만들었다면 이미지가 없는 초기 단계에서 Repository를 다시 만드는 것이 안전합니다.

### 6.4 취약점 0건용 Dockerfile

지급된 book은 x86-64 정적 링크 Go 바이너리이므로 OS 패키지가 없는 scratch image로 실행할 수 있습니다. 이 방식은 스캔 대상 OS 패키지를 포함하지 않아 취약점 0건 조건을 맞추기 가장 쉽습니다.

book 파일과 같은 폴더에 Dockerfile을 만듭니다.

```dockerfile
FROM scratch
COPY book /book
EXPOSE 8080
ENTRYPOINT ["/book"]
```

주의:

- 지급된 book 바이너리는 수정하지 않습니다.
- Docker build context에 book이 있어야 합니다.
- scratch에는 shell, curl, chmod가 없습니다. Dockerfile에서 RUN chmod를 사용할 수 없습니다.
- Windows에서 파일을 옮겨 실행 권한 문제가 생기면 Linux/CloudShell에서 chmod +x book을 먼저 수행합니다.
- Kubernetes probe는 exec가 아니라 HTTP GET /health를 사용합니다.

### 6.5 로그인, Build, Tag, Push

지급파일 폴더에서 실행합니다.

```bash
cd '<지급파일의 book과 Dockerfile이 있는 폴더>'

export AWS_REGION=ap-northeast-2
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_URI=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/unicorn-concert-app

aws ecr get-login-password --region $AWS_REGION   | docker login --username AWS --password-stdin     $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

docker build --platform linux/amd64 -t unicorn-concert-app:v1.0.0 .

docker tag unicorn-concert-app:v1.0.0 $ECR_URI:v1.0.0
docker tag unicorn-concert-app:v1.0.0 $ECR_URI:latest

docker push $ECR_URI:v1.0.0
docker push $ECR_URI:latest
```

반드시 v1.0.0을 최초 push할 때 올바른 image를 사용합니다. v1.0.0을 다시 push하면 ImageTagAlreadyExistsException이 발생하는 것이 정상입니다. latest는 exclusion 대상이므로 다시 push할 수 있습니다.

두 tag를 같은 build 결과에 붙였는지 확인합니다.

```bash
aws ecr describe-images   --repository-name unicorn-concert-app   --image-ids imageTag=v1.0.0 imageTag=latest   --query 'imageDetails[].[imageDigest,imageTags]'   --output table
```

두 tag의 digest가 같으면 가장 단순하고 안전합니다.

### 6.6 Scan 실행과 완료 대기

Scan on push가 켜져 있으면 v1.0.0 push 직후 자동 스캔됩니다. 먼저 상태를 확인합니다.

```bash
aws ecr describe-image-scan-findings   --repository-name unicorn-concert-app   --image-id imageTag=v1.0.0   --query '[imageScanStatus.status,imageScanStatus.description]'   --output text
```

아직 스캔 이력이 없을 때만 수동 스캔을 시작합니다.

```bash
aws ecr start-image-scan   --repository-name unicorn-concert-app   --image-id imageTag=v1.0.0
```

같은 이미지는 보통 24시간에 한 번만 수동 스캔할 수 있으므로 scan on push가 이미 실행됐다면 start-image-scan을 반복하지 않습니다. 상태가 IN_PROGRESS이면 잠시 기다렸다가 describe-image-scan-findings를 다시 실행합니다.

### 6.7 취약점 0건 판정

전체 결과:

```bash
aws ecr describe-image-scan-findings   --repository-name unicorn-concert-app   --image-id imageTag=v1.0.0
```

채점에 필요한 핵심 출력만 확인:

```bash
aws ecr describe-image-scan-findings   --repository-name unicorn-concert-app   --image-id imageTag=v1.0.0   --query '[imageScanStatus.status,imageScanFindings.findingSeverityCounts]'   --output json
```

정상 예시:

```json
[
  "COMPLETE",
  {}
]
```

COMPLETE와 빈 객체가 함께 나와야 합니다. findingSeverityCounts가 비어 있어도 status가 없거나 scan 결과 자체가 없으면 스캔 미실행으로 오답입니다. LOW: 1처럼 LOW 하나만 있어도 이 과제에서는 오답입니다.

### 6.8 mark.sh와 같은 최종 검증

```bash
aws ecr describe-repositories   --repository-names unicorn-concert-app   --query 'repositories[0].{Scan:imageScanningConfiguration.scanOnPush,Mutability:imageTagMutability,Enc:encryptionConfiguration.encryptionType}'   --output json

aws ecr describe-images   --repository-name unicorn-concert-app   --query 'sort(imageDetails[].imageTags[])'   --output json | jq -r '@tsv'

aws ecr describe-image-scan-findings   --repository-name unicorn-concert-app   --image-id imageTag=v1.0.0   --query 'imageScanFindings.findingSeverityCounts'   --output json
```

기대 결과:

- Scan: true
- Mutability: IMMUTABLE_WITH_EXCLUSION
- Enc: KMS
- tag 목록에 latest와 v1.0.0 존재
- findingSeverityCounts는 빈 객체
- 스캔 이력은 별도 status 조회에서 COMPLETE

### 6.9 자주 발생하는 오류

| 증상 | 원인 | 해결 |
|---|---|---|
| ImageTagAlreadyExistsException | v1.0.0 재 push | 새 Repository라면 최초 push만 수행; latest만 갱신 |
| latest도 덮어쓰기 실패 | exclusion filter 누락/오타 | WILDCARD, latest로 put-image-tag-mutability 실행 |
| scan 결과가 없음 | scan on push 전에 이미지를 올림 | v1.0.0 수동 scan 1회 실행 |
| scan status IN_PROGRESS | 스캔 진행 중 | 완료까지 대기 후 다시 조회 |
| LOW 이상 finding 존재 | OS package가 든 base image 사용 | 정적 book을 scratch image로 다시 build |
| KMS가 AES256으로 출력 | 기본 암호화로 생성 | KMS Repository로 다시 생성 |
| no basic auth credentials | ECR 로그인 만료/리전 오류 | get-login-password를 서울 리전으로 재실행 |
| exec format error | 다른 CPU architecture로 build | --platform linux/amd64로 다시 build |
| Pod에서 /bin/sh 오류 | scratch에는 shell 없음 | exec probe 대신 HTTP /health 사용 |
## 7. EKS - 4.5점

Cluster unicorn-eks-cluster, Kubernetes 1.35:

- endpointPublicAccess false
- endpointPrivateAccess true
- Private Subnet 3개
- api, audit, authenticator, controllerManager, scheduler 로그 활성화
- Secrets envelope encryption: Platform CMK
- Node EBS와 로그도 Platform CMK
- 모든 Node는 Public IP 없음, timezone KST

| NodeGroup | Label | EC2 Name tag | 수량 |
|---|---|---|---|
| App | unicorn=app | unicorn-k8snode-app-node | 2대 이상, 2개 이상 AZ |
| Addon | unicorn=addon | unicorn-k8snode-addon-node | 1대 이상 |

App과 DaemonSet을 제외한 Addon은 addon Node에, Book App은 app Node에만 배치합니다.

### Book App 필수 Manifest

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unicorn-book-app-deploy
  namespace: unicorn
spec:
  replicas: 2
  selector:
    matchLabels: {app: unicorn-book}
  template:
    metadata:
      labels: {app: unicorn-book}
    spec:
      serviceAccountName: unicorn-book-app-sa
      nodeSelector: {unicorn: app}
      terminationGracePeriodSeconds: 45
      containers:
        - name: book
          image: ACCOUNT_ID.dkr.ecr.ap-northeast-2.amazonaws.com/unicorn-concert-app:v1.0.0
          ports: [{containerPort: 8080}]
          env:
            - {name: AWS_REGION, value: ap-northeast-2}
            - {name: TABLE_NAME, value: unicorn-concert-db}
          livenessProbe:
            httpGet: {path: /health, port: 8080}
          readinessProbe:
            httpGet: {path: /health, port: 8080}
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 15"]
---
apiVersion: v1
kind: Service
metadata:
  name: unicorn-book-app-svc
  namespace: unicorn
spec:
  selector: {app: unicorn-book}
  ports: [{port: 80, targetPort: 8080}]
```

Ready/Available가 모두 2 이상이어야 합니다. Pod Identity Association은 unicorn-book-app-sa에 연결하고 DynamoDB 동작에 필요한 최소 권한만 부여합니다.

## 8. Lambda - 1점

- Function: unicorn-get-booking-func
- GET /v1/book, booking_id 필수
- email, concert_name 선택 조건
- TABLE_NAME=unicorn-concert-db
- KMSKeyArn: Platform CMK
- Log Group: /unicorn/lambda/get-booking
- ALB 형식 JSON 응답
- DynamoDB 최소 권한

### 8.1 함수 생성과 보안 설정

Lambda 콘솔에서 Author from scratch를 선택합니다.

| 항목 | 값 |
|---|---|
| Function name | unicorn-get-booking-func |
| Runtime | Python 3.x |
| Architecture | x86_64 |
| Environment variable | TABLE_NAME=unicorn-concert-db |
| Environment encryption | alias/unicorn-kms-platform |
| Log group | /unicorn/lambda/get-booking |

실행 역할에는 CloudWatch Logs 기록 권한과 unicorn-concert-db의 dynamodb:GetItem만 허용합니다. 별도 조회 방식을 추가하지 않는다면 Scan이나 전체 테이블 wildcard 권한은 필요하지 않습니다.

### 8.2 lambda_function.py 전체 코드

```python
import json
import os

import boto3


TABLE_NAME = os.environ["TABLE_NAME"]
table = boto3.resource("dynamodb").Table(TABLE_NAME)

STATUS_TEXT = {
    200: "OK",
    400: "Bad Request",
    404: "Not Found",
    405: "Method Not Allowed",
    500: "Internal Server Error",
}


def alb_response(status_code, payload):
    return {
        "statusCode": status_code,
        "statusDescription": f"{status_code} {STATUS_TEXT[status_code]}",
        "isBase64Encoded": False,
        "headers": {
            "Content-Type": "application/json; charset=utf-8"
        },
        "body": json.dumps(payload, ensure_ascii=False),
    }


def lambda_handler(event, context):
    method = event.get("httpMethod", "GET")
    params = event.get("queryStringParameters") or {}

    if method != "GET":
        return alb_response(405, {"message": "Method Not Allowed"})

    booking_id = params.get("booking_id")
    if not booking_id:
        return alb_response(400, {"message": "booking_id is required"})

    try:
        result = table.get_item(
            Key={"booking_id": booking_id},
            ConsistentRead=True,
        )
    except Exception:
        print("DynamoDB GetItem failed", flush=True)
        return alb_response(500, {"message": "internal server error"})

    item = result.get("Item")
    if item is None:
        return alb_response(404, {"message": "booking not found"})

    # 선택 파라미터가 오면 저장된 값과 함께 일치해야 합니다.
    for field in ("email", "concert_name"):
        expected = params.get(field)
        if expected is not None and item.get(field) != expected:
            return alb_response(404, {"message": "booking not found"})

    return alb_response(200, item)
```

boto3는 Lambda Python 런타임에 포함되므로 별도 Layer나 dependency zip이 필요하지 않습니다. Handler는 lambda_function.lambda_handler로 둡니다.

### 8.3 IAM 최소 권한

ACCOUNT_ID는 실제 계정 ID로 바꿉니다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadBooking",
      "Effect": "Allow",
      "Action": "dynamodb:GetItem",
      "Resource": "arn:aws:dynamodb:ap-northeast-2:ACCOUNT_ID:table/unicorn-concert-db"
    }
  ]
}
```

CloudWatch Logs는 AWSLambdaBasicExecutionRole을 사용하거나 /unicorn/lambda/get-booking에 한정한 logs:CreateLogStream, logs:PutLogEvents 권한을 직접 부여합니다. 환경변수 복호화를 위해 실행 역할에 Platform CMK의 kms:Decrypt도 필요합니다.

### 8.4 콘솔 테스트 이벤트

```json
{
  "httpMethod": "GET",
  "path": "/v1/book",
  "queryStringParameters": {
    "booking_id": "POST에서 받은 ID"
  }
}
```

정상 응답은 statusCode 200이고 body는 JSON 문자열이어야 합니다. booking_id가 없는 이벤트도 실행해 400을 확인합니다.

### 8.5 ALB Lambda Target Group 연결

1. Target type을 Lambda function으로 선택해 Lambda용 Target Group을 만듭니다.
2. unicorn-get-booking-func를 Target으로 등록합니다.
3. Lambda Resource-based policy에 elasticloadbalancing.amazonaws.com의 InvokeFunction을 허용합니다.
4. ALB Listener의 GET + /v1/book 규칙을 Lambda Target Group으로 전달합니다.
5. POST /v1/book과 GET /health는 기존 unicorn-tg로 전달합니다.

CloudFront에서 query string 전달이 꺼져 있으면 Lambda에 booking_id가 도착하지 않아 400이 발생합니다. /v1/book* behavior의 Origin request policy에서 모든 query string 또는 booking_id, email, concert_name을 전달하세요.
## 9. ALB와 CloudFront - 7점

### Internal ALB

- unicorn-alb / internal / application / active
- Listener HTTP 80
- App Target Group unicorn-tg
- POST /v1/book → EKS App
- GET /health → EKS App
- GET /v1/book → Lambda
- Default 403

Internal ALB 직접 curl은 000 또는 403이어야 합니다.

### CloudFront VPC Origin

Distribution Comment는 unicorn-svc-cf입니다.

| Origin ID | 연결 |
|---|---|
| s3-origin | S3 OAC |
| app-origin | unicorn-alb VPC Origin |

Default behavior는 S3, /v1/book*와 /health*는 app-origin으로 보냅니다. query string을 전달하고 정적 GET은 캐싱합니다. HTTP는 HTTPS로 redirect합니다.

## 10. WAF - 1점 + Runtime 1.5점

us-east-1에 unicorn-waf를 만듭니다.

- Default Allow
- AWSManagedRulesCommonRuleSet
- AWSManagedRulesKnownBadInputsRuleSet
- unicorn-rate-limit
- 60초 50건 초과 block
- Custom response 403
- Body: Request blocked by Unicorn WAF
- Log Group aws-waf-logs-unicorn
- Platform CMK 암호화

XSS 요청은 403, Rate test 후 /health는 403과 지정 body를 반환해야 합니다.

## 11. Audit Role - 2점

- Role: unicorn-audit-role
- External ID: unicorn-audit-2026$NUMBER
- Max session: 3600
- 동일 계정의 명시된 IAM Principal
- Inline Policy
- Action과 Resource wildcard 금지
- 허용: dynamodb:GetItem, dynamodb:Query, ec2:DescribeVpcs, eks:DescribeCluster

External ID 없이 AssumeRole은 AccessDenied, 올바른 값으로는 성공해야 합니다. Assume 후 DescribeVpcs는 성공하고 DescribeInstances는 UnauthorizedOperation이어야 합니다.

## 12. Observability - 2점

Fluent Bit DaemonSet이 Book App 로그를 10초 안에 /unicorn/eks/book-app으로 전송해야 합니다. /health 로그는 제외합니다.

정확한 JSON key:

```text
client_ip,method,path,status_code,timestamp
```

monitoring namespace에 Prometheus와 Grafana를 설치합니다. 관리형 Control Plane용 kube-controller-manager, kube-scheduler, kube-etcd ServiceMonitor 수는 0이어야 합니다.

Grafana:

- ALB/TG: unicorn-grafana-alb / unicorn-grafana-tg
- ID: skills$NUMBER
- Password: HelloKrSkills!$NUMBER@
- Dashboard: unicorn-grafana-dashboard

필수 패널:

1. EKS Node CPU Usage (%) - Time Series
2. EKS Node Memory Usage (%) - Time Series
3. unicorn Namespace Pod Status - Stat, graph 포함
4. Book App Ready Pods - Stat
5. Book App HTTP Request Duration - Time Series

No Data, 잘못된 Panel type, 다른 이름은 오답입니다.

## 13. 실제 채점 요청

```bash
CF=$(aws cloudfront list-distributions   --query "DistributionList.Items[?Comment=='unicorn-svc-cf'].DomainName | [0]"   --output text)

RESP=$(curl -s -X POST "https://$CF/v1/book"   -H 'Content-Type: application/json'   -d '{"client_id":"C-MARK","username":"Judge","email":"judge@skills.kr","concert_name":"UnicornMark2026"}')
echo "$RESP"
BID=$(echo "$RESP" | jq -r '.booking_id')

curl -s "https://$CF/v1/book?booking_id=$BID" | jq .
curl -s -o /dev/null -w "%{http_code}
" "https://$CF/health"
```

POST의 booking_id, DynamoDB item, GET 응답 booking_id가 같아야 합니다. created_at도 저장되어야 합니다.

## 14. 제출 직전 체크리스트

1. unicorn-mark에서 mark.sh 실행
2. Endpoint 3종과 Flow Log 확인
3. KMS 세 alias가 모두 True 90
4. ECR scan finding 완전 0
5. EKS endpoint false true, 로그 5종
6. App Pod 2개 Ready/Available, 2개 AZ
7. POST/GET/health CloudFront 테스트
8. ALB 직접 요청 000 또는 403
9. XSS 403
10. 최신 POST 로그가 30초 안에 도착
11. /health 로그 검색 0
12. Grafana 5개 패널 No Data 없음
13. 모든 테스트와 부하 중지

## 15. 빠른 장애 진단

| 증상 | 확인 |
|---|---|
| ImagePullBackOff | ECR api/dkr, S3 Endpoint, SG, Node Role |
| kubectl 실패 | unicorn-mark, private endpoint, access entry |
| CloudFront 502 | VPC Origin, ALB SG, target health |
| POST 200인데 DB 없음 | Pod Identity, TABLE_NAME, KMS 권한 |
| GET 502 | Lambda permission, ALB response, DynamoDB 권한 |
| S3 403 | OAC, SourceArn, Data KMS policy |
| 로그가 문자열 | Fluent Bit JSON parser 순서 |
| /health 로그 존재 | exclude filter key/path |
| Grafana No Data | datasource, scrape target, label |
| Rate test 200 | 60초 window, rule priority, 전파 대기 |