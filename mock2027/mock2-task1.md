# 2027 지방대회 대비 모의고사 2회 · 제1과제

## 응시 방법

1. 타이머를 4시간으로 맞추고 시작합니다. 인터넷은 AWS·Kubernetes 공식 문서만 참고합니다.
2. 과제를 마치면 Bastion(`ticket-bastion`)에 `ec2-user`로 접속해 페이지 하단의 채점 스크립트를 내려받아 실행합니다.
3. 출력 전체를 복사해 하단 제출 칸에 붙여넣고 제출합니다. 마지막 줄의 `TOTAL SCORE`가 점수입니다.
4. 채점이 끝나면 리소스를 모두 삭제합니다. EKS, NAT Gateway, ALB는 켜 둔 시간만큼 과금됩니다. Ingress를 먼저 지워야 ALB가 함께 삭제됩니다.

| 항목 | 내용 |
| --- | --- |
| 과제명 | Container platform |
| 경기시간 | 4시간 |
| 배점 | 50점 |
| 리전 | 서울(ap-northeast-2) |
| 채점 위치 | Bastion EC2 (`ticket-bastion`, ec2-user) |

## 1. 요구사항

당신은 공연 예매 서비스 SkillsTicket의 플랫폼 엔지니어입니다. 예매 API를 EKS에 배포하고, 예매 데이터는 DynamoDB에 저장합니다. Pod는 액세스 키 없이 최소 권한으로 DynamoDB에 접근해야 하고, 티켓 오픈 시간의 트래픽 급증에 자동으로 대응해야 합니다.

| AWS | Language / Framework |
| --- | --- |
| VPC, EC2, ECR, EKS, ALB(AWS Load Balancer Controller), DynamoDB, KMS, IAM, CloudWatch | Python 3.12 / Flask, Kubernetes, Helm |

## 2. 선수 유의사항

1. 문제의 괄호 `< >`는 변수입니다.
2. Security Group의 80/443 outbound는 anyopen해도 됩니다.
3. Bastion에서 AWS CLI와 kubectl로 채점합니다. Bastion이 EKS API에 접근하지 못하면 EKS 관련 문항이 모두 0점입니다.
4. 모든 리소스는 서울(ap-northeast-2) 리전에 생성합니다.
5. 과제 종료 전 부하를 모두 중지하고, `ticket-api` Pod 수가 2개로 돌아와 있어야 합니다.
6. Pod에 IAM 사용자 액세스 키를 넣으면 해당 문항은 0점입니다.

## 3. Networking

| 구분 | Name tag | CIDR | AZ | 인터넷 |
| --- | --- | --- | --- | --- |
| VPC | ticket-vpc | 10.20.0.0/16 | - | - |
| Public | ticket-pub-a | 10.20.0.0/24 | ap-northeast-2a | IGW (`ticket-igw`) |
| Public | ticket-pub-b | 10.20.1.0/24 | ap-northeast-2b | IGW |
| Private | ticket-priv-a | 10.20.10.0/24 | ap-northeast-2a | NAT (`ticket-nat-a`) |
| Private | ticket-priv-b | 10.20.11.0/24 | ap-northeast-2b | NAT (`ticket-nat-b`) |

- Route table: `ticket-pub-rt`, `ticket-priv-rt-a`, `ticket-priv-rt-b`
- ALB가 자동으로 서브넷을 찾을 수 있도록 Public 서브넷에는 `kubernetes.io/role/elb=1`, Private 서브넷에는 `kubernetes.io/role/internal-elb=1` 태그를 붙입니다.

## 4. Bastion

- Name tag: `ticket-bastion` / Instance type: `t3.small` / AMI: Amazon Linux 2023 / Subnet: `ticket-pub-a` / Elastic IP 연결
- IAM role: AdministratorAccess / EKS Access entry로 클러스터 관리자(`AmazonEKSClusterAdminPolicy`) 권한 부여
- Packages: awscli v2, curl, jq, kubectl(클러스터와 같은 minor 버전), helm, eksctl
- `ec2-user`로 로그인해 바로 `kubectl get nodes`가 동작해야 합니다.

## 5. DynamoDB

- Table name: `ticket-table` / Partition key: `ticket_id` (S) / Capacity: On-demand
- KMS CMK `alias/ticket-ddb-key`로 암호화 / PITR 활성화 / 삭제 방지 활성화

## 6. ECR

- Repository: `ticket-api` / Scan on push / Tag immutable / KMS 암호화 / Tag `v1.0.0`
- 이미지는 부록의 코드로 직접 빌드합니다. Dockerfile은 직접 작성합니다.

## 7. EKS

