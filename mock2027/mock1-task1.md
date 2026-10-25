# 2027 지방대회 대비 모의고사 1회 · 제1과제

## 응시 방법

1. 타이머를 4시간으로 맞추고 시작합니다. 인터넷은 AWS 공식 문서만 참고합니다.
2. 과제를 마치면 Bastion(`cafe-bastion`)에서 페이지 하단의 채점 스크립트를 내려받아 실행합니다.
3. 출력 전체를 복사해 하단 제출 칸에 붙여넣고 제출합니다. 마지막 줄의 `TOTAL SCORE`가 점수입니다.
4. 채점이 끝나면 리소스를 모두 삭제합니다. NAT Gateway와 Aurora는 켜 둔 시간만큼 과금됩니다.

| 항목 | 내용 |
| --- | --- |
| 과제명 | Solution architecture |
| 경기시간 | 4시간 |
| 배점 | 50점 |
| 리전 | 서울(ap-northeast-2) |
| 채점 위치 | Bastion EC2 (`cafe-bastion`) |

## 1. 요구사항

당신은 커피 프랜차이즈 SkillsCafe의 주문 시스템을 AWS에 구축합니다. 주문 앱은 컨테이너로 배포하고, 주문 데이터는 Aurora MySQL에 저장합니다. 고가용성, 보안, 확장성, 운영 효율성을 고려해 인프라를 구성하세요.

| AWS | Language / Framework |
| --- | --- |
| VPC, EC2, ECR, ECS(Fargate), ALB, Aurora MySQL, Secrets Manager, KMS, CloudWatch, SNS | Python 3.12 / Flask, MySQL |

## 2. 선수 유의사항

1. 문제의 괄호 `< >`는 변수이므로 적절히 바꿔 사용합니다.
2. Security Group의 80/443 outbound는 anyopen해도 됩니다.
3. Bastion EC2는 채점에 사용하므로 종료되거나 접속·권한 문제가 생기지 않도록 합니다.
4. 모든 리소스는 서울(ap-northeast-2) 리전에 생성합니다.
5. 문제에 제시한 Name tag와 이름이 다르면 채점되지 않습니다.
6. 제공된 애플리케이션 코드(부록)는 수정하지 않습니다. Dockerfile은 직접 작성합니다.
7. 과제 종료 전 실행 중인 부하 테스트를 모두 중지합니다.

## 3. VPC

서비스용 VPC 하나를 A존과 C존에 나눠 구성합니다. Public 서브넷은 Internet Gateway로, App 서브넷은 AZ마다 따로 둔 NAT Gateway로 인터넷에 나갑니다. DB 서브넷은 인터넷 경로가 없어야 합니다. App 서브넷에서 Secrets Manager와 S3에 접근할 때는 인터넷을 거치지 않도록 VPC endpoint를 구성합니다. VPC Flow log는 CloudWatch Logs로 보냅니다.

- VPC Name tag: `cafe-vpc` / CIDR: `10.10.0.0/16`
- Internet Gateway: `cafe-igw` / NAT Gateway: `cafe-nat-a`, `cafe-nat-c`
- VPC endpoint: Secrets Manager(Interface, Private DNS 활성화), S3(Gateway)
- Flow log 대상 Log group: `/cafe/vpc/flowlog`

| Subnet Name tag | CIDR | AZ | Route table Name tag |
| --- | --- | --- | --- |
| cafe-pub-a | 10.10.0.0/24 | ap-northeast-2a | cafe-pub-rt |
| cafe-pub-c | 10.10.1.0/24 | ap-northeast-2c | cafe-pub-rt |
| cafe-app-a | 10.10.10.0/24 | ap-northeast-2a | cafe-app-rt-a |
| cafe-app-c | 10.10.11.0/24 | ap-northeast-2c | cafe-app-rt-c |
| cafe-db-a | 10.10.20.0/24 | ap-northeast-2a | cafe-db-rt |
| cafe-db-c | 10.10.21.0/24 | ap-northeast-2c | cafe-db-rt |

