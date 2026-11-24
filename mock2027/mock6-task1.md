# 2027 지방대회 대비 모의고사 6회 · 제1과제

| 항목 | 조건 |
| --- | --- |
| 과제명 | Private asynchronous report worker |
| 난이도 / 시간 / 배점 | 상 / 4시간 / 50점 |
| 리전 | 서울 ap-northeast-2 |
| 채점 | 교사 실기 평가 50점 |
| 출제 구분 | 자체 제작 연습문제. 제2과제와 독립적으로 응시 |

보충 개정: 2026. 11. 24. · 기존 4시간·50점과 리소스 이름을 유지하고 구현·검증 기준을 명확히 했습니다. 별도 보충 해설은 왼쪽 메뉴의 ‘6회 · 구현·검증 해설’에서 확인합니다.

## 1. 무엇을 만드나요?

여러 점검 결과를 큐로 받아 통계 보고서를 만드는 시스템입니다. 사용자는 S3에 원본 CSV를 올리고 SQS에 작업 메시지를 넣습니다. ECS 컨테이너가 메시지를 읽고 보고서를 만들며, 잘못된 메시지는 재시도 후 실패 큐로 이동합니다.

흐름은 **S3 원본 + SQS 작업 → ECS Fargate 작업자 → S3 보고서·DynamoDB 작업 상태**입니다. HTTP 서버와 로드 밸런서는 필요하지 않습니다.

같은 작업 메시지가 두 번 도착해도 같은 보고서를 사용하고, 작업이 성공한 뒤에만 큐에서 메시지를 지웁니다.

## 2. 네트워크와 데이터 준비

| 리소스 | 이름 | 필수 값 |
| --- | --- | --- |
| VPC | report-vpc | 10.60.0.0/16 |
| Private A / C | report-app-a / report-app-c | 10.60.10.0/24 / 10.60.11.0/24, 서울 A·C존 |
| S3 | report-data-<계정ID>-<비번호> | 서울, 공개 차단 4개, 버전 관리, SSE-S3 |
| DynamoDB | report-jobs | PK job_id(String), On-demand |
| SQS 원본 큐 | report-jobs | Standard, visibility 180초, SSE-SQS, long polling 20초 |
| SQS 실패 큐 | report-jobs-dlq | Standard, SSE-SQS, 보관 14일 |
| Redrive | 원본 → 실패 큐 | maxReceiveCount=3 |

Private 두 서브넷은 인터넷 기본 경로와 공인 IP가 없어야 합니다. ECR API·ECR DKR·CloudWatch Logs·SQS Interface Endpoint를 두 서브넷에 만들고 Private DNS를 켭니다. Endpoint 보안 그룹의 TCP 443은 작업자 보안 그룹만 허용합니다. S3·DynamoDB Gateway Endpoint는 두 서브넷의 라우팅 테이블에 연결합니다. 작업자 보안 그룹에는 인바운드 규칙을 추가하지 않습니다.

**콘솔 순서**는 VPC → VPC만 생성 → 서브넷 두 개 → 라우팅 테이블 연결 → 보안 그룹 → 엔드포인트입니다. S3, DynamoDB와 SQS에서는 위 이름과 설정을 입력합니다. S3 버킷 정책은 버킷·객체의 비 TLS 요청을 거부합니다.

## 3. 원본 파일과 메시지 형식

문제지 상단의 input.csv를 내려받아 S3의 inputs/input.csv에 올립니다. CSV는 UTF-8이며 헤더는 device,result입니다. 정상 파일의 내용은 아래와 같습니다.

```csv
device,result
pump-1,PASS
pump-2,FAIL
pump-3,PASS
pump-4,PASS
```

SQS 콘솔의 **메시지 전송 및 수신 → 메시지 전송**에서 아래 JSON을 보냅니다. 샘플 작업 파일의 source_version은 S3 원본 객체의 실제 VersionId로 바꿉니다. 계정ID는 본인 12자리 계정 ID, 비번호는 본인 번호입니다.

```json
{"job_id":"exam-001","source_key":"inputs/input.csv","source_version":"<원본 VersionId>"}
```

