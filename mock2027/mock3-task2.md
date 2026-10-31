# 2027 지방대회 대비 모의고사 3회 · 제2과제

## 응시 방법

1. 제한 시간은 4시간, 총점은 50점입니다. 제1과제와 독립된 과제입니다.
2. 모든 리소스는 서울 ap-northeast-2에 만듭니다. AWS·Python 공식 문서를 참고할 수 있습니다.
3. 설정 자동 점검 30점과 교사 실기 평가 20점을 합산합니다. 자동 점검은 리소스를 생성·변경·삭제하지 않습니다.
4. CloudShell에서 스크립트에 비번호와 교사가 확정한 실기 점수를 입력해 실행하고 출력 전체를 제출합니다.
5. 자체 제작 연습문제입니다. 실제 대회의 공식 출제·채점 기준과는 다를 수 있습니다.

## 1. 공통 조건

SkillsDocs에 업로드된 문서 정보를 큐로 받아 처리하고, 복구 및 권한 체계를 구성합니다.

- <계정ID>는 현재 AWS 계정의 12자리 ID, <비번호>는 1~6자리 숫자입니다. S3 이름은 이 두 값을 모두 포함합니다.
- 이 세트 전용 계정을 사용하며 IAM 액세스 키를 새로 만들지 않습니다.
- 주요 리소스의 태그는 Project=SkillsDocs입니다.
- S3 버킷은 모두 퍼블릭 액세스 차단 4개를 활성화하고 버전 관리를 사용합니다.
- 기존 버킷·데이터·리소스를 삭제하거나 덮어쓰지 않습니다.

## 2. 문서 이벤트 처리 (20점)

| 리소스 | 요구사항 |
| --- | --- |
| S3 | docs-inbox-<계정ID>-<비번호> |
| 알림 | s3:ObjectCreated:* / prefix incoming/ / suffix .json / 대상 docs-events |
| SQS | Standard docs-events / visibility timeout 180초 / SSE-SQS |
| DLQ | Standard docs-events-dlq / retention 1209600초 / SSE-SQS |
| Redrive | docs-events에서 docs-events-dlq로 / maxReceiveCount=3 |
| Lambda | docs-indexer / Python 3.12 / timeout 30초 / memory 128 MiB |
| 환경 변수 | TABLE_NAME=docs-index |
| Event source mapping | Batch size 5 / Batch window 0 / ReportBatchItemFailures / Enabled |
| DynamoDB | docs-index / PK object_key(String) / On-demand |

직접 S3 알림을 받을 대상은 같은 리전의 Standard SQS입니다. 큐 정책은 s3.amazonaws.com의 SendMessage를 허용하되 SourceArn을 위 버킷으로, SourceAccount를 본인 계정으로 제한합니다.

문서 형식 예시:

```json
{"title":"network practice","owner":"student01"}
```

Lambda의 처리 규칙:

