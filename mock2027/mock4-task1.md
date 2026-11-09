# 2027 지방대회 대비 모의고사 4회 · 제1과제

| 항목 | 조건 |
| --- | --- |
| 과제명 | Secure multi-AZ container platform |
| 난이도 / 시간 / 배점 | 상 / 4시간 / 50점 |
| 리전 | 서울 ap-northeast-2 |
| 채점 | 교사 실기 평가 50점 |
| 과제 범위 | 자체 제작 연습문제. 제2과제와 독립적으로 응시 |

## 1. 무엇을 만드나요?

공장의 펌프나 장비를 점검한 뒤 결과를 저장하는 웹 API를 만듭니다. 예를 들어 사용자가 “pump-1 점검 결과는 PASS”라고 보내면, 서버가 결과를 저장하고 나중에 다시 조회할 수 있어야 합니다.

요청은 **사용자 → CloudFront → ALB → ECS → DynamoDB** 순서로 이동합니다. 사용자는 CloudFront 주소로 접속하고, ALB는 요청을 실행 중인 컨테이너에 전달합니다. 컨테이너는 DynamoDB에 결과를 저장합니다.

시험에서 확인할 동작은 세 가지입니다.

1. 사용자가 CloudFront 주소로 점검 결과를 저장하고 조회할 수 있습니다.
2. 같은 접수 번호로 요청이 여러 번 와도 기록이 하나만 남습니다.
3. 잘못된 버전을 배포하면 ECS가 직전 정상 버전으로 돌아갑니다.

아래 순서로 요구사항을 확인하세요. 리소스 이름과 숫자는 표에 나온 값을 사용합니다.

**콘솔에서 시작하기**  
AWS 콘솔 오른쪽 위에서 **아시아 태평양(서울)**을 선택합니다. 콘솔 검색창에서 VPC, DynamoDB, IAM, ECR, ECS, EC2, CloudFront, CloudWatch를 검색해 각 서비스를 엽니다. CloudFront는 전역 서비스입니다. 앱 코드는 직접 작성하고, 이미지 빌드와 API 호출 시험은 콘솔에서 열 수 있는 CloudShell을 사용합니다.

## 2. 네트워크 만들기

VPC는 실습에 사용할 네트워크입니다. 서울의 A·C 가용 영역에 서브넷을 두 개씩 만듭니다.

| 리소스 | 이름 | CIDR | 가용 영역 |
| --- | --- | --- | --- |
| VPC | inspect-vpc | 10.40.0.0/16 | 서울 |
| Public | inspect-pub-a | 10.40.0.0/24 | ap-northeast-2a |
| Public | inspect-pub-c | 10.40.1.0/24 | ap-northeast-2c |
| Private | inspect-app-a | 10.40.10.0/24 | ap-northeast-2a |
| Private | inspect-app-c | 10.40.11.0/24 | ap-northeast-2c |

- **Public 서브넷 두 곳**에는 ALB를 둡니다. 기본 경로는 Internet Gateway(IGW)로 연결합니다.
- **Private 서브넷 두 곳**에는 ECS 컨테이너를 둡니다. NAT나 IGW로 가는 기본 경로를 만들지 않고, 컨테이너에 공인 IP를 할당하지 않습니다.

Private 서브넷에서 AWS 서비스로 연결하려면 VPC Endpoint를 사용합니다. 아래 다섯 개를 만드세요.

| Endpoint 종류 | 대상 서비스 | 연결 조건 |
| --- | --- | --- |
| Interface 3개 | ECR API, ECR DKR, CloudWatch Logs | 두 Private 서브넷에 배치, Private DNS 활성화, Endpoint 보안 그룹의 TCP 443은 Task 보안 그룹만 허용 |
| Gateway 2개 | S3, DynamoDB | 두 Private 서브넷의 라우팅 테이블에 연결 |

ECR은 컨테이너 이미지를 가져올 때, S3는 ECR 이미지 레이어를 내려받을 때, CloudWatch Logs는 로그를 보낼 때 사용합니다.

### 콘솔에서 어디를 누르나요?

