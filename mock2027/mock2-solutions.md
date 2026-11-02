# 2027 지방대회 대비 모의고사 2회 · 문제 해설집

두 과제의 구현 순서와 핵심 코드, 검증 기준을 정리했습니다. 제2과제는 현재 게시된 확장 문제지 기준입니다. 예시는 계정ID·비번호·ARN을 치환해야 하며 AWS 실계정 배포 검증은 수행하지 않았습니다.

## 제1과제 · Private EKS 예매 플랫폼

### 1. 네트워크·Bastion·데이터

1. ticket-vpc(10.20.0.0/16)에 Public A/B, Private A/B를 문제의 CIDR로 만듭니다. Public은 IGW, Private은 같은 AZ NAT로 기본 경로를 지정합니다.
2. Public에 kubernetes.io/role/elb=1, Private에 kubernetes.io/role/internal-elb=1을 태그합니다.
3. ticket-bastion은 Public A의 t3.small, AL2023, EIP, AdministratorAccess 역할로 구성합니다.
4. ticket-table은 ticket_id(String), PAY_PER_REQUEST, CMK alias/ticket-ddb-key, PITR, 삭제 방지로 구성합니다.
5. ECR ticket-api는 KMS 암호화, scanOnPush, IMMUTABLE로 만들고 문제 부록 코드로 만든 v1.0.0 이미지를 push합니다.

Python 3.12 slim 이미지에 requirements.txt를 설치한 뒤 app.py를 복사하고 python app.py로 실행하면 됩니다. 컨테이너는 8080을 사용합니다. 클러스터 노드 아키텍처에 맞춰 linux/amd64로 빌드합니다.

### 2. EKS와 접근 권한

ticket-cluster를 생성할 때 현재 지원되는 버전을 확인해 선택하고 kubectl은 같은 minor로 설치합니다. Private endpoint만 활성화합니다. api·audit·authenticator 제어 영역 로그와 alias/ticket-eks-key를 이용한 Secret 암호화를 설정합니다.

ticket-ng는 두 Private 서브넷, t3.medium, Min/Desired 2, Max 4입니다. node label role=app을 지정하고 노드 EC2 Name은 ticket-node가 되도록 구성합니다. 클러스터 SG에 Bastion에서 API 443으로 접근할 경로를 확인합니다.

Bastion 역할 ARN을 EKS Access entry로 등록하고 AmazonEKSClusterAdminPolicy를 cluster 범위로 연결합니다. STS assumed-role 세션 ARN이 아닌 IAM role ARN을 사용합니다. ec2-user의 홈에서 kubeconfig를 만듭니다.

```bash
aws eks update-kubeconfig --region ap-northeast-2 --name ticket-cluster
kubectl get nodes -L role
helm version
```

Timeout이면 Private endpoint DNS·라우팅·SG를, Unauthorized이면 Access entry와 실제 호출 역할을 확인합니다. root 사용자 홈에만 kubeconfig를 만들어 두면 ec2-user 채점이 실패합니다.

### 3. Pod Identity·컨트롤러

EKS Pod Identity Agent add-on을 설치합니다. ticket-pod-role은 pods.eks.amazonaws.com을 신뢰하고 sts:AssumeRole 및 sts:TagSession을 허용합니다. IAM 정책은 ticket-table의 PutItem/GetItem과 지정 CMK 사용에 필요한 권한으로 제한합니다. association을 cluster=ticket-cluster, namespace=ticket, serviceAccount=ticket-sa로 만듭니다.

AWS Load Balancer Controller는 별도 ServiceAccount와 공식 IAM 정책으로 설치합니다. 앱 역할에 컨트롤러 권한을 합치지 않습니다. 설치 시 clusterName, region, vpcId를 확인합니다. Metrics Server도 설치하고 kubectl top nodes가 성공하는지 확인합니다.

### 4. Kubernetes 매니페스트

<이미지URI>를 본인 ECR ticket-api:v1.0.0 전체 URI로 바꿉니다.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ticket
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ticket-sa
  namespace: ticket
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ticket-api
  namespace: ticket