## 4. Bastion

채점용 Bastion을 만듭니다. 재시작해도 공인 IP가 바뀌지 않아야 하고, SSH는 기본 포트가 아닌 **2222**번으로 접속합니다. AWS CLI로 모든 리소스를 조회할 수 있도록 AdministratorAccess 역할을 붙입니다.

- Name tag: `cafe-bastion` / Instance type: `t3.micro` / AMI: Amazon Linux 2023
- Subnet: `cafe-pub-a` / Elastic IP 연결 / 종료 방지(Termination protection) 활성화
- Packages: awscli, curl, jq, docker, mariadb105(mysql 클라이언트)

## 5. Application

주문 앱은 Python/Flask로 개발되었고 8080 포트에서 동작합니다. 앱은 환경 변수 `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`을 읽어 DB에 접속하며, DB에 접속할 수 없으면 `/health`가 500을 반환합니다. 코드는 문서 끝의 부록에 있습니다.

| API | Request | Response |
| --- | --- | --- |
| POST /v1/orders | `{"menu": "latte", "qty": 2}` | `{"order_id": 1}` |
| GET /v1/orders | `?order_id=1` | `{"order_id": 1, "menu": "latte", "qty": 2}` |
| GET /health | - | `{"status": "ok"}` |

## 6. ECR

앱 이미지를 Private repository에 저장합니다. 업로드 시 취약점 스캔이 자동으로 실행되어야 하고, 같은 태그로 덮어쓸 수 없어야 하며, KMS로 암호화합니다. `v1.0.0` 태그 이미지를 하나 업로드합니다. 이미지 안에서 curl을 사용할 수 있어야 합니다.

- Repository name: `cafe-order` / Tag: `v1.0.0` (latest 태그 사용 금지)

## 7. ECS

앱을 ECS Fargate에 배포합니다. Task는 App 서브넷에만 배치하고 공인 IP를 할당하지 않습니다. DB 비밀번호는 Task definition에 평문으로 적지 않고, Secrets Manager의 값을 Task definition의 `secrets` 항목으로 주입합니다. 운영 중 컨테이너에 Shell로 들어갈 수 있도록 ECS Exec를 활성화합니다. CPU 평균 60%를 기준으로 Task 수가 자동 조절되어야 합니다.

- Cluster: `cafe-cluster` (Container Insights 활성화)
- Task definition: `cafe-order-td` / 0.5 vCPU, 1 GB / 로그 드라이버 awslogs
- Service: `cafe-order-svc` / Desired 2 / Min 2, Max 6 / Target tracking CPU 60%
- Security group: `cafe-app-sg` (ALB SG에서 8080만 허용)

## 8. ALB

Public 서브넷에 인터넷 대상 ALB를 구성합니다. `/v1/*`과 `/health` 요청만 앱으로 전달하고, 그 외 경로는 앱에 도달하지 않고 Fixed response 기능으로 HTTP 404와 본문 `not found`를 반환합니다.

- ALB name: `cafe-alb` / Scheme: internet-facing / Listener: HTTP 80
- Target group: `cafe-order-tg` / Target type: ip / Health check path: `/health`

## 9. Aurora MySQL

주문 데이터를 저장할 Aurora MySQL 클러스터를 DB 서브넷에 만듭니다. 한 가용영역에 장애가 나도 장애 조치되도록 Writer와 Reader를 서로 다른 AZ에 둡니다. 저장소는 CMK로 암호화하고, 실수로 삭제하지 못하게 하며, 기본 포트 3306 대신 **3307**을 사용합니다.

- DB cluster identifier: `cafe-db` / Engine: Aurora MySQL 8.0 호환 / Instance class: `db.t3.medium` × 2
- KMS key alias: `alias/cafe-db-key` / 삭제 방지 활성화 / 백업 보관 7일 / Public access 비활성화
- CloudWatch Logs로 error, slowquery 로그 내보내기