- SQS body 안의 S3 Records를 해석하고 URL 인코딩된 key를 디코딩합니다.
- S3 테스트 이벤트(s3:TestEvent)는 성공 처리하고 종료합니다.
- 객체를 읽어 title과 owner가 비어 있지 않은 문자열인지 검사합니다. 실패하면 해당 SQS messageId만 batchItemFailures에 넣습니다.
- 정상 객체는 docs-index에 object_key, title, owner, status=INDEXED를 저장합니다. 제목과 소유자는 앞뒤 공백을 제거합니다.
- 같은 key를 재처리하면 같은 PK에 덮어써서 한 항목만 유지합니다. 테스트는 고유 key를 사용하며 같은 key 동시 수정의 순서 보장은 요구하지 않습니다.
- 로그에 처리 key와 성공·실패를 남깁니다. 메시지 본문 전체나 자격증명을 로그에 쓰지 않습니다.
- 실행 역할은 지정 inbox의 incoming/* GetObject, docs-index PutItem, 지정 큐의 ReceiveMessage·DeleteMessage·GetQueueAttributes, 자체 로그 권한만 갖습니다.

검증 파일은 incoming/good.json(위 정상 데이터), incoming/bad.json({"title":""}), outside/ignored.json(정상 데이터)입니다. 정상 문서 1건만 색인되고 bad 메시지는 재시도 후 DLQ로 이동해야 합니다. 180초 visibility와 폴링 지연을 고려해 최대 15분 기다립니다.

## 3. 백업과 복구 (10점)

- DynamoDB docs-index의 PITR을 활성화합니다.
- 온디맨드 백업 docs-index-checkpoint를 생성하고 AVAILABLE 상태를 확인합니다.
- 정상 문서가 색인된 후 생성한 백업으로 docs-index-restore 테이블을 복원합니다.
- 복원한 테이블에서 정상 key의 title, owner, status가 원본과 같아야 합니다.
- 원본 테이블은 유지합니다. 복원 테이블에 PITR이 자동 승계된다고 가정하지 않습니다.

## 4. 조건부 권한 (10점)

- IAM role docs-uploader를 만들고, 현재 CloudShell 호출 주체가 AssumeRole할 수 있도록 신뢰 정책을 지정합니다. IAM 사용자를 새로 만들지 않습니다.
- 이 역할은 지정 inbox의 incoming/*에 PutObject, 해당 버킷에 GetBucketLocation을 허용합니다.
- ListBucket은 s3:prefix 조건 StringLike incoming/*로 제한합니다.
- GetObject·DeleteObject·다른 prefix 쓰기·다른 버킷 접근 권한을 부여하지 않습니다.
- 버킷 정책에는 aws:SecureTransport=false인 요청의 s3:*를 명시적으로 Deny합니다.
- 교사는 임시 자격증명으로 incoming/ 쓰기 성공, outside/ 쓰기 거부, incoming/ 읽기 거부를 확인합니다. 테스트 파일은 JSON 필터에 걸리지 않는 .txt를 사용합니다.
- 액세스 키·토큰은 제출물에 포함하지 않습니다.

## 5. 운영 관측 (10점)

- 로그 그룹 /aws/lambda/docs-indexer의 retention을 14일로 설정합니다.
- CloudWatch 경보 docs-dlq-visible: AWS/SQS, ApproximateNumberOfMessagesVisible, QueueName=docs-events-dlq, Maximum, period 60, 1회 평가, 1 이상, treatMissingData=notBreaching.
- SNS Standard topic docs-ops-alerts를 만들고 경보의 AlarmActions에 연결합니다. 이메일 구독·발송은 요구하지 않습니다.
- CloudWatch Dashboard docs-ops: Lambda Errors(Sum)와 SQS DLQ ApproximateNumberOfMessagesVisible(Maximum)를 각각 표시합니다. 리전·함수명·큐명 dimension을 지정합니다.
- 교사는 실패 로그와 DLQ 경보 ALARM 전이를 확인합니다. 경보 테스트 시 실습 큐 외 리소스를 변경하지 않습니다.

## 6. 채점 기준

자동 항목은 각 2점이며 묶인 조건을 모두 만족해야 득점합니다.

| 영역 | 자동 점검 항목 | 자동 | 교사 |
| --- | --- | --- | --- |
| 이벤트 처리 | S3 차단·버전관리, 알림 필터·큐, 원본 큐·visibility·SSE, DLQ·redrive, Lambda runtime·timeout·memory·환경 변수, mapping 설정 | 12 | 8 |
| 백업 복구 | 원본 키·On-demand·PITR, AVAILABLE 백업, 복원 테이블 ACTIVE·키 | 6 | 4 |
| 조건부 권한 | uploader 역할 존재, HTTPS 강제 Deny 정책 | 4 | 6 |
| 운영 관측 | 보관 14일, DLQ 경보 설정, SNS 연결, Dashboard 두 metric | 8 | 2 |
| 총점 | 자동 점검은 정책 의미·실제 처리를 완전히 판단하지 않음 | 30 | 20 |

| 교사 확인 | 부분점수 |
| --- | --- |
| 이벤트 처리 8점 | 정상 색인 2, 동일 key 재처리 시 항목 1개 1, 필터 밖 무시 1, 실패만 batchItemFailures로 반환 1, DLQ 이동 1, Lambda 실행 역할 최소 권한 1, SQS 정책의 SourceArn·SourceAccount 제한 1 |
| 복구 4점 | 정상 데이터 이후 백업 생성 1, 복원 데이터 title·owner·status 일치 2, 원본 유지 1 |
| 권한 6점 | incoming 쓰기 성공 1, outside 쓰기 거부 1, 읽기 거부 1, ListBucket 조건 및 GetBucketLocation 1, 불필요한 정책 없음·신뢰 주체 제한 1, 주요 태그 1 |
| 관측 2점 | 실패 key 로그 1, 실제 DLQ 적재 후 ALARM 전이 1 |

기능 테스트와 IAM 점검은 교사가 수행하고 증거를 확인합니다. API 오류로 자동 점검이 불가능하면 권한을 해결한 뒤 재실행합니다. 오류를 임의 만점 처리하지 않습니다.

## 7. 정리

S3 알림과 Lambda mapping을 먼저 해제합니다. 큐·DLQ·Lambda·로그·경보·Dashboard·SNS·백업·두 테이블을 삭제합니다. 버전 관리된 S3는 현재/이전 버전과 삭제 마커를 모두 비운 뒤 삭제합니다. 실습 역할·정책도 제거합니다.
