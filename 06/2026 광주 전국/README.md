# ☁️ 2026 전국기능경기대회 · 클라우드컴퓨팅

> **제 1과제 — Solution Architecture**  
> 풀이 해설집 및 이론 참고서

![AWS](https://img.shields.io/badge/AWS-Cloud-FF9900?style=flat-square&logo=amazon-aws&logoColor=white)
![EKS](https://img.shields.io/badge/EKS-Kubernetes-326CE5?style=flat-square&logo=kubernetes&logoColor=white)
![Region](https://img.shields.io/badge/Region-ap--northeast--2-232F3E?style=flat-square&logo=amazon-aws&logoColor=white)
![Time](https://img.shields.io/badge/경기시간-4시간-blue?style=flat-square)

---

## 📋 목차

- [아키텍처 개요](#-아키텍처-개요)
- [소프트웨어 스택](#-소프트웨어-스택)
- [시간 배분 전략](#-시간-배분-전략)
- [01. 네트워크 구성](#01-네트워크-구성)
- [02. KMS 키 관리](#02-kms-키-관리)
- [03. ECR 컨테이너 레지스트리](#03-ecr-컨테이너-레지스트리)
- [04. DynamoDB](#04-dynamodb)
- [05. EKS 클러스터 구성](#05-eks-클러스터-구성)
- [06. 애플리케이션 배포](#06-애플리케이션-배포)
- [07. 로드 밸런서 (ALB)](#07-로드-밸런서-alb)
- [08. S3 정적 웹 호스팅](#08-s3-정적-웹-호스팅)
- [09. Lambda 함수](#09-lambda-함수)
- [10. CloudFront CDN](#10-cloudfront-cdn)
- [11. WAF 보안 설정](#11-waf-보안-설정)
- [12. 모니터링](#12-모니터링-grafana--fluent-bit)
- [핵심 이론 정리](#-핵심-이론-정리)
- [최종 체크리스트](#-최종-체크리스트)

---

## 🏗️ 아키텍처 개요

```
사용자
  │
  ▼
CloudFront (gj2026-cdn)  ◄──── WAF (gj2026-waf-acl)
  │
  ├─ /v1/*         ──► VPC Origin (gj2026-alb-origin)
  │                        │
  ├─ /grafana*     ──►   ALB (gj2026-alb) [Private Subnet]
  │                        │
  │                   ┌────┴────┐
  │                   ▼         ▼
  │              book Pod    Grafana Pod
  │              (skills ns) (monitoring ns)
  │                   │
  │                   ▼
  │              DynamoDB (books)  ← CMK 암호화
  │
  ├─ /reservation* ──► Lambda (gj2026-book-reservation)
  │                        │
  │                        ▼
  │                   DynamoDB (books) 조회
  │
  └─ 정적 파일     ──► S3 (gj2026-static-{비번호})  ← OAC
```

### 경로별 라우팅 요약

| 경로 패턴 | 오리진 | 캐싱 | 비고 |
|-----------|--------|------|------|
| `/v1/*` | VPC Origin → ALB → book Pod | ❌ | Query String 전달 |
| `/grafana*` | VPC Origin → ALB → Grafana Pod | ❌ | subpath 설정 필요 |
| `/reservation*` | Lambda Function URL | ❌ | WAF 형식 검증 |
| `*.html`, `*.js` 등 | S3 OAC | ✅ | CDN 캐싱 |
| `/*` (기본) | S3 OAC | ✅ | index.html 폴백 |

---

## 🛠 소프트웨어 스택

| AWS 서비스 | 역할 |
|-----------|------|
| VPC | Private 전용 네트워크 / 2개 AZ |
| EKS 1.35 | Kubernetes 클러스터 / Addon·App 노드그룹 분리 |
| ECR | 컨테이너 이미지 저장 (3MB 제한) |
| DynamoDB | NoSQL 예약 DB / CMK 암호화 / GSI |
| ALB | Private 로드밸런서 / 경로 라우팅 |
| S3 | 정적 콘텐츠 / CMK 암호화 / OAC |
| Lambda | 예약 조회 API / Python 3.14 |
| CloudFront | CDN / HTTP→HTTPS / 경로별 오리진 |
| WAF | POST 제한 / client_id 형식 검증 |
| KMS | DynamoDB·S3·EKS Secret 암호화 |
| CloudWatch | Lambda 메트릭 / Fluent Bit 로그 |
| Grafana | CloudWatch 메트릭 시각화 |
| Fluent Bit | EKS 로그 수집 → AZ별 스트림 분리 |

---

## ⏱️ 시간 배분 전략

| 시간 | 작업 | 비고 |
|------|------|------|
| 0:00 ~ 0:20 | KMS 키 3개 생성 | 가장 먼저! 후속 작업 선행 조건 |
| 0:20 ~ 0:40 | VPC / 서브넷 / IGW / 라우팅 | EKS 태그 함께 추가 |
| 0:40 ~ 1:10 | EKS 클러스터 + 노드그룹 생성 | 생성 시간 길어 병렬 작업 |
| 1:10 ~ 1:30 | ECR 생성, 이미지 빌드 & 푸시 | 3MB 이하 확인 |
| 1:30 ~ 1:50 | DynamoDB 테이블 + GSI | CMK 암호화 적용 |
| 1:50 ~ 2:20 | EKS 앱 배포 (Namespace·Deployment·Service) | IRSA 설정 포함 |
| 2:20 ~ 2:40 | ALB 설정 (AWS LBC Ingress) | Private 서브넷 지정 |
| 2:40 ~ 3:00 | S3 버킷 + Lambda 함수 | OAC 설정 포함 |
| 3:00 ~ 3:20 | CloudFront 배포 구성 | VPC Origin 생성 |
| 3:20 ~ 3:40 | WAF Web ACL 생성 및 연결 | us-east-1 주의 |
| 3:40 ~ 4:00 | Grafana + Fluent Bit 배포 | 대시보드 저장 |

---

## 01. 네트워크 구성

### Reference 값

#### VPC
| Name | CIDR |
|------|------|
| `gj2026-vpc` | `10.0.0.0/16` |

#### Subnet
| Name | CIDR | AZ |
|------|------|----|
| `gj2026-private-subnet-a` | `10.0.10.0/24` | ap-northeast-2a |
| `gj2026-private-subnet-b` | `10.0.11.0/24` | ap-northeast-2c |

#### Routing Table
| Name | Subnet | IGW 경로 |
|------|--------|---------|
| `gj2026-private-rtb-a` | `gj2026-private-subnet-a` | ❌ (없음) |
| `gj2026-private-rtb-b` | `gj2026-private-subnet-b` | ❌ (없음) |

> ⚠️ **IGW는 VPC에 연결하되 라우팅 테이블에 추가하지 않습니다.**  
> CloudFront VPC Origin이 내부적으로 IGW를 통해 ALB에 접근하지만, 일반 인터넷 트래픽은 차단됩니다.

### Step 1: VPC 생성

```bash
aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=gj2026-vpc}]" \
  --region ap-northeast-2

# DNS 활성화 (EKS 필수)
aws ec2 modify-vpc-attribute --vpc-id <VPC_ID> --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id <VPC_ID> --enable-dns-support
```

### Step 2: 서브넷 생성

```bash
# Subnet A (ap-northeast-2a)
aws ec2 create-subnet \
  --vpc-id <VPC_ID> \
  --cidr-block 10.0.10.0/24 \
  --availability-zone ap-northeast-2a \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=gj2026-private-subnet-a}]"

# Subnet B (ap-northeast-2c)
aws ec2 create-subnet \
  --vpc-id <VPC_ID> \
  --cidr-block 10.0.11.0/24 \
  --availability-zone ap-northeast-2c \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=gj2026-private-subnet-b}]"
```

### Step 3: Internet Gateway 생성 및 연결

```bash
aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=gj2026-igw}]"

# VPC에 연결 (라우팅 테이블에는 추가 금지!)
aws ec2 attach-internet-gateway \
  --internet-gateway-id <IGW_ID> \
  --vpc-id <VPC_ID>
```

### Step 4: EKS용 서브넷 태그 (필수!)

```bash
aws ec2 create-tags --resources <SUBNET_ID> \
  --tags \
    Key=kubernetes.io/role/internal-elb,Value=1 \
    Key=kubernetes.io/cluster/gj2026-eks-cluster,Value=shared
```

---

## 02. KMS 키 관리

생성해야 하는 KMS 키 **3개**:

| Alias | 용도 |
|-------|------|
| `alias/gj2026-db-key` | DynamoDB 암호화 |
| `alias/gj2026-s3-key` | S3 버킷 암호화 |
| `alias/gj2026-eks-key` | EKS Secret 암호화 |

```bash
# DynamoDB 키
KEY_ID=$(aws kms create-key \
  --description "gj2026 DynamoDB key" \
  --query "KeyMetadata.KeyId" --output text)
aws kms create-alias --alias-name alias/gj2026-db-key --target-key-id $KEY_ID

# S3 키
KEY_ID2=$(aws kms create-key \
  --description "gj2026 S3 key" \
  --query "KeyMetadata.KeyId" --output text)
aws kms create-alias --alias-name alias/gj2026-s3-key --target-key-id $KEY_ID2

# EKS 키
KEY_ID3=$(aws kms create-key \
  --description "gj2026 EKS key" \
  --query "KeyMetadata.KeyId" --output text)
aws kms create-alias --alias-name alias/gj2026-eks-key --target-key-id $KEY_ID3

# ARN 확인 (후속 작업에서 필요)
aws kms describe-key --key-id alias/gj2026-db-key --query "KeyMetadata.Arn" --output text
```

---

## 03. ECR 컨테이너 레지스트리

> ⚠️ **이미지 크기 3MB 초과 불가** → `scratch` 또는 `distroless` 베이스 이미지 사용

### Repository 생성

```bash
aws ecr create-repository \
  --repository-name book \
  --image-scanning-configuration scanOnPush=true \
  --region ap-northeast-2
```

### Dockerfile (3MB 이하)

```dockerfile
FROM scratch
COPY book-app /app
ENTRYPOINT ["/app"]
```

### 이미지 빌드 및 푸시

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.ap-northeast-2.amazonaws.com"

# ECR 로그인
aws ecr get-login-password --region ap-northeast-2 \
  | docker login --username AWS --password-stdin $ECR_URI

# amd64 빌드 및 푸시
docker build --platform linux/amd64 -t book:latest .
docker tag book:latest ${ECR_URI}/book:latest
docker push ${ECR_URI}/book:latest

# 크기 확인 (3MB = 3,145,728 bytes 이하)
aws ecr describe-images --repository-name book \
  --query "imageDetails[0].imageSizeInBytes"
```

---

## 04. DynamoDB

### 테이블 스펙

| 항목 | 값 |
|------|----|
| Table Name | `books` |
| Partition Key | `booking_id` (String) |
| GSI Name | `client_id-index` |
| GSI Partition Key | `client_id` (String) |
| KMS Key | `alias/gj2026-db-key` |
| Billing Mode | `PAY_PER_REQUEST` |

### 테이블 생성

```bash
KMS_ARN=$(aws kms describe-key --key-id alias/gj2026-db-key \
  --query "KeyMetadata.Arn" --output text)

aws dynamodb create-table \
  --table-name books \
  --attribute-definitions \
    AttributeName=booking_id,AttributeType=S \
    AttributeName=client_id,AttributeType=S \
  --key-schema \
    AttributeName=booking_id,KeyType=HASH \
  --global-secondary-indexes '[
    {
      "IndexName": "client_id-index",
      "KeySchema": [{"AttributeName":"client_id","KeyType":"HASH"}],
      "Projection": {"ProjectionType":"ALL"},
      "BillingMode": "PAY_PER_REQUEST"
    }
  ]' \
  --billing-mode PAY_PER_REQUEST \
  --sse-specification Enabled=true,SSEType=KMS,KMSMasterKeyId=${KMS_ARN}
```

> 🚨 **채점 전 모든 데이터 항목 삭제 필수!**

---

## 05. EKS 클러스터 구성

### 클러스터 스펙

| 항목 | 값 |
|------|----|
| Cluster Name | `gj2026-eks-cluster` |
| Version | `1.35` |
| KMS Key | `alias/gj2026-eks-key` |

### 노드그룹 스펙

| 항목 | Addon Nodegroup | App Nodegroup |
|------|----------------|---------------|
| Name | `gj2026-eks-addon-nodegroup` | `gj2026-eks-app-nodegroup` |
| Instance Type | `t3.medium` | `m5.large` |
| 노드 수 | 2 | 2 |
| AMI | Bottlerocket | Bottlerocket |
| EC2 Tag | `Name=gj2026-eks-addon-node` | `Name=gj2026-eks-app-node` |
| 노드 이름 형식 | `gj2026.<instance_id>.addon.node` | `gj2026.<instance_id>.app.node` |

### eksctl 클러스터 생성 (`cluster.yaml`)

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: gj2026-eks-cluster
  region: ap-northeast-2
  version: "1.35"

vpc:
  id: <VPC_ID>
  subnets:
    private:
      ap-northeast-2a:
        id: <SUBNET_A_ID>
      ap-northeast-2c:
        id: <SUBNET_B_ID>

secretsEncryption:
  keyARN: <alias/gj2026-eks-key ARN>

managedNodeGroups:
  - name: gj2026-eks-addon-nodegroup
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 2
    maxSize: 2
    amiFamily: Bottlerocket
    privateNetworking: true
    labels:
      role: addon
    tags:
      Name: gj2026-eks-addon-node

  - name: gj2026-eks-app-nodegroup
    instanceType: m5.large
    desiredCapacity: 2
    minSize: 2
    maxSize: 2
    amiFamily: Bottlerocket
    privateNetworking: true
    labels:
      role: app
    tags:
      Name: gj2026-eks-app-node
```

```bash
eksctl create cluster -f cluster.yaml
```

### Namespace 생성

```bash
kubectl create namespace skills      # 애플리케이션
kubectl create namespace monitoring  # Grafana
kubectl create namespace logging     # Fluent Bit
```

### AWS Load Balancer Controller 설치 (Addon NodeGroup)

```bash
# IRSA 설정
eksctl create iamserviceaccount \
  --cluster=gj2026-eks-cluster \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::aws:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve

# Helm 설치
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=gj2026-eks-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set nodeSelector."role"=addon
```

### Taint & Toleration으로 Pod 격리

```bash
# App 노드: 앱 Pod만 허용
kubectl taint nodes -l role=app dedicated=app:NoSchedule

# Addon 노드: Addon만 허용
kubectl taint nodes -l role=addon dedicated=addon:NoSchedule
```

---

## 06. 애플리케이션 배포

### Deployment (`book-deployment.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: book
  namespace: skills
spec:
  replicas: 2
  selector:
    matchLabels:
      app: book
  template:
    metadata:
      labels:
        app: book
    spec:
      serviceAccountName: book-sa
      tolerations:
      - key: dedicated
        value: app
        effect: NoSchedule
      nodeSelector:
        role: app
      containers:
      - name: book
        image: <ACCOUNT_ID>.dkr.ecr.ap-northeast-2.amazonaws.com/book:latest
        ports:
        - containerPort: 8080
        env:
        - name: AWS_REGION
          value: "ap-northeast-2"
        - name: TABLE_NAME
          value: "books"
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
```

### Service (`book-service.yaml`)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: book-svc
  namespace: skills
spec:
  selector:
    app: book
  ports:
  - protocol: TCP
    port: 80
    targetPort: 8080
  type: ClusterIP
```

### NetworkPolicy: ALB에서만 수신

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: book-netpol
  namespace: skills
spec:
  podSelector:
    matchLabels:
      app: book
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          app.kubernetes.io/name: aws-load-balancer-controller
    ports:
    - protocol: TCP
      port: 8080
```

---

## 07. 로드 밸런서 (ALB)

### 스펙

| 항목 | 값 |
|------|----|
| ALB Name | `gj2026-alb` |
| Book Target Group | `gj2026-book-tg` |
| Grafana Target Group | `gj2026-grafana-tg` |
| 배치 위치 | Private Subnet (인터넷 직접 접근 불가) |

### Ingress 리소스 (`alb-ingress.yaml`)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gj2026-alb
  namespace: skills
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/load-balancer-name: gj2026-alb
    alb.ingress.kubernetes.io/subnets: <SUBNET_A_ID>,<SUBNET_B_ID>
spec:
  rules:
  - http:
      paths:
      - path: /grafana
        pathType: Prefix
        backend:
          service:
            name: grafana-svc
            port:
              number: 80
      - path: /
        pathType: Prefix
        backend:
          service:
            name: book-svc
            port:
              number: 80
```

---

## 08. S3 정적 웹 호스팅

> 버킷 이름: `gj2026-static-{비번호}` (예: `gj2026-static-001`)

```bash
BNUM="001"  # 본인 비번호로 교체
S3_KMS_ARN=$(aws kms describe-key --key-id alias/gj2026-s3-key \
  --query "KeyMetadata.Arn" --output text)

# 버킷 생성
aws s3api create-bucket \
  --bucket gj2026-static-${BNUM} \
  --region ap-northeast-2 \
  --create-bucket-configuration LocationConstraint=ap-northeast-2

# 퍼블릭 액세스 차단
aws s3api put-public-access-block \
  --bucket gj2026-static-${BNUM} \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,\
    BlockPublicPolicy=true,RestrictPublicBuckets=true

# SSE-KMS 기본 암호화 (업로드 시 자동 CMK 암호화)
aws s3api put-bucket-encryption \
  --bucket gj2026-static-${BNUM} \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "'"$S3_KMS_ARN"'"
      },
      "BucketKeyEnabled": true
    }]
  }'
```

### CloudFront OAC 버킷 정책

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "cloudfront.amazonaws.com"},
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::gj2026-static-{비번호}/*",
    "Condition": {
      "StringEquals": {
        "AWS:SourceArn": "arn:aws:cloudfront::<ACCOUNT_ID>:distribution/<DIST_ID>"
      }
    }
  }]
}
```

---

## 09. Lambda 함수

### 스펙

| 항목 | 값 |
|------|----|
| Function Name | `gj2026-book-reservation` |
| Runtime | `python3.14` |
| API | GET `/reservation`, GET `/reservation?client_id=Cxxxxx` |

### 함수 코드 (`lambda_function.py`)

```python
import json
import boto3

dynamodb = boto3.resource("dynamodb", region_name="ap-northeast-2")
table = dynamodb.Table("books")

def lambda_handler(event, context):
    params = event.get("queryStringParameters") or {}
    client_id = params.get("client_id")

    # CloudWatch 커스텀 메트릭 전송
    cw = boto3.client("cloudwatch", region_name="ap-northeast-2")
    cw.put_metric_data(
        Namespace="BookReservation",
        MetricData=[{
            "MetricName": "InvocationCount",
            "Dimensions": [{"Name": "client_id", "Value": client_id or "ALL"}],
            "Value": 1,
            "Unit": "Count"
        }]
    )

    if client_id:
        # GSI로 client_id별 조회
        response = table.query(
            IndexName="client_id-index",
            KeyConditionExpression=boto3.dynamodb.conditions.Key("client_id").eq(client_id)
        )
    else:
        # 전체 조회
        response = table.scan()

    items = response.get("Items", [])
    result = [
        {
            "username": i.get("username"),
            "email": i.get("email"),
            "concert_name": i.get("concert_name")
        }
        for i in items
    ]

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(result)
    }
```

### 배포

```bash
zip function.zip lambda_function.py

aws lambda create-function \
  --function-name gj2026-book-reservation \
  --runtime python3.14 \
  --role <LAMBDA_EXECUTION_ROLE_ARN> \
  --handler lambda_function.lambda_handler \
  --zip-file fileb://function.zip \
  --region ap-northeast-2

# CloudFront 오리진용 Function URL 생성
aws lambda create-function-url-config \
  --function-name gj2026-book-reservation \
  --auth-type NONE
```

---

## 10. CloudFront CDN

### 스펙

| 항목 | 값 |
|------|----|
| Distribution Name | `gj2026-cdn` |
| VPC Origin Name | `gj2026-alb-origin` |
| 뷰어 프로토콜 | HTTP → HTTPS 리디렉션 |
| Default Root Object | `index.html` |

### 오리진별 캐시 동작 설정

| 경로 | Cache Policy | Origin Request Policy |
|------|-------------|----------------------|
| `/reservation*` | CachingDisabled | AllViewer (Query String 전달) |
| `/v1/*`, `/grafana*` | CachingDisabled | AllViewer |
| `/*` (S3) | CachingOptimized | — |

```bash
# ALB용 VPC Origin은 콘솔에서 생성 권장
# CloudFront → 오리진 → VPC 오리진 생성 → ALB ARN 선택
# VPC Origin Name: gj2026-alb-origin

# 캐시 비활성화 Policy ID (AWS 관리형)
# CachingDisabled: 4135ea2d-6df8-44a3-9df3-4b5a84be39ad
# AllViewer:       216adef6-5c7f-47e4-b989-5492eafa07d3
```

---

## 11. WAF 보안 설정

> ⚠️ **CloudFront 연동 WAF는 반드시 `us-east-1` 리전에 생성**

### 규칙 설계

#### 규칙 1: POST 이외 메서드 차단 (ALB 대상)

```
조건: URI 경로가 /v1/ 로 시작 AND HTTP 메서드 ≠ POST
액션: Block
응답: 405 + "Method Not Allowed"
```

#### 규칙 2: client_id 형식 검증 (Lambda 대상)

```
조건: URI 경로가 /reservation 으로 시작
      AND client_id 쿼리 파라미터 존재
      AND 형식 불일치 (영문자 시작 + 숫자 포함 형식 아님)
허용 정규식: ^[a-zA-Z][a-zA-Z0-9]*[0-9]+[a-zA-Z0-9]*$
액션: Block
응답: 403 + "Access Denied"
```

```bash
aws wafv2 create-web-acl \
  --name gj2026-waf-acl \
  --scope CLOUDFRONT \
  --default-action Allow={} \
  --region us-east-1 \
  --visibility-config \
    SampledRequestsEnabled=true,\
    CloudWatchMetricsEnabled=true,\
    MetricName=gj2026-waf-acl \
  --rules file://waf-rules.json
```

---

## 12. 모니터링 (Grafana + Fluent Bit)

### Grafana 배포

| 항목 | 값 |
|------|----|
| Admin Password | `Skills53#` |
| Namespace | `monitoring` |
| Dashboard Name | `WSI Dashboard` |

```bash
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update

helm install grafana grafana/grafana \
  --namespace monitoring \
  --set adminPassword=Skills53# \
  --set nodeSelector."role"=addon \
  --set service.type=ClusterIP \
  --set "grafana\.ini.server.root_url=%(protocol)s://%(domain)s/grafana" \
  --set "grafana\.ini.server.serve_from_sub_path=true"
```

### Fluent Bit DaemonSet

| 항목 | 값 |
|------|----|
| Namespace | `logging` |
| DaemonSet Name | `aws-for-fluent-bit` |
| CloudWatch Log Group | `/eks/book-svc/access` |
| Log Stream (AZ-a) | `/book-svc/ap-northeast-2a` |
| Log Stream (AZ-b) | `/book-svc/ap-northeast-2b` |

#### Fluent Bit 설정 핵심 (`configmap.yaml`)

```ini
[INPUT]
    Name   tail
    Path   /var/log/containers/book-*.log
    Parser json
    Tag    book.access

[FILTER]
    Name   lua
    Match  book.access
    script route_by_az.lua
    call   set_az_stream

[OUTPUT]
    Name              cloudwatch_logs
    Match             book.access
    region            ap-northeast-2
    log_group_name    /eks/book-svc/access
    log_stream_name   $(stream)
    auto_create_group true
```

#### Lua 스크립트 (IP → AZ 분류)

```lua
-- route_by_az.lua
-- 10.0.10.x → ap-northeast-2a  /  10.0.11.x → ap-northeast-2b
function set_az_stream(tag, timestamp, record)
    local ip = record["remote_addr"]
    if ip and string.match(ip, "^10%.0%.10%.") then
        record["stream"] = "/book-svc/ap-northeast-2a"
    else
        record["stream"] = "/book-svc/ap-northeast-2b"
    end
    return 1, timestamp, record
end
```

### Grafana 대시보드 설정 (WSI Dashboard)

```
데이터소스: CloudWatch (ap-northeast-2)
Namespace:  BookReservation
MetricName: InvocationCount
Dimension:  client_id = {특정값 또는 ALL}
통계:        Sum
기간:        5분
```

---

## 📚 핵심 이론 정리

### Kubernetes 핵심 개념

| 개념 | 설명 |
|------|------|
| Pod | Kubernetes 최소 배포 단위. 1개 이상의 컨테이너 포함 |
| Deployment | Pod의 선언적 관리. replicas, 롤링 업데이트 |
| Service | Pod에 안정적인 네트워크 엔드포인트 제공 |
| Ingress | HTTP(S) 라우팅 규칙. AWS에서는 ALB로 구현 |
| Secret | 민감 데이터 저장. KMS 암호화 권장 |
| IRSA | Pod에 IAM Role 부여. SA ↔ IAM Role 연결 |
| DaemonSet | 모든 노드에 1개씩 배포. 로그 수집/모니터링 |
| Namespace | 클러스터 내 논리적 격리 단위 |

### AWS 보안 핵심

| 개념 | 설명 |
|------|------|
| KMS CMK | 고객 직접 생성/관리 암호화 키. 키 정책으로 세밀한 접근 제어 |
| IAM Role | 임시 자격 증명. EC2/Lambda/EKS Pod에 연결 |
| VPC Endpoint | 인터넷 없이 AWS 서비스에 접근. Interface/Gateway 유형 |
| WAF | HTTP 요청 검사. 커스텀 규칙으로 차단/허용 제어 |
| OAC | S3 + CloudFront 연동 최신 방식. SSE-KMS 호환 |

### 고가용성 설계 원칙

- **다중 AZ 배포**: 서브넷을 최소 2개 AZ에 배포
- **헬스체크**: ALB Target Group + K8s Liveness/Readiness Probe
- **장애 격리**: App/Addon 노드그룹 분리로 영향 범위 최소화
- **자동 복구**: Deployment의 ReplicaSet이 Pod 장애 시 자동 재시작

---

## ✅ 최종 체크리스트

경기 종료 전 반드시 확인하세요!

- [ ] KMS 키 3개 모두 생성 (`db`, `s3`, `eks`)
- [ ] EKS 서브넷에 `kubernetes.io` 태그 추가
- [ ] **DynamoDB 채점 전 모든 데이터 삭제**
- [ ] S3 버킷 이름에 비번호 포함 (`gj2026-static-{비번호}`)
- [ ] ECR 이미지 크기 3MB 이하 확인
- [ ] book 앱 환경변수 `AWS_REGION`, `TABLE_NAME` 설정
- [ ] Grafana `/grafana` subpath 설정
- [ ] CloudFront HTTP → HTTPS 리디렉션 활성화
- [ ] WAF를 `us-east-1`에 생성 (CloudFront 연동)
- [ ] Fluent Bit DaemonSet 배포 (`logging` namespace)
- [ ] CloudWatch 로그 스트림 2개 확인 (`2a`, `2b`)
- [ ] Grafana `WSI Dashboard` 생성 및 저장
- [ ] EKS Secret KMS 암호화 확인
- [ ] ALB 이름 `gj2026-alb`, TG 이름 정확히 입력
- [ ] 모든 리소스 이름 **대소문자** 정확히 입력

---

<div align="center">

**대구스마트고등학교 소프트웨어과**  
2026 전국기능경기대회 클라우드컴퓨팅 직종

</div>