```sql
CREATE DATABASE cafe;
CREATE TABLE cafe.orders (
  order_id INT AUTO_INCREMENT PRIMARY KEY,
  menu VARCHAR(50) NOT NULL,
  qty INT NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

## 10. Secrets Manager

앱이 사용할 DB 접속 정보를 secret으로 저장합니다. Secret은 CMK로 암호화하고, 앱 계정은 master 사용자가 아닌 별도 사용자여야 하며 `cafe` DB에 대한 권한만 갖습니다.

- Secret name: `cafe/db-secret` / KMS key alias: `alias/cafe-secret-key`
- JSON keys: `username`, `password`, `host`, `port`, `dbname` (username은 `cafeapp`)

## 11. CloudWatch

앱 로그를 모으고, 이상 징후를 한 화면에서 보며, 에러가 급증하면 알림을 받습니다.

- App log group: `/cafe/ecs/order` / 보관 기간 14일
- Dashboard: `cafe-dashboard` / ALB RequestCount, ALB HTTPCode_Target_5XX_Count, ECS 서비스 CPUUtilization 위젯 포함
- Alarm: `cafe-5xx-alarm` / ALB HTTPCode_Target_5XX_Count가 5분 합계 10 이상이면 SNS topic `cafe-alert`로 알림

## 배점

| 번호 | 주요항목 | 세부항목 (배점) | 합계 |
| --- | --- | --- | --- |
| 1 | VPC | CIDR 1, 서브넷 6개 1.5, Route table 4개 1.5, AZ별 NAT 1.5, DB RT 인터넷 경로 없음 1.5, Secrets Manager endpoint 1.5, S3 endpoint 0.5, Flow log 1.5 | 10.5 |
| 2 | Bastion | EIP 1, SSH 2222 1.5, 종료 방지 1.5 | 4 |
| 3 | ECR | Repository·태그 1, Immutable 1, Scan on push 1, KMS 1 | 4 |
| 4 | ECS | Container Insights 1.5, Task 사양 1, secrets 주입 2, Service 1.5, ECS Exec 1.5, Auto scaling 1.5 | 9 |
| 5 | ALB | Scheme 1, Target group 1.5, Default 404 1.5, 경로 규칙 1 | 5 |
| 6 | Aurora | Engine 1, Multi-AZ 1.5, 포트 1, CMK 1.5, 삭제 방지 1, 로그 1 | 7 |
| 7 | Secrets Manager | CMK 1.5, 앱 계정 1.5 | 3 |
| 8 | Application | 주문 생성 1.5, 주문 조회 1.5, 비정상 경로 404 1 | 4 |
| 9 | CloudWatch | Log 보관 1, Dashboard 1.5, Alarm 1 | 3.5 |
|  | **합계** |  | **50** |

## 부록: 제공 애플리케이션 코드

app.py

```python
import os, pymysql
from flask import Flask, request, jsonify

app = Flask(__name__)

def db():
    return pymysql.connect(host=os.environ["DB_HOST"], port=int(os.environ.get("DB_PORT", 3306)),
                           user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"],
                           database=os.environ.get("DB_NAME", "cafe"), autocommit=True)

@app.get("/health")
def health():
    try:
        db().close()
        return {"status": "ok"}
    except Exception as e:
        print("health error:", e, flush=True)
        return {"status": "error"}, 500

@app.post("/v1/orders")
def create():
    body = request.get_json()
    with db() as c, c.cursor() as cur:
        cur.execute("INSERT INTO orders(menu, qty) VALUES(%s, %s)", (body["menu"], body["qty"]))
        oid = cur.lastrowid
    print("order created:", oid, flush=True)
    return {"order_id": oid}

@app.get("/v1/orders")
def get():
    with db() as c, c.cursor() as cur:
        cur.execute("SELECT order_id, menu, qty FROM orders WHERE order_id=%s", (request.args["order_id"],))
        row = cur.fetchone()
    if not row:
        return {"error": "not found"}, 404
    return jsonify(order_id=row[0], menu=row[1], qty=row[2])

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
```

requirements.txt

```text
flask==3.0.3
pymysql==1.1.1
```