- job_id는 영문·숫자·하이픈 1~40자입니다. source_key는 inputs/ 아래 .csv 객체여야 합니다.
- 버킷은 환경 변수로 고정하고, 지정된 VersionId로 읽습니다. 메시지에 버킷·출력 키를 받아 사용하지 않습니다.
- 모든 데이터 행에 비어 있지 않은 device와 PASS 또는 FAIL인 result가 있어야 합니다. 빈 데이터, 잘못된 헤더, 잘못된 값은 실패로 처리합니다.
- 입력은 최대 100행, 파일 크기는 최대 64KiB입니다. 파일 크기는 읽기 전에 확인하고, 실제 읽는 양도 제한합니다.

## 4. 컨테이너 처리 규칙

Python 또는 자유 언어로 작업자를 작성합니다. Lambda 대신 ECS 컨테이너가 SQS를 직접 long polling해야 합니다. 한 Task는 메시지를 한 개씩 처리하고, 한 메시지는 30초 안에 끝나야 합니다.

1. 원본 CSV를 확인한 뒤 reports/<job_id>.json에 보고서를 저장합니다. 보고서에는 job_id, source_key, source_version, total, pass, fail을 넣습니다. 예제 파일 결과는 total=4, pass=3, fail=1입니다.
2. S3 조건부 쓰기 If-None-Match: *를 사용해 보고서가 없을 때만 저장합니다. 같은 job_id가 다시 들어오면 기존 보고서를 읽습니다. 원본 키·버전이 같으면 성공으로 처리하고, 다르면 충돌로 처리합니다. 병렬 Task가 동시에 처리해도 보고서 객체의 새 버전이 추가되지 않아야 합니다.
3. 성공한 보고서의 내용으로 report-jobs에 status=DONE, 원본 키·버전, report_key와 건수를 저장합니다. 같은 작업 재처리 시 값이 바뀌지 않아야 합니다. 충돌 작업은 기존 성공 기록을 덮어쓰지 않습니다.
4. S3 저장과 DynamoDB 기록이 성공한 경우에만 DeleteMessage합니다. 보고서는 있지만 DB 쓰기가 실패했다면 메시지를 남기고, 다음 처리에서 기존 보고서를 이용해 DB 기록을 완료합니다.
5. 잘못된 메시지·CSV·충돌은 로그에 이유를 남기고 메시지를 삭제하지 않습니다. 큐의 redrive 설정에 따라 DLQ로 이동하도록 합니다. 임의의 고정 성공 응답으로 처리하지 않습니다.
6. 기존 보고서를 확인한 뒤에도 DB 쓰기가 끝나기 전까지 메시지를 삭제하지 않습니다. 동일 job_id의 원본 조합은 실습 중 바꾸지 않습니다. 충돌 시험은 이미 성공한 job_id에 다른 원본 버전을 지정해 수행합니다.

## 5. ECS 배포와 운영

| 항목 | 설정 |
| --- | --- |
| ECR | report-worker, IMMUTABLE, push 시 기본 스캔, 이미지 v1 |
| ECS | Cluster report-cluster, Service report-worker, family report-worker |
| Task | FARGATE, awsvpc, Linux x86_64, CPU 256, Memory 512 MiB |
| 서비스 | Desired 2, 두 Private 서브넷, Public IP 비활성 |
| 환경 변수 | QUEUE_URL, BUCKET_NAME, TABLE_NAME=report-jobs, AWS_REGION=ap-northeast-2 |
| 로그 | /report/worker, awslogs, 보관 7일 |
| 경보 | report-dlq-visible, DLQ ApproximateNumberOfMessagesVisible, Maximum, 60초, 1회, 1 이상, notBreaching |