spec:
  replicas: 2
  selector:
    matchLabels: {app: ticket-api}
  template:
    metadata:
      labels: {app: ticket-api}
    spec:
      serviceAccountName: ticket-sa
      nodeSelector: {role: app}
      containers:
        - name: api
          image: <이미지URI>
          ports:
            - containerPort: 8080
          env:
            - {name: TABLE_NAME, value: ticket-table}
            - {name: AWS_REGION, value: ap-northeast-2}
          resources:
            requests: {cpu: 250m, memory: 256Mi}
          readinessProbe:
            httpGet: {path: /health, port: 8080}
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet: {path: /health, port: 8080}
            initialDelaySeconds: 15
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: ticket-svc
  namespace: ticket
spec:
  type: ClusterIP
  selector: {app: ticket-api}
  ports:
    - {port: 80, targetPort: 8080}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ticket-ingress
  namespace: ticket
  annotations:
    alb.ingress.kubernetes.io/load-balancer-name: ticket-alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
    alb.ingress.kubernetes.io/healthcheck-path: /health
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ticket-svc
                port: {number: 80}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ticket-hpa
  namespace: ticket
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ticket-api
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
```

HPA의 CPU 사용률은 requests를 기준으로 계산됩니다. Node group Max 4와 HPA Max 6은 서로 다른 값이므로 혼동하지 않습니다. HPA만으로 노드 수가 자동 증가하는 것은 아닙니다.

### 5. Fluent Bit와 검증

amazon-cloudwatch 네임스페이스에 fluent-bit가 이름에 포함된 DaemonSet을 배포합니다. 각 노드의 /var/log/containers/*.log와 실제 로그 경로를 읽을 수 있게 hostPath를 연결합니다. 출력 플러그인은 cloudwatch_logs, region ap-northeast-2, log_group_name /ticket/app입니다. 해당 ServiceAccount에 별도 로그 전송 권한을 연결하고 그룹 보관을 7일로 설정합니다.

```bash
kubectl -n ticket rollout status deployment/ticket-api
kubectl -n ticket get pods,svc,ingress,hpa
kubectl -n amazon-cloudwatch get ds,pods
kubectl top pods -n ticket
```

ALB DNS에서 /health, POST /v1/tickets, GET /v1/tickets?ticket_id=<실제ID>를 확인합니다. 생성 로그가 5분 안에 /ticket/app에 보여야 합니다. DynamoDB AccessDenied이면 Pod Identity association·Agent·SDK 자격증명 경로를 확인합니다. 앱에 AWS_ACCESS_KEY_ID 같은 정적 키를 넣어 해결하지 않습니다.

채점 전 부하를 중지하고 HPA 안정화 후 Pod 2개를 확인합니다. 정리할 때 Ingress를 먼저 삭제하고 ALB 해제를 기다린 후 노드 그룹·클러스터·NAT를 삭제합니다.

## 제2과제 · 1. Terraform 재구축

iac-bastion과 버전 관리 Enabled인 iac-tfstate-<비번호> 버킷을 먼저 별도로 생성합니다. 아래 코드는 /home/ec2-user/iac/main.tf의 예입니다. backend 버킷의 <비번호>를 실제 숫자로 바꿉니다. Terraform은 use_lockfile을 지원하는 버전을 설치합니다.

```hcl
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
  backend "s3" {
    bucket       = "iac-tfstate-<비번호>"
    key          = "iac/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
  }
}
provider "aws" {
  region = "ap-northeast-2"
  default_tags {
    tags = { Project = "KoreaSkills" }
  }
}
data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
resource "aws_vpc" "web" {
  cidr_block           = "10.50.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "iac-vpc" }
}
resource "aws_subnet" "public" {
  for_each = {
    a = { cidr = "10.50.0.0/24", az = "ap-northeast-2a" }
    c = { cidr = "10.50.1.0/24", az = "ap-northeast-2c" }
  }
  vpc_id                  = aws_vpc.web.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true
  tags = { Name = "iac-pub-${each.key}" }
}
resource "aws_internet_gateway" "web" {
  vpc_id = aws_vpc.web.id
  tags = { Name = "iac-igw" }
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.web.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.web.id
  }
}
resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
resource "aws_security_group" "web" {
  name   = "iac-web-sg"
  vpc_id = aws_vpc.web.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_instance" "web" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public["a"].id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.web.id]
  root_block_device {
    encrypted = true
  }
  metadata_options {
    http_tokens = "required"
  }
  user_data = <<-EOF
    #!/bin/bash
    set -eu
    dnf install -y nginx
    printf 'Hello Terraform\n' > /usr/share/nginx/html/index.html
    systemctl enable --now nginx
  EOF
  depends_on = [aws_route_table_association.public]
  tags = { Name = "iac-web" }
}
output "web_url" {
  value = "http://${aws_instance.web.public_ip}"
}
```

terraform fmt와 validate로 문법을 확인하고 init -input=false, apply -auto-approve -input=false를 실행합니다. 생성된 .terraform.lock.hcl도 보관합니다. web_url의 HTTP 응답은 cloud-init과 nginx 설치가 끝난 후 확인합니다.

채점은 destroy 후 apply를 실제 수행합니다. Bastion·backend 버킷·다른 문항은 이 state에 포함하면 안 됩니다. 입력 변수는 자동 로드 tfvars나 기본값으로 공급합니다.

## 제2과제 · 2. Streaming data lake

1. 서울에 click-lake-<비번호>, click-result-<비번호>를 생성합니다.
2. Direct PUT Firehose click-stream을 만들고 S3 목적지를 로그 버킷으로 설정합니다. 버퍼 60초/1 MiB, prefix clicks/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/, error prefix errors/!{firehose:error-output-type}/를 정확히 입력합니다.
3. Firehose 역할에 목적지 버킷 ListBucket·GetBucketLocation·PutObject 등 전달에 필요한 권한을 설정합니다.
4. 문제의 6개 JSON을 events.jsonl에 한 줄씩 저장하고 각 레코드 끝에 LF를 넣어 각각 한 번만 전송합니다. CLI 사용 시 raw-in-base64-out 옵션과 JSON의 개행 처리를 확인합니다.
5. S3 객체 생성까지 기다리고 실제 객체를 열어 JSON 6건과 개행을 확인합니다. API 성공만으로 적재 완료를 판단하지 않습니다.
6. click-crawler는 s3://click-lake-<비번호>/clicks/만 크롤링하며 DB는 click_db입니다. crawler 역할에 S3 읽기·Glue 카탈로그 갱신 권한을 줍니다. 최종 테이블 clicks의 컬럼 user/page/ts, 파티션 year/month/day를 확인합니다.
7. click-wg에 결과 버킷, BytesScannedCutoffPerQuery=104857600을 지정합니다. click-top-pages 저장 쿼리는 해당 workgroup과 click_db에 연결합니다.

쿼리는 다음과 같습니다.

```sql
SELECT page, COUNT(*) AS cnt
FROM clicks
GROUP BY page
ORDER BY cnt DESC
LIMIT 3;
```

실행 결과는 /menu 3, /order 2, /event 1입니다. 중복 전송으로 건수가 늘면 실제 실습 데이터의 중복 원인을 수정합니다. DISTINCT나 상수 응답으로 감추지 않습니다. Firehose 날짜 경로는 도착 시각 UTC이므로 테스트 데이터의 ts 날짜로 고정하지 않습니다.

## 제2과제 · 3. Serverless REST API

memo-table은 memo_id(String), On-demand입니다. memo-handler는 Python 3.12, TABLE_NAME=memo-table 환경 변수를 사용합니다. 실행 역할의 DynamoDB 권한은 해당 테이블 PutItem/GetItem으로 제한하고 로그 권한은 별도로 줍니다.

```python
import json
import os
import uuid
import boto3

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])

