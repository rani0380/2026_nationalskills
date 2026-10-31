# 2027 지방대회 대비 모의고사 3회 · 제1과제

## 응시 방법

1. 제한 시간은 4시간입니다. AWS·Python·Docker 공식 문서를 참고할 수 있습니다.
2. 서울 리전 CloudShell에서 채점 스크립트를 실행합니다. AWS CLI v2와 Python 3가 필요합니다.
3. 설정 자동 점검은 30점, 교사가 실제 동작과 권한을 확인하는 실기 평가는 20점입니다. 자동 점검만으로 전체 요구사항을 검증하지 않습니다.
4. 교사는 아래 실기 평가표로 채점하고, 확정 점수를 스크립트의 두 번째 인자로 입력합니다. 학생의 임의 입력은 인정하지 않습니다.
5. 출력 전체를 하단에 제출합니다. 이 문제는 자체 제작 연습문제이며 공식 대회 문제가 아닙니다.

| 항목 | 내용 |
| --- | --- |
| 과제명 | SkillsDocs · Container document API |
| 시간 / 점수 | 4시간 / 50점 |
| 리전 | 서울 ap-northeast-2 |
| 목표 | 두 가용 영역에서 동작하는 비공개 컨테이너 서비스 구축 |

## 1. 시나리오와 공통 조건

학교의 문서 접수 API를 구축합니다. 외부 사용자는 ALB로만 접근하고, API는 DynamoDB에 문서 제목을 저장합니다. 애플리케이션은 ECS Task Role의 임시 자격증명으로 AWS에 접근합니다.

- 계정별 독립 실습을 가정합니다. 공유 계정이면 별도 계정을 배정합니다.
- 모든 주요 리소스에 Project=SkillsDocs 태그를 지정합니다. 태그를 지원하지 않는 리소스는 제외합니다.
- 임의의 IAM 액세스 키를 코드·이미지·환경 변수에 넣지 않습니다.
- 지정하지 않은 세부 설정은 기본값을 사용할 수 있습니다.
- 제2과제와 독립적으로 응시할 수 있습니다.

## 2. 네트워크

| 종류 | 이름 | CIDR | 가용 영역 |
| --- | --- | --- | --- |
| VPC | docs-vpc | 10.30.0.0/16 | - |
| Public | docs-pub-a | 10.30.0.0/24 | ap-northeast-2a |
| Public | docs-pub-c | 10.30.1.0/24 | ap-northeast-2c |
| Private | docs-app-a | 10.30.10.0/24 | ap-northeast-2a |
| Private | docs-app-c | 10.30.11.0/24 | ap-northeast-2c |

- Internet Gateway를 연결하고 Public 서브넷의 기본 경로를 설정합니다.
- 각 AZ에 NAT Gateway를 하나씩 생성하고 Private 서브넷은 같은 AZ의 NAT를 기본 경로로 사용합니다.
- DynamoDB Gateway VPC Endpoint를 생성해 두 Private 라우팅 테이블에 연결합니다.
- docs-alb-sg: 인터넷에서 TCP 80 허용.
- docs-api-sg: docs-alb-sg에서 오는 TCP 8080만 인바운드 허용. SSH 인바운드는 없어야 합니다.
- ALB는 두 Public 서브넷, ECS 서비스는 두 Private 서브넷을 사용합니다.

## 3. 데이터와 이미지

- DynamoDB docs-table: Partition key doc_id(String), On-demand, PITR 활성화.
- ECR docs-api: 태그 불변성 IMMUTABLE, 기본 스캔 scanOnPush=true, 이미지 태그 v1.
- 부록의 애플리케이션으로 linux/amd64 이미지를 빌드합니다. Dockerfile은 직접 작성합니다.
- 컨테이너는 8080 포트에서 실행하며 stdout으로 요청 처리 로그를 출력합니다.

## 4. ECS와 로드밸런서

| 항목 | 요구사항 |
| --- | --- |
| ECS Cluster | docs-cluster |
| Task Definition family | docs-api |
| 실행 방식 | FARGATE / awsvpc / Linux X86_64 |
| CPU / Memory | 256 / 512 MiB |
| Container name | api |
| 환경 변수 | TABLE_NAME=docs-table, AWS_REGION=ap-northeast-2 |
| ECS Service | docs-api / Desired count 2 / 두 Private 서브넷 / Public IP 비활성 |
| ALB | docs-alb / internet-facing / HTTP 80 |
| Target Group | docs-api-tg / ip / HTTP 8080 / Health check /health / 성공 코드 200 |
| 로그 | awslogs / 그룹 /skillsdocs/api / 보관 7일 / stream prefix ecs |

- Task Execution Role은 ECR 이미지 pull과 로그 전송에 필요한 권한을 갖습니다.
- Task Role은 docs-table의 PutItem, GetItem만 허용합니다. 두 역할을 구분합니다.
- 서비스의 Deployment circuit breaker 및 rollback을 활성화합니다.
- Application Auto Scaling: Min 2, Max 4, ECSServiceAverageCPUUtilization Target 60%, Scale-in/out cooldown 각 60초.
- CloudWatch 경보 docs-api-5xx: AWS/ApplicationELB의 HTTPCode_Target_5XX_Count, Sum, 60초, 1회 평가, 5 이상, 결측치는 notBreaching.