1. **VPC → VPC → VPC 생성**에서 **VPC만**을 선택합니다. 이름과 CIDR을 입력한 뒤, VPC를 선택해 **작업 → VPC 설정 편집**에서 DNS 확인과 DNS 호스트 이름을 활성화합니다.
2. **VPC → 서브넷 → 서브넷 생성**에서 위 표의 네 서브넷을 추가합니다. Private 두 곳은 **서브넷 설정 편집**에서 공인 IPv4 자동 할당을 끕니다.
3. **인터넷 게이트웨이**에서 IGW를 만들고 `inspect-vpc`에 연결합니다. **라우팅 테이블**에서 Public용 테이블에 `0.0.0.0/0 → IGW`를 추가하고, **서브넷 연결**에서 Public 두 곳을 연결합니다. Private 두 곳에도 별도의 Private용 테이블을 명시적으로 연결합니다. 이 테이블에는 인터넷 기본 경로를 추가하지 않습니다.
4. **보안 그룹**에서 ALB용, Task용, Endpoint용 그룹을 같은 VPC에 만듭니다. ALB용 80의 소스는 CloudFront 관리형 prefix list(`com.amazonaws.global.cloudfront.origin-facing`), Task용 8080의 소스는 ALB용 그룹, Endpoint용 443의 소스는 Task용 그룹을 선택합니다.
5. **VPC → 엔드포인트 → 엔드포인트 생성**에서 AWS 서비스를 선택합니다. Interface 세 개는 A·C Private 서브넷과 Endpoint용 그룹을 선택하고 **DNS 이름 활성화**를 확인합니다. Gateway 두 개는 Private 두 서브넷에 연결된 라우팅 테이블을 선택합니다. 생성 뒤 Endpoint 상태와 라우팅 테이블 연결을 확인합니다.

## 3. 점검 결과 저장 기능 만들기

사용 언어는 자유입니다. 앱은 `0.0.0.0:8080`에서 실행하고 테이블 이름은 `TABLE_NAME` 환경 변수로 읽습니다. DynamoDB 테이블 이름은 `inspect-records`입니다. 파티션 키는 `record_id`(String), 용량 모드는 On-demand, PITR은 활성화합니다.

### 입력값과 접수 번호

- `Idempotency-Key`는 요청에 붙이는 **접수 번호**입니다. 영문·숫자·하이픈만 사용하고 길이는 1~64자입니다. 이 값을 `record_id`로 저장합니다.
- `device`는 장비 이름입니다. 앞뒤 공백을 제거한 뒤 1~80자인 문자열이어야 합니다. 저장과 비교 모두 이 값을 사용합니다.
- `result`는 점검 결과입니다. `PASS` 또는 `FAIL`을 사용합니다.

POST 요청 예시입니다. 헤더에는 `Idempotency-Key: exam-01`을 넣습니다.

```json
{"device":"pump-1","result":"PASS"}
```

### 어떤 응답이 나와야 하나요?

| 시험할 요청 | 상태 코드 | 응답 본문 |
| --- | --- | --- |
| GET /health | 200 | {"status":"ok"} |
| POST /v1/inspections · exam-01을 처음 전송 | 201 | {"record_id":"exam-01","device":"pump-1","result":"PASS"} |
| 같은 접수 번호와 같은 유효 본문을 다시 POST | 200 | 처음 저장한 레코드 |
| 같은 접수 번호에 다른 유효 본문을 POST | 409 | {"error":"key conflict"} |
| GET /v1/inspections/exam-01 | 200 | 저장된 레코드 |
| GET /v1/inspections/missing | 404 | {"error":"not found"} |
| 키 누락, 잘못된 JSON 또는 필드 오류가 있는 POST | 400 | {"error":"invalid input"} |

DynamoDB에서 **해당 접수 번호가 없을 때만 저장**하는 조건부 쓰기를 사용합니다. 이미 저장되어 조건부 쓰기가 실패하면 일관된 읽기로 기존 내용을 확인합니다. 같은 내용이면 기존 값을 반환하고, 다른 내용이면 충돌로 응답합니다. 요청이 동시에 들어와도 최초 생성에 성공한 한 건만 201을 반환해야 합니다.

### DynamoDB 콘솔에서 테이블 준비하기

**DynamoDB → 테이블 → 테이블 생성**에서 `inspect-records`와 파티션 키 `record_id`(문자열)를 입력합니다. 생성 화면의 용량 모드에서 On-demand를 선택하거나 생성 뒤 테이블의 용량 설정에서 확인합니다. **백업 → 지정 시간 복구(PITR) 편집**에서 복구를 활성화합니다. 앱에서는 위 API 조건에 맞춰 이 테이블을 사용합니다.

## 4. 컨테이너 배포하기

| 항목 | 필수 설정 |
| --- | --- |
| ECR 저장소 | inspect-api, 태그 불변, push 시 기본 스캔, 정상 이미지 태그 v1 |
| ECS 클러스터 | inspect-cluster |
| 서비스 / Task family | 둘 다 inspect-api |
| Task 사양 | FARGATE, awsvpc, Linux x86_64, CPU 256, 메모리 512 MiB, 컨테이너 이름 api |
| 서비스 | 두 Private 서브넷, 공인 IP 비활성, Desired 2, Deployment circuit breaker 및 rollback 활성화 |
| 로그 | awslogs 드라이버, /inspect/api 로그 그룹, 보관 14일 |

