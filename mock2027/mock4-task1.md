# 2027 지방대회 대비 모의고사 4회 · 제1과제

| 항목 | 조건 |
| --- | --- |
| 과제명 | Secure multi-AZ container platform |
| 난이도 / 시간 / 배점 | 상 / 4시간 / 50점 |
| 리전 | 서울 ap-northeast-2 |
| 채점 | 교사 실기 평가 50점 |
| 과제 범위 | 자체 제작 연습문제. 제2과제와 독립적으로 응시 |

## 1. 시나리오

현장 장비 점검 결과를 기록하는 Inspect API를 구축합니다. 인터넷 사용자는 CloudFront를 통해서만 API에 접속합니다. ECS 작업은 인터넷 기본 경로 없이 두 가용 영역에서 실행되며, DynamoDB 접근은 작업 역할의 임시 자격 증명을 사용합니다. 잘못된 앱 버전을 배포하면 정상 버전으로 자동 복구되어야 합니다.

구성 흐름은 사용자 → CloudFront → ALB → ECS Fargate → DynamoDB입니다.

## 2. 네트워크와 접근 제어

| 리소스 | 이름 | CIDR / 가용 영역 |
| --- | --- | --- |
| VPC | inspect-vpc | 10.40.0.0/16 |
| Public A | inspect-pub-a | 10.40.0.0/24 / ap-northeast-2a |
| Public C | inspect-pub-c | 10.40.1.0/24 / ap-northeast-2c |
| Private A | inspect-app-a | 10.40.10.0/24 / ap-northeast-2a |
| Private C | inspect-app-c | 10.40.11.0/24 / ap-northeast-2c |

- Public은 IGW 기본 경로를 사용합니다. Private에는 NAT·IGW 기본 경로와 공인 IP가 없어야 합니다.
- ECR API, ECR DKR, CloudWatch Logs Interface Endpoint를 두 Private 서브넷에 배치하고 Private DNS를 활성화합니다. Endpoint SG의 TCP 443은 Task SG에서만 허용합니다.
- S3와 DynamoDB Gateway Endpoint를 두 Private 서브넷의 라우팅 테이블에 연결합니다.
- ALB SG의 TCP 80은 AWS 관리형 CloudFront origin-facing prefix list만 허용합니다. Task SG의 8080은 ALB SG만 허용합니다.
- ALB HTTP 리스너에서 지정한 Origin 검증 헤더가 일치할 때만 Target Group으로 전달합니다. 기본 동작은 고정 403입니다. 헤더 이름은 X-Inspect-Origin이고 값은 실습자가 임의로 생성합니다. 화면 캡처와 제출물에는 값을 가립니다.
- CloudFront inspect 배포에는 ALB를 사용자 지정 Origin으로 등록하고 동일한 헤더를 설정합니다. 이 실습의 Origin 프로토콜은 HTTP입니다. Viewer의 HTTP는 HTTPS로 리다이렉트하고, 모든 HTTP 메서드를 허용하며, API 응답 캐시는 비활성화합니다. 아래 API의 Idempotency-Key와 Content-Type 헤더가 Origin까지 전달되도록 설정합니다.

## 3. 애플리케이션과 데이터

언어는 자유입니다. 앱은 0.0.0.0:8080에서 실행하고, DynamoDB 테이블 이름은 TABLE_NAME 환경 변수로 받습니다. 테이블 inspect-records는 PK record_id(String), On-demand, PITR 활성화입니다.

| 요청 | 기대 결과 |
| --- | --- |
| GET /health | 200, {"status":"ok"} |
| POST /v1/inspections, Idempotency-Key: exam-01, 본문 {"device":"pump-1","result":"PASS"} | 처음 요청은 201, {"record_id":"exam-01","device":"pump-1","result":"PASS"} |
| 같은 키와 같은 유효 본문을 다시 POST | 200, 기존 레코드 반환 |
| 같은 키와 다른 유효 본문을 POST | 409, {"error":"key conflict"} |
| GET /v1/inspections/exam-01 | 200, 저장된 레코드 반환 |
| GET /v1/inspections/missing | 404, {"error":"not found"} |
| POST에서 키 누락, 잘못된 JSON 또는 필드 오류 | 400, {"error":"invalid input"} |