## 5. API 동작

| 요청 | 결과 |
| --- | --- |
| GET /health | 200 / {"status":"ok"} |
| POST /documents / {"title":"practice"} | 201 / {"doc_id":"생성된 UUID"} |
| GET /documents/생성된UUID | 200 / doc_id와 title |
| GET /documents/missing | 404 / {"error":"not found"} |
| POST /documents / {} 또는 빈 제목 | 400 / {"error":"invalid title"} |

ALB 주소로 테스트합니다. 유효한 요청을 10회 보내도 정상 응답해야 합니다. 서비스 안정화 후 두 타깃이 healthy여야 합니다.

## 6. 배점

자동 항목은 각 2점이며, 각 항목에 묶인 조건을 모두 만족해야 해당 2점을 얻습니다. 자동 스크립트가 AccessDenied 또는 API 오류를 보고하면 0점으로 확정하지 말고 교사가 재확인합니다.

| 자동 항목 | 배점 |
| --- | --- |
| VPC CIDR, 네 서브넷의 CIDR·AZ | 4 |
| 두 NAT가 available, DynamoDB endpoint가 두 Private RT에 연결 | 4 |
| DynamoDB 키·용량, PITR | 4 |
| ECR 불변성·스캔·v1 이미지 | 2 |
| ECS 서비스 Desired/Running 2 이상·두 지정 Private 서브넷·Public IP 비활성 | 2 |
| Fargate·awsvpc·CPU·메모리·Linux X86_64·circuit breaker·rollback | 2 |
| 컨테이너 포트·환경 변수 | 2 |
| ALB·HTTP listener·지정 TG 연결 | 2 |
| IP TG·포트·health path·정상 타깃 2개 | 2 |
| awslogs 연결·로그 보관 기간 | 2 |
| Auto Scaling 설정 | 2 |
| 5xx 경보 설정·ALB/TG dimensions | 2 |
| 자동 소계 | 30 |

| 교사 실기 항목 | 평가 방법과 부분점수 | 배점 |
| --- | --- | --- |
| 경로·보안 | 두 Public RT의 IGW 경로 1, 각 Private RT의 같은 AZ NAT 경로 1, 두 SG 인바운드가 지정 규칙만 허용 2 | 4 |
| IAM·태그 | 두 역할 분리·신뢰 정책 1, Task Role의 테이블 최소 권한 2, 주요 리소스 태그 1 | 4 |
| API | health 1, 생성 201 및 UUID 1, 조회 값 일치 1, 없는 ID 404 1, 잘못된 제목 400 1, 10회 정상 응답 1 | 6 |
| 복구·관측 | 실행 Task 하나를 중지한 뒤 desired 2 복구·healthy 2 확인 2, 생성 요청 로그 조회 1, 키가 이미지·환경 변수에 없음 확인 1 | 4 |
| 정리 계획 | 리소스 삭제 순서와 비용이 남는 리소스(NAT·EIP·ECR·로그) 목록 제출 | 2 |
| 교사 소계 | 실제 관찰한 항목만 인정 | 20 |
| 총점 | 자동 30 + 교사 20 | 50 |

Task 중지 테스트는 교사가 응시자에게 알린 후 해당 docs-api 서비스의 Task 한 개에만 수행합니다. 별도 서비스에는 수행하지 않습니다.

## 부록: 제공 코드

app.py

```python
import os
import uuid
import boto3
from flask import Flask, request

app = Flask(__name__)
table = boto3.resource("dynamodb", region_name=os.environ["AWS_REGION"]).Table(os.environ["TABLE_NAME"])

@app.get("/health")
def health():
    return {"status": "ok"}

@app.post("/documents")
def create():
    body = request.get_json(silent=True)
    title = body.get("title") if isinstance(body, dict) else None
    if not isinstance(title, str) or not title.strip():
        return {"error": "invalid title"}, 400
    doc_id = str(uuid.uuid4())
    table.put_item(Item={"doc_id": doc_id, "title": title})
    print("document_created", doc_id, flush=True)
    return {"doc_id": doc_id}, 201

@app.get("/documents/<doc_id>")
def get(doc_id):
    item = table.get_item(Key={"doc_id": doc_id}, ConsistentRead=True).get("Item")
    return item if item else ({"error": "not found"}, 404)
```

requirements.txt

```text
Flask>=3.0,<4
boto3>=1.35,<2
gunicorn>=22,<24
```

앱 실행 명령은 gunicorn --bind 0.0.0.0:8080 --workers 2 app:app 입니다. 빌드 시 실제 설치 버전을 기록합니다.

## 응시 후 정리

ECS Desired를 0으로 낮추고 서비스를 삭제합니다. ALB·TG, ECS 관련 Auto Scaling·경보, 클러스터, ECR 이미지·저장소, DynamoDB, 로그, endpoint, NAT·EIP, 서브넷·라우팅·IGW·VPC, 실습용 IAM 역할 순서로 정리합니다. ENI 해제 완료를 기다립니다.