ECS에서 사용하는 IAM 역할을 두 개로 나눕니다. **실행 역할**은 ECS가 ECR에서 이미지를 가져오고 로그를 보낼 때 사용합니다. **Task 역할**은 앱이 `inspect-records` 테이블에 `PutItem`과 `GetItem`을 할 때 사용합니다. Task 역할의 데이터 권한은 이 테이블과 두 작업으로 제한합니다. 이미지나 환경 변수에 정적 AWS 키를 넣지 않습니다.

### 콘솔에서 이미지와 Task Definition 준비하기

1. **CloudWatch → 로그 그룹 → 로그 그룹 생성**에서 `/inspect/api`를 만들고 보관 기간을 14일로 설정합니다.
2. **IAM → 역할 → 역할 생성**에서 신뢰 서비스로 **Elastic Container Service Task**를 선택합니다. 실행 역할에는 `AmazonECSTaskExecutionRolePolicy`를 연결할 수 있습니다. Task 역할에는 IAM의 **인라인 정책 생성**에서 지정 테이블 ARN에 대한 DynamoDB `PutItem`과 `GetItem`만 추가합니다. 두 역할의 신뢰 주체는 `ecs-tasks.amazonaws.com`입니다.
3. **ECR → 프라이빗 리포지토리 → 리포지토리 생성**에서 `inspect-api`와 태그 불변을 설정합니다. 스캔 설정에서 이 저장소가 기본 스캔의 push 시 검사 대상인지 확인합니다. 저장소의 **푸시 명령 보기**에서 계정에 맞는 이미지 URI를 확인할 수 있습니다.
4. **Python·Flask로 작성했다면** 문제지 상단의 **Dockerfile 다운로드**를 이용합니다. 확장자 없는 `Dockerfile`과 직접 작성한 `app.py`, `requirements.txt`를 CloudShell의 같은 폴더에 둡니다. `app.py`는 Flask 앱 객체를 `app`이라는 이름으로 노출해야 합니다. 다른 소스 파일을 import하는 구조라면 Dockerfile에 해당 파일을 복사하는 줄을 추가합니다. 다른 언어를 사용한 경우 실행 방식에 맞는 Dockerfile을 작성합니다.

`requirements.txt`에는 앱에서 사용하는 라이브러리와 서버 실행에 필요한 패키지를 적습니다. Flask로 API를 만들고 boto3로 DynamoDB를 사용하는 경우 아래와 같습니다.

```text
Flask
boto3
gunicorn
```

CloudShell에서 Dockerfile만 직접 내려받으려면 앱 폴더에서 아래 명령을 실행합니다.

```bash
curl -fL 'https://rani0380.github.io/2026_nationalskills/downloads/mock2027/mock4-task1/Dockerfile' -o Dockerfile
```

세 파일이 준비되면 같은 폴더에서 아래 명령으로 이미지를 빌드하고 ECR에 업로드합니다. 제공 Dockerfile의 Gunicorn은 컨테이너 안에서 `0.0.0.0:8080`으로 요청을 받습니다.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT_ID.dkr.ecr.ap-northeast-2.amazonaws.com"
IMAGE="$REGISTRY/inspect-api:v1"
aws ecr get-login-password --region ap-northeast-2 |
  docker login --username AWS --password-stdin "$REGISTRY"
