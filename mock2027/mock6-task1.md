# 2027 지방대회 대비 모의고사 6회 · 제1과제

| 항목 | 조건 |
| --- | --- |
| 과제명 | Private asynchronous report worker |
| 난이도 / 시간 / 배점 | 상 / 4시간 / 50점 |
| 리전 | 서울 ap-northeast-2 |
| 채점 | 교사 실기 평가 50점 |
| 출제 구분 | 자체 제작 연습문제. 제2과제와 독립적으로 응시 |

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