Private 형태의 EKS 클러스터를 만듭니다. Kubernetes API는 VPC 내부(특히 Bastion)에서만 접근할 수 있어야 하고, Control plane의 api·audit·authenticator 로그는 CloudWatch Logs에서 확인할 수 있어야 합니다. Kubernetes Secret은 KMS로 Envelope encryption합니다.

- Cluster name: `ticket-cluster` / Version: EKS가 지원하는 최신 버전
- Endpoint access: Private only / Secret 암호화 키: `alias/ticket-eks-key`
- Managed node group: `ticket-ng` / `t3.medium` / Min 2, Desired 2, Max 4 / Private 서브넷 / Node label `role=app`
- Node EC2 Name tag: `ticket-node`

## 8. Kubernetes 리소스

| 종류 | 이름 | 요구사항 |
| --- | --- | --- |
| Namespace | ticket | 앱 리소스는 모두 이 네임스페이스에 생성 |
| ServiceAccount | ticket-sa | EKS Pod Identity로 IAM role `ticket-pod-role`과 연결 |
| Deployment | ticket-api | replicas 2, `role=app` 노드에만 배치, requests cpu 250m / memory 256Mi, readiness·liveness probe `/health` |
| Service | ticket-svc | ClusterIP, 80 → 8080 |
| Ingress | ticket-ingress | AWS Load Balancer Controller, ALB 이름 `ticket-alb`, internet-facing, target-type ip, HTTP 80 |
| HPA | ticket-hpa | CPU 평균 50%, Min 2, Max 6 |

- `ticket-pod-role`은 `ticket-table`에 대한 `dynamodb:PutItem`, `dynamodb:GetItem`과 KMS 키 사용 권한만 가집니다.
- Deployment의 환경 변수: `TABLE_NAME=ticket-table`, `AWS_REGION=ap-northeast-2`
- HPA가 동작하도록 Metrics Server를 설치합니다.

## 9. Logging

컨테이너의 표준 출력 로그를 Fluent Bit DaemonSet으로 CloudWatch Logs에 보냅니다. 로그는 발생 후 5분 안에 조회되어야 합니다.

- Namespace: `amazon-cloudwatch` / DaemonSet 이름에 `fluent-bit` 포함
- App log group: `/ticket/app` / 보관 기간 7일

## 배점

| 번호 | 주요항목 | 세부항목 (배점) | 합계 |
| --- | --- | --- | --- |
| 1 | Networking | CIDR 1, 서브넷 4개 1.5, ELB 태그 1.5, AZ별 NAT 1, Private RT 경로 1 | 6 |
| 2 | Bastion | EIP 1, kubectl 동작 2, helm 1, Admin 권한 1 | 5 |
| 3 | DynamoDB | CMK 1.5, PITR 1, 삭제 방지 1, On-demand 0.5 | 4 |
| 4 | ECR | Immutable·Scan·KMS 2, 태그 1 | 3 |
| 5 | EKS | Private endpoint 2, Control plane 로그 2, Secret 암호화 2, Node group 크기 2, Label·Name tag 2 | 10 |
| 6 | Kubernetes | Deployment 2, nodeSelector 1, Probe 1.5, Requests 1, Service 1, Ingress ALB 2, HPA 2, Pod Identity 2, Metrics Server 1.5 | 14 |
| 7 | Application | 예매 생성 1.5, 예매 조회 1.5, 액세스 키 미사용 1 | 4 |
| 8 | Logging | Fluent Bit 전 노드 1.5, 보관 7일 1, 로그 수집 1.5 | 4 |
|  | **합계** |  | **50** |

## 부록: 제공 애플리케이션 코드

| API | Request | Response |
| --- | --- | --- |
| POST /v1/tickets | `{"event": "concert", "seat": "A-1"}` | `{"ticket_id": "<uuid>"}` |
| GET /v1/tickets | `?ticket_id=<uuid>` | `{"ticket_id": "<uuid>", "event": "concert", "seat": "A-1"}` |
| GET /health | - | `{"status": "ok"}` |

app.py

```python
import os, uuid, boto3
from flask import Flask, request

app = Flask(__name__)
table = boto3.resource("dynamodb", region_name=os.environ["AWS_REGION"]).Table(os.environ["TABLE_NAME"])

@app.get("/health")
def health():
    return {"status": "ok"}

@app.post("/v1/tickets")
def create():
    body = request.get_json()
    tid = str(uuid.uuid4())
    table.put_item(Item={"ticket_id": tid, "event": body["event"], "seat": body["seat"]})
    print("ticket created:", tid, flush=True)
    return {"ticket_id": tid}

@app.get("/v1/tickets")
def get():
    item = table.get_item(Key={"ticket_id": request.args["ticket_id"]}).get("Item")
    return item if item else ({"error": "not found"}, 404)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
```

requirements.txt

```text
flask==3.0.3
boto3==1.35.0
```