docker build --platform linux/amd64 -t "$IMAGE" .
docker push "$IMAGE"
printf '%s\n' "$IMAGE"
```

5. **ECS → 클러스터 → 클러스터 생성**에서 `inspect-cluster`를 만듭니다. **ECS → 태스크 정의 → 새 태스크 정의 생성**에서 표의 Fargate 사양과 두 역할을 입력합니다. 컨테이너 이름은 `api`, 이미지 URI는 위 명령에서 출력한 값, 컨테이너 포트는 8080입니다. 환경 변수에 `TABLE_NAME=inspect-records`를 넣고 로그 드라이버는 `awslogs`, 리전은 서울, 로그 그룹은 앞서 생성한 그룹, 스트림 접두사는 예를 들어 `ecs`로 설정합니다.

## 5. 사용자가 접속할 경로 만들기

4단계에서 이미지와 Task Definition을 준비한 뒤 ALB와 대상 그룹을 만듭니다. ECS 서비스를 생성할 때 이 대상 그룹을 연결합니다. 마지막으로 CloudFront를 만들어 사용자가 접속할 주소를 준비합니다.

### ALB

1. `inspect-alb`를 두 Public 서브넷에 internet-facing으로 생성합니다. 리스너는 HTTP 80입니다.
2. `inspect-api-tg` 대상 그룹은 ip 유형과 포트 8080을 사용합니다. 상태 검사는 `/health`의 200 응답으로 확인합니다.
3. ALB 보안 그룹의 TCP 80은 AWS 관리형 CloudFront origin-facing prefix list만 허용합니다. Task 보안 그룹의 TCP 8080은 ALB 보안 그룹만 허용합니다.
4. ALB는 `X-Inspect-Origin` 헤더가 지정한 값과 일치할 때만 대상 그룹으로 전달합니다. 헤더 값은 직접 생성합니다. 리스너 기본 동작은 고정 응답 403으로 설정합니다.

### CloudFront

1. `inspect` 배포에서 ALB를 사용자 지정 Origin으로 등록합니다. 이 실습에서 CloudFront와 ALB 사이의 프로토콜은 HTTP입니다.
2. Origin에 ALB에서 지정한 것과 같은 `X-Inspect-Origin` 헤더와 값을 설정합니다. 이 값은 제출 화면과 캡처에서 가립니다.
3. 사용자의 HTTP 요청은 HTTPS로 리다이렉트합니다. 모든 HTTP 메서드를 허용하고 API 응답 캐시는 끕니다.
4. 요청의 `Idempotency-Key`와 `Content-Type` 헤더를 Origin까지 전달합니다.

배포가 끝나면 두 가용 영역에서 각각 하나씩, **healthy 타깃 2개**가 있는지 확인합니다. API 요청은 CloudFront 주소로 시험합니다.

### 콘솔에서 ALB·ECS·CloudFront를 연결하기

1. **EC2 → 대상 그룹 → 대상 그룹 생성**에서 대상 유형 **IP 주소**, VPC `inspect-vpc`, HTTP 8080, 상태 검사 경로 `/health`, 성공 코드 `200`을 지정합니다. 컨테이너 IP는 ECS 서비스가 등록합니다.
2. **EC2 → 로드 밸런서 → 로드 밸런서 생성 → Application Load Balancer**에서 Public 두 곳과 ALB용 보안 그룹을 지정합니다. **리스너 및 규칙 → HTTP:80**에서 기본 동작을 고정 403으로 편집하고, 별도 규칙에 **HTTP 헤더 조건 → X-Inspect-Origin**을 추가해 지정 값이 맞으면 `inspect-api-tg`로 전달합니다. ECS 서비스가 대상 그룹을 사용하려면 먼저 이 리스너 규칙으로 대상 그룹을 ALB와 연결해야 합니다.
3. **ECS → 클러스터 → inspect-cluster → 서비스 → 생성**에서 앞서 만든 태스크 정의와 Fargate, Desired 2를 선택합니다. **네트워킹**에서 Private 두 곳과 Task용 그룹을 선택하고 Public IP를 끕니다. **로드 밸런싱**에서 기존 ALB·HTTP:80·대상 그룹과 컨테이너 `api:8080`을 연결합니다. **배포 실패 감지**에서 ECS deployment circuit breaker와 Rollback on failures를 활성화합니다. 생성 후 ALB 기본 동작과 헤더 조건이 그대로 적용되는지 다시 확인합니다.
4. **CloudFront → 정책 → 원본 요청 → 정책 생성**에서 Origin에 보낼 헤더로 `Idempotency-Key`와 `Content-Type`을 포함합니다. **배포 → 배포 생성**에서 ALB의 DNS 이름을 사용자 지정 Origin으로 선택하고 Origin 프로토콜은 HTTP로 설정합니다. **사용자 지정 헤더 추가**에서 ALB 규칙의 이름과 값으로 설정합니다.
5. 배포의 **동작(Behaviors)**에서 Viewer protocol은 Redirect HTTP to HTTPS, 허용 메서드는 7개 모두, 캐시 정책은 `CachingDisabled`, 원본 요청 정책은 앞서 만든 정책을 선택합니다. 배포 완료 뒤 표시되는 CloudFront 도메인을 API 주소로 사용합니다.

## 6. 로그·경보·자동 복구 확인하기

- 앱 로그에 요청 경로, 상태 코드, 오류 원인을 남깁니다. Origin 검증 값과 AWS 자격 증명은 기록하지 않습니다.
- `inspect-unhealthy` 경보를 만듭니다. ALB와 대상 그룹을 식별하는 dimension을 사용하고, 지표는 ALB의 `UnHealthyHostCount`입니다. 통계는 Maximum, 기간은 60초입니다. 연속 두 번 1 이상일 때 경보로 전환하고, 결측치는 `notBreaching`으로 처리합니다.
- 자동 복구 시험은 정상 배포가 안정된 뒤 합니다. 정상 이미지와 역할을 유지한 새 Task Definition revision을 만들고, 컨테이너가 시작 직후 종료하도록 command만 바꿉니다. 이 revision을 **시험 서비스에만** 적용합니다.
- ECS가 실패를 감지한 이벤트, 직전 정상 revision으로 복귀한 상태, 복귀 뒤 CloudFront API의 정상 응답을 확인합니다. 수동으로 되돌린 경우에는 자동 복구 점수를 받을 수 없습니다.

### 콘솔에서 경보와 복구를 확인하기

- **CloudWatch → 경보 → 경보 생성 → 지표 선택 → ApplicationELB**에서 ALB와 대상 그룹이 모두 일치하는 `UnHealthyHostCount`를 고릅니다. 위의 통계·기간을 입력하고 **추가 구성**에서 2회 중 2회 및 결측치 처리 값을 확인합니다.
- **ECS → 태스크 정의 → inspect-api → 새 리비전 생성**에서 정상 리비전을 복사한 뒤 컨테이너 명령만 바꿉니다. 현재 시작 명령 구조에서 즉시 종료되는지 확인합니다. **ECS → 서비스 → 업데이트**에서 시험용 리비전을 선택합니다. **배포**와 **이벤트**에서 실패, 롤백, 정상 리비전을 확인하고 API를 다시 호출합니다.
- 타깃이 비정상이면 **EC2 → 대상 그룹 → 대상**의 상태 이유와 **ECS → 서비스 → 이벤트**를 함께 봅니다. 이미지 가져오기에 실패하면 ECR·S3 Endpoint와 실행 역할을, 상태 검사에 실패하면 포트·Task 보안 그룹·앱의 `/health`를 확인합니다.

## 7. 시험하기와 제출하기

1. CloudFront 주소에서 health, 새 접수 번호로 POST, 생성한 기록 조회, 없는 기록 조회를 차례대로 시험합니다.
2. 같은 접수 번호로 같은 내용과 다른 내용을 보내 각각 200과 409를 확인합니다. 잘못된 입력은 400을 확인합니다.
3. **아직 사용하지 않은 접수 번호**로 동일한 요청 다섯 건을 동시에 보냅니다. 201이 한 건, 200이 네 건이어야 합니다.
4. 각 시험의 상태 코드와 응답, Target Group의 healthy 상태, 배포 실패 및 복구 이벤트, 마지막 정상 revision을 채점 증거로 정리합니다. Origin 검증 헤더 값과 자격 증명은 가립니다.
5. 교사가 확정한 결과는 채점지 또는 이 페이지 하단의 양식에서 제출합니다.

## 실기 평가표

| 영역 | 채점 항목 | 배점 |
| --- | --- | --- |
| 네트워크 | VPC·두 AZ 서브넷·라우팅 4, 다섯 Endpoint와 Private DNS/RT 연결 6 | 10 |
| 접근 제어 | CloudFront HTTPS·캐시·헤더 전달 3, ALB prefix list 및 헤더 검증·기본 403 4, Task SG 제한 2 | 9 |
| 배포와 IAM | ECR 설정 2, Task 사양·서비스와 healthy 타깃 2개 4, 역할 분리·테이블 최소 권한 3 | 9 |
| API | health·조회·없는 ID 3, 최초 생성과 재호출 4, 다른 본문 충돌 및 잘못된 입력 4, 새 키로 동일 요청 5건 동시 전송 시 201 한 건·200 네 건 3 | 14 |
| 운영 | 로그·보관·경보와 dimension 확인 4, 실패 revision의 자동 롤백과 정상 호출 회복 4 | 8 |
| 합계 | 교사 실기 점수 | 50 |

채점 후 본인 실습 리소스를 정리합니다. CloudFront 배포를 비활성화하고 삭제한 뒤 ALB, ECS, Endpoint, 데이터 저장소를 정리하세요.

## 참고 자료

AWS CloudFront의 ALB 접근 제한: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/restrict-access-to-load-balancer.html

AWS CloudShell에서 이미지 빌드 및 ECR 푸시: https://docs.aws.amazon.com/cloudshell/latest/userguide/tutorial-docker-cli.html

ECS 콘솔에서 서비스와 롤백 설정: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/create-service-console-v2.html