def response(code, body):
    return {"statusCode": code,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(body, separators=(",", ":"))}

def lambda_handler(event, context):
    if event["httpMethod"] == "POST":
        body = json.loads(event.get("body") or "{}")
        if not isinstance(body.get("text"), str):
            return response(400, {"error": "invalid text"})
        memo_id = str(uuid.uuid4())
        table.put_item(Item={"memo_id": memo_id, "text": body["text"]})
        return response(201, {"memo_id": memo_id})
    memo_id = event["pathParameters"]["memo_id"]
    item = table.get_item(Key={"memo_id": memo_id}, ConsistentRead=True).get("Item")
    return response(200, item) if item else response(404, {"error": "not found"})
```

API Gateway는 REST API memo-api를 만듭니다. POST /memos와 GET /memos/{memo_id}에 Lambda proxy integration과 API key required를 설정하고 키 소스 HEADER로 둡니다. API Gateway의 Lambda 호출 권한도 등록합니다.

prod Stage로 배포한 뒤 활성 키 memo-key와 Usage plan memo-plan을 만듭니다. plan에는 prod Stage와 키를 모두 연결하고 Rate 10, Burst 20, Quota 1000/DAY를 지정합니다. 메서드 변경 후에는 prod에 다시 배포합니다.

유효한 x-api-key로 생성 201 → 같은 ID 조회 200 → 없는 ID 404를 확인하고 키를 빼면 403인지 확인합니다. 키 이름이나 ID가 아니라 실제 키 값으로 요청하며 키 값은 제출하지 않습니다.

## 제2과제 · 4. Fleet operation with SSM

도쿄의 ops-web-1/2에 Role=web 태그와 ops-ssm-role 인스턴스 프로파일을 연결합니다. 역할에는 AmazonSSMManagedInstanceCore 및 /ops/web/message GetParameter 권한이 필요합니다. 두 서버의 모든 SG에서 22를 허용하지 않습니다.

nginx 설치 경로와 SSM API 접근 경로를 확보하고 SSM Agent Online을 확인합니다. SecureString /ops/web/message의 초기값은 Hello Ops입니다. 고객 관리 KMS 키를 쓰면 kms:Decrypt와 키 정책도 확인합니다.

Command 타입 ops-update-index의 예입니다.

```yaml
schemaVersion: '2.2'
description: Update nginx page from Parameter Store
mainSteps:
  - action: aws:runShellScript
    name: updateIndex
    inputs:
      runCommand:
        - 'set -eu'
        - 'message=$(aws ssm get-parameter --region ap-northeast-1 --name /ops/web/message --with-decryption --query Parameter.Value --output text)'
        - 'printf "%s" "$message" > /usr/share/nginx/html/index.html'
        - 'chmod 644 /usr/share/nginx/html/index.html'
        - 'systemctl enable --now nginx'
```

ops-association은 해당 Document, Target key tag:Role/value web, rate(30 minutes)로 생성합니다. 두 대의 실행 성공 후 Run Command에서 curl -s localhost를 실행합니다. Parameter 값을 공백 포함 새 문자열로 변경하고 association을 수동 실행했을 때 두 대 모두 바뀌어야 합니다. 초기값을 코드에 고정하면 재실행 시험에서 실패합니다.

## 채점·복원·정리

제1과제는 ticket-bastion/ec2-user, 제2과제는 서울 iac-bastion/ec2-user에서 각 문제 페이지의 스크립트를 실행합니다. 제2과제는 Terraform 재구축과 도쿄 Parameter 변경을 실제 수행합니다. 채점 후 Parameter가 Hello Ops로 복원됐는지 확인하고 association을 다시 실행해 두 서버 파일도 복원합니다.

점수 저장 후 Terraform 관리 웹 환경을 먼저 destroy합니다. backend 버킷은 상태가 더 필요 없을 때 마지막에 정리합니다. S3 버전·삭제 마커, Firehose·Glue·Athena, API Gateway·Lambda·DynamoDB, 도쿄 SSM·EC2, IAM 역할과 남은 로그를 확인합니다.

