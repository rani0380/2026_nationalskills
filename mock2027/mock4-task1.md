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

## 6. 로그·경보·자동 복구 확인하기

- 앱 로그에 요청 경로, 상태 코드, 오류 원인을 남깁니다. Origin 검증 값과 AWS 자격 증명은 기록하지 않습니다.
- `inspect-unhealthy` 경보를 만듭니다. ALB와 대상 그룹을 식별하는 dimension을 사용하고, 지표는 ALB의 `UnHealthyHostCount`입니다. 통계는 Maximum, 기간은 60초입니다. 연속 두 번 1 이상일 때 경보로 전환하고, 결측치는 `notBreaching`으로 처리합니다.
- 자동 복구 시험은 정상 배포가 안정된 뒤 합니다. 정상 이미지와 역할을 유지한 새 Task Definition revision을 만들고, 컨테이너가 시작 직후 종료하도록 command만 바꿉니다. 이 revision을 **시험 서비스에만** 적용합니다.
- ECS가 실패를 감지한 이벤트, 직전 정상 revision으로 복귀한 상태, 복귀 뒤 CloudFront API의 정상 응답을 확인합니다. 수동으로 되돌린 경우에는 자동 복구 점수를 받을 수 없습니다.

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
