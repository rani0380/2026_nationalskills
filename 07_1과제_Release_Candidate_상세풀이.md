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

Repository unicorn-concert-app:

- Scan on push true
- KMS, Data CMK
- IMMUTABLE_WITH_EXCLUSION
- latest만 Mutable 예외
- v1.0.0과 latest push
- v1.0.0 scan 이력 존재
- LOW를 포함한 어떤 취약점도 없어야 함

```bash
aws ecr describe-image-scan-findings   --repository-name unicorn-concert-app --image-id imageTag=v1.0.0
```

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