- 키는 영문·숫자·하이픈으로만 구성된 1~64자입니다. device는 앞뒤 공백을 제거한 후 1~80자의 문자열이며, result는 PASS 또는 FAIL입니다. 비교할 때는 앞뒤 공백을 제거한 device를 사용합니다.
- 동시 POST에서도 한 요청만 201이어야 합니다. DynamoDB 조건부 쓰기로 최초 생성 여부를 결정하고, 충돌이 발생하면 일관된 읽기로 기존 레코드를 확인합니다.
- 앱 역할의 데이터 권한은 inspect-records의 PutItem/GetItem으로 제한합니다. 실행 역할에는 ECR 이미지 가져오기 및 로그 권한을 부여합니다. 이미지나 환경 변수에 정적 AWS 키를 넣지 않습니다.

## 4. 배포·관측·장애 복구

| 항목 | 설정 |
| --- | --- |
| ECR | inspect-api, 태그 불변, push 시 기본 스캔, 정상 이미지 태그 v1 |
| ECS | Cluster inspect-cluster, Service inspect-api, task family inspect-api |
| Task | FARGATE / awsvpc, Linux x86_64, CPU 256, Memory 512 MiB, 컨테이너 이름 api |
| ALB | inspect-alb, internet-facing, HTTP 80, 두 Public 서브넷 |
| Target Group | inspect-api-tg, ip 유형, 8080, /health 200 |
| 서비스 | 두 Private 서브넷, Desired 2, Deployment circuit breaker 및 rollback 활성화 |
| 로그 | /inspect/api, awslogs, 보관 14일 |
| 경보 | inspect-unhealthy, ALB UnHealthyHostCount, Maximum, 60초, 연속 2회 1 이상, 결측치는 notBreaching |

- 정상 서비스는 서로 다른 AZ의 healthy 타깃 2개를 확보해야 합니다.
- 검증용 Task Definition revision은 정상 이미지와 역할을 유지하되 컨테이너 command를 변경해 시작 직후 종료되게 만듭니다. 시험 서비스에만 새 revision을 적용합니다. ECS 이벤트와 배포 상태에서 실패 감지 및 직전 정상 revision 복귀를 확인합니다. 실패를 수동으로 되돌리는 동작은 자동 복구 점수로 인정하지 않습니다.
- 로그에는 요청 경로·상태 코드와 오류 원인을 남깁니다. Origin 검증 값이나 AWS 자격 증명은 기록하지 않습니다.

## 5. 실기 평가표

| 영역 | 채점 항목 | 배점 |
| --- | --- | --- |
| 네트워크 | VPC·두 AZ 서브넷·라우팅 4, 다섯 Endpoint와 Private DNS/RT 연결 6 | 10 |
| 접근 제어 | CloudFront HTTPS·캐시·헤더 전달 3, ALB prefix list 및 헤더 검증·기본 403 4, Task SG 제한 2 | 9 |
| 배포와 IAM | ECR 설정 2, Task 사양·서비스와 healthy 타깃 2개 4, 역할 분리·테이블 최소 권한 3 | 9 |
| API | health·조회·없는 ID 3, 최초 생성과 재호출 4, 다른 본문 충돌 및 잘못된 입력 4, 새 키로 동일 요청 5건 동시 전송 시 201 한 건·200 네 건 3 | 14 |
| 운영 | 로그·보관·경보와 dimension 확인 4, 실패 revision의 자동 롤백과 정상 호출 회복 4 | 8 |
| 합계 | 교사 실기 점수 | 50 |

정상 요청과 실패 요청의 상태 코드·응답, Target Group 상태, ECS 배포 이벤트와 마지막 정상 revision을 증거로 제출합니다. 동시 검증에는 미사용 키를 사용합니다. 실기 채점 후 CloudFront를 비활성화하고 삭제한 뒤 ALB·ECS·Endpoint·데이터 저장소 등 본인 실습 자원을 정리합니다.

## 참고 자료

AWS CloudFront의 ALB 접근 제한: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/restrict-access-to-load-balancer.html