실행 역할은 ECR pull·로그 전송, Task 역할은 원본 큐 ReceiveMessage·DeleteMessage·GetQueueAttributes, 지정 버킷 inputs/* 읽기와 버전 읽기·reports/* 읽기 및 쓰기, 테이블 PutItem·GetItem에 필요한 권한으로 제한합니다. 버전 조회 및 객체 존재 확인에 필요한 버킷 ListBucket은 해당 버킷으로 제한할 수 있습니다. 정적 AWS 키를 넣지 않습니다.

**콘솔 순서**는 IAM 역할 → CloudWatch 로그 그룹 → ECR → CloudShell에서 이미지 빌드·push → ECS Task Definition → 클러스터와 서비스입니다. 앱은 계속 실행되는 작업자이며 HTTP 포트 매핑은 필요하지 않습니다. 언어별 Dockerfile과 앱 코드는 직접 작성합니다.

## 6. 실기 검증과 배점

1. 정상 메시지를 보내고 보고서 4/3/1 및 DB DONE을 확인합니다.
2. 같은 메시지를 두 번 더 전송한 뒤 보고서 버전 수가 1인지, 작업 기록과 합계가 같은지 확인합니다.
3. 실패 메시지로 존재하지 않는 원본 버전, 잘못된 CSV, 성공 job_id와 다른 원본 조합을 각각 보냅니다. DLQ 이동은 visibility와 재시도를 고려해 최대 15분 관찰합니다.
4. 작업자 Task 한 개를 중지하고 서비스가 다시 두 개로 복구되는지 확인합니다. 시험 서비스 외 Task는 중지하지 않습니다.
5. 실제 DLQ 메시지를 유지한 상태에서 경보 ALARM과 실패 로그를 확인합니다.

| 영역 | 확인할 항목 | 배점 |
| --- | --- | --- |
| 네트워크 | VPC·두 서브넷·Private 경로 4, Endpoint·DNS·SG 6 | 10 |
| 데이터·큐 | 버킷·테이블 4, 큐 암호화·대기·visibility·DLQ 6 | 10 |
| 작업 처리 | 원본 버전·검증·집계 5, 조건부 보고서·중복 처리 6, DB 후 메시지 삭제·실패 재시도 5 | 16 |
| 배포·권한 | ECR·Task·서비스 5, 역할 분리·최소 권한 3 | 8 |
| 운영 | Task 복구 2, 로그·실제 DLQ 경보 4 | 6 |
| 합계 | 교사 실기 평가 | 50 |

요청 메시지, 보고서와 버전 목록, DB 항목, DLQ·경보, ECS 복구 화면을 제출합니다. 평가 후 서비스 Desired를 0으로 낮추고 ECS·ECR·Endpoint·큐·버킷 버전·테이블·실습 역할을 정리합니다.

## 참고 자료

S3 조건부 쓰기: https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html

SQS visibility timeout: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html

## 7. 보충: 시작 전 변수와 네트워크 점검

| 변수 | 예시·확인 방법 |
| --- | --- |
| 계정ID | CloudShell에서 aws sts get-caller-identity의 Account 값 |
| 비번호 | 1~6자리 숫자. 버킷 이름에 쓴 값을 끝까지 유지 |
| 원본 버전 | 업로드 응답의 VersionId. 문자열 null 또는 빈 값은 사용하지 않음 |
| QUEUE_URL | 원본 큐 report-jobs의 URL. DLQ URL과 혼동하지 않음 |
| BUCKET_NAME | report-data-계정ID-비번호 |
| TABLE_NAME | report-jobs |

VPC의 DNS resolution과 DNS hostnames를 모두 켭니다. 두 Private 라우팅 테이블에는 VPC local 경로와 S3·DynamoDB prefix-list 경로가 있어야 하며, IPv4 0.0.0.0/0 및 IPv6 ::/0 인터넷 경로가 없어야 합니다. Interface Endpoint는 각 서비스별 하나를 만들고 그 안에 두 AZ의 서브넷을 선택합니다.

| Endpoint 서비스 이름 | 유형 | 용도 |
| --- | --- | --- |
| com.amazonaws.ap-northeast-2.ecr.api | Interface | ECR 인증·이미지 메타데이터 |
| com.amazonaws.ap-northeast-2.ecr.dkr | Interface | 이미지 pull |
| com.amazonaws.ap-northeast-2.logs | Interface | awslogs 전송 |
| com.amazonaws.ap-northeast-2.sqs | Interface | 작업 long polling·삭제 |
| com.amazonaws.ap-northeast-2.s3 | Gateway | 원본·보고서·ECR 이미지 레이어 읽기 |
| com.amazonaws.ap-northeast-2.dynamodb | Gateway | 작업 기록 |

작업자 SG의 outbound는 Endpoint SG TCP 443, S3 및 DynamoDB의 관리형 prefix list TCP 443을 허용합니다. Endpoint SG의 inbound는 작업자 SG TCP 443만 허용합니다. SG와 네트워크 ACL의 차이를 구분하고, 사용자 정의 ACL을 쓴다면 응답 포트도 허용합니다.

S3 Gateway Endpoint 정책을 실습 버킷으로만 제한하면 ECR 이미지 레이어를 받을 수 없습니다. 실습 버킷과 함께 서울 ECR 레이어 저장소 prod-ap-northeast-2-starport-layer-bucket의 GetObject 경로를 허용하거나, Endpoint 정책 기본값으로 먼저 동작을 확인합니다. 실제 데이터 접근 범위는 IAM과 버킷 정책으로 제한합니다.

컨테이너 실행 시 pip 설치·운영체제 패키지 다운로드를 하지 않습니다. 인터넷이 있는 빌드 환경에서 의존성을 이미지에 포함하고 ECR로 push한 뒤 Task를 시작합니다. ECR은 직접 push한 일반 저장소를 사용하며 pull-through cache의 첫 외부 다운로드에 의존하지 않습니다.

## 8. 보충: 메시지·CSV·중복 처리 판정

- SQS body는 JSON 객체여야 합니다. 필수 필드 세 개는 문자열이며 job_id는 정규식 ^[A-Za-z0-9-]{1,40}$를 만족해야 합니다.
- source_key는 inputs/로 시작하고 .csv로 끝나야 합니다. source_version은 빈 값·null을 거부합니다. 메시지의 버킷·출력 키 필드를 실행 대상으로 사용하지 않습니다.
- CSV 헤더는 순서까지 device,result와 일치해야 합니다. 데이터는 1~100행입니다. 초과 열·누락 열·빈 행·빈 device·PASS/FAIL 이외 값은 실패입니다. device의 앞뒤 공백은 제거할 수 있으나 result는 대소문자를 바꾸어 인정하지 않습니다.
- HeadObject에 VersionId를 지정해 ContentLength가 65536 이하인지 먼저 확인합니다. GetObject에도 같은 VersionId를 지정하고 최대 65537바이트만 읽어 제한 초과를 다시 확인합니다. UTF-8 디코딩 오류는 실패입니다.
- 입력 파일의 추가 업로드로 latest가 바뀌더라도 이미 보낸 메시지는 지정된 과거 버전을 읽어야 합니다.

중복 처리의 기준 데이터는 S3 보고서입니다. 작업을 받으면 reports/job_id.json을 조회하고, 존재하면 원본 키·버전을 대조합니다. 보고서가 없다면 지정 버전의 CSV를 검증·집계한 뒤 조건부 저장합니다.

| 상황 | 처리 | 메시지 삭제 |
| --- | --- | --- |
| 보고서 없음, 조건부 저장 성공 | 새 보고서를 기준으로 DB DONE 기록 | DB 성공 후 |
| 조건부 저장 412 PreconditionFailed | 다른 Task가 만든 기존 보고서를 읽고 원본 대조 | 같은 원본이며 DB 성공 후 |
| 조건부 저장 409 ConditionalRequestConflict | 짧은 backoff 후 조건부 저장·기존 객체 확인을 제한 횟수만 재시도 | 성공 확정 전에는 삭제 안 함 |
| 보고서는 있으나 DB 기록 누락 | 기존 보고서 값으로 DB 재기록 | DB 성공 후 |
| 같은 job_id, 다른 원본 버전 | JOB_CONFLICT 로그. 기존 보고서·DB를 변경하지 않음 | 삭제 안 함 |
| 접근 거부·네트워크·파싱 오류 | 오류 종류를 기록하고 재시도에 맡김 | 삭제 안 함 |

403 AccessDenied를 ‘객체 없음’으로 바꿔 처리하지 않습니다. ListBucket을 부여한다면 s3:prefix를 inputs/*와 reports/*로 제한하여, 해당 prefix의 없는 객체와 권한 오류를 구분할 수 있게 합니다. 충돌을 확인하려고 보고서를 삭제하거나 새 버전을 덮어쓰면 중복 방지 점수를 인정하지 않습니다.

DynamoDB 기록은 보고서에 저장된 값으로만 만듭니다. DB가 일시 실패했을 때 보고서를 삭제해 보상하려 하지 않습니다. 원본 메시지는 최대 30초 내 처리하고 ReceiveMessage의 WaitTimeSeconds=20, MaxNumberOfMessages=1을 사용합니다. poll 대기는 처리 시간에 포함하지 않습니다.

## 9. 보충: 재현 가능한 시험과 기대 결과

시험 중 ECS 서비스 두 Task가 RUNNING인 것을 먼저 확인합니다. DLQ에 들어간 메시지는 경보와 증거 수집을 마친 뒤 정리합니다.

| 시험 | 준비·동작 | 합격 결과 |
| --- | --- | --- |
| 정상 처리 | input.csv의 실제 VersionId로 exam-001 전송 | 보고서 total=4/pass=3/fail=1, DB DONE |
| 원본 버전 고정 | 같은 키에 invalid.csv를 새 버전으로 업로드한 뒤, 새 job_id와 최초 정상 VersionId 전송 | 정상 4/3/1. latest를 읽지 않음 |
| 동시 중복 | exam-001 정상 메시지 두 개를 연속 전송 | 동일 보고서·DB 유지. 해당 보고서의 실제 객체 버전 1개 |
| DB 실패 후 복구 | 교사가 전용 Task Role의 테이블 PutItem만 일시 거부하고 새 job_id 실행. 보고서 생성 후 거부 해제 | DB 복구 후 DONE 및 큐 삭제. 보고서 버전은 1개 |
| 없는 버전 | 존재하지 않는 source_version을 새 job_id로 전송 | 성공 보고서·DONE 없음. DLQ 이동 |
| CSV 오류 | invalid.csv의 실제 VersionId를 새 job_id로 전송 | 검증 실패·DLQ 이동 |
| job_id 충돌 | 성공한 exam-001에 다른 원본 버전 지정 | 기존 보고서·DB 유지, 충돌 메시지 DLQ 이동 |
| Task 복구 | 교사가 report-worker Task 한 개 중지 | 서비스가 새 Task를 만들어 RUNNING 2 복구 |

DB 장애 시험은 교사가 실습 전용 역할에만 짧게 수행합니다. 원래 정책을 별도 저장하고 시험 직후 복원합니다. IAM 반영 지연과 visibility 180초를 고려해 최대 15분 관찰하며, 다른 서비스·테이블 권한은 변경하지 않습니다.

## 10. 보충: 채점 증거와 시간 배분

| 권장 시간 | 작업 |
| --- | --- |
| 0~50분 | VPC·Endpoint·S3·DynamoDB·SQS |
| 50~140분 | 작업자 구현·이미지 빌드·권한·ECS |
| 140~205분 | 정상·중복·충돌·DB 복구 시험 |
| 205~240분 | DLQ·경보·Task 복구·증거 정리 |

기존 50점 배점을 그대로 적용합니다. ‘작업 처리 16점’은 원본 버전·검증·집계 5점, 조건부 쓰기·동시 중복·충돌 보존 6점, DB 성공 후 삭제·실패 복구 5점으로 평가합니다. 설정 화면만으로 동작 점수를 대체하지 않습니다.

제출 폴더에는 worker 소스·Dockerfile·의존성 버전, 계정·비번호와 원본 VersionId 목록, 정상/중복/실패 요청, 보고서 JSON·버전 목록, DB 조회, DLQ 메시지·경보 이력, Task 교체 전후를 넣습니다. 정적 키·세션 토큰·로그인 비밀번호는 제출하지 않습니다.

## 보충 참고

ECR PrivateLink와 S3 레이어 경로: https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html

ECS Private 연결: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/networking-connecting-vpc.html
