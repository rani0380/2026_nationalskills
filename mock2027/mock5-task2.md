# 2027 지방대회 대비 모의고사 5회 · 제2과제

| 항목 | 조건 |
| --- | --- |
| 과제명 | Stream audit archive and replay |
| 난이도 / 시간 / 배점 | 상 / 4시간 / 50점 |
| 리전 | 서울 ap-northeast-2 |
| 채점 | 교사 실기 평가 50점 |
| 과제 범위 | 자체 제작 연습문제. 제1과제와 독립적으로 응시 |

## 1. 무엇을 만드나요?

부품 수량이 바뀔 때마다 변경 전후의 값을 감사 기록으로 남깁니다. DynamoDB Streams가 변경 이벤트를 만들고, Lambda가 이벤트를 S3에 기록합니다. 저장에 실패한 이벤트는 별도 버킷에 남겼다가 원인을 고친 후 다시 처리합니다.

구성 흐름은 **DynamoDB → Streams → Lambda → 감사 버킷**입니다. 재시도 한도를 넘긴 이벤트는 **실패 버킷**에 보관합니다.

## 제공 파일

| 파일 | 사용 방법 |
| --- | --- |
| part-001.json | DynamoDB 콘솔의 **항목 생성 → JSON 보기**에 붙여넣습니다. quantity=10으로 시작하는 정상 입력입니다. |
| part-fail-001.json | FAIL_PART_ID를 part-fail-001로 설정한 후, DynamoDB 콘솔에서 이 JSON으로 항목을 생성합니다. |
| parts-stream-test-event.json | Lambda 콘솔 **테스트**에 붙여넣어 INSERT·MODIFY·REMOVE 처리 코드를 점검할 때 사용합니다. |

세 파일은 문제지 상단에서 다운로드합니다. Lambda 테스트 이벤트는 실제 스트림을 기다리기 전에 동작을 확인하는 연습 입력입니다. 실기 평가에는 실제 테이블 변경으로 생성된 이벤트와 실패 버킷에 보관된 원본 입력을 사용합니다.

## 2. 리소스 준비

| 서비스 | 이름 | 필수 설정 |
| --- | --- | --- |
| DynamoDB | parts-inventory | PK part_id(String), On-demand, Streams NEW_AND_OLD_IMAGES |
| Lambda | parts-audit-writer | Python 3.12, timeout 30초, 환경 변수 AUDIT_BUCKET |
| S3 감사 버킷 | parts-audit-<계정ID>-<비번호> | 퍼블릭 액세스 차단 4개, 버전 관리, SSE-S3 |
| S3 실패 버킷 | parts-fail-<계정ID>-<비번호> | 퍼블릭 액세스 차단 4개, 버전 관리, SSE-S3 |
| CloudWatch Logs | /aws/lambda/parts-audit-writer | 보관 7일 |

두 버킷은 모두 서울에 생성합니다. <계정ID>는 본인 AWS 계정의 12자리 ID입니다. 원본 테이블에는 실습 데이터만 넣습니다.

**콘솔 경로**는 DynamoDB → 테이블 → 생성, 생성한 테이블 → 내보내기 및 스트림 → DynamoDB 스트림 켜기입니다. S3에서 두 버킷을 만든 뒤, IAM 역할과 Lambda 함수를 생성합니다. 코드는 Lambda의 **코드** 탭에 입력합니다.

## 3. 변경 기록 저장하기

- Streams의 INSERT·MODIFY·REMOVE를 모두 처리합니다. 각 이벤트의 감사 객체 키는 records/<eventID>.json입니다. 같은 이벤트가 다시 들어와도 같은 키를 사용합니다.
- 객체 JSON에는 event_id, operation, part_id, sequence_number, old_image, new_image를 기록합니다. old_image와 new_image에는 Streams가 전달한 DynamoDB 타입 표기까지 유지합니다. INSERT의 old_image와 REMOVE의 new_image는 JSON null로 기록합니다.
- S3 PutObject의 If-None-Match: * 조건을 사용하여 기존 감사 객체를 덮어쓰지 않습니다. 412 PreconditionFailed는 이미 기록한 이벤트로 처리합니다. 그 밖의 쓰기 실패는 재시도 대상입니다. 사용 중인 SDK에서 조건부 쓰기 옵션을 사용할 수 있어야 합니다.
- 실패 항목은 해당 DynamoDB SequenceNumber를 itemIdentifier로 반환합니다. 모든 항목이 성공했으면 {"batchItemFailures":[]}를 반환합니다. AWS가 실패 지점부터 다시 처리할 수 있으므로, 이미 성공한 항목을 다시 받아도 추가 객체 버전을 만들면 안 됩니다.
- 실패를 재현하려면 환경 변수 FAIL_PART_ID에 실습용 부품 ID를 넣습니다. 값이 지정되어 있고 이벤트의 part_id가 일치하면 그 항목을 저장하기 전에 실패로 표시합니다. 변수가 비어 있거나 제거되면 정상 처리합니다. 이 조건은 실습 검증에만 사용합니다.

## 4. Lambda 트리거와 권한

**Lambda → parts-audit-writer → 트리거 추가 → DynamoDB**에서 해당 스트림을 연결합니다. 실패 대상은 함수 전체의 비동기 호출 대상과 구분하여 **이벤트 소스 매핑의 On failure**로 지정합니다.

| 설정 | 값 |
| --- | --- |
| 시작 위치 | TRIM_HORIZON |
| 배치 크기 / 배치 창 | 5 / 0초 |
| 병렬 처리 계수 | 1 |
| 부분 배치 실패 보고 | ReportBatchItemFailures |
| 최대 재시도 | 2 |
| 최대 레코드 수명 | 300초 |
| On failure 대상 | parts-fail 버킷 |

Lambda 실행 역할은 이 스트림에 필요한 읽기 권한, 감사 버킷 records/*에 대한 PutObject, 실패 대상 버킷의 ListBucket 및 aws/lambda/* 경로의 PutObject, 자체 로그 기록 권한을 갖습니다. 스트림 읽기 권한을 지정한 스트림으로 제한하고, 리소스 수준 제한을 지원하지 않는 작업이 필요할 경우 별도 문장으로 분리합니다. 실패 버킷 쓰기는 지정 버킷과 본인 계정(s3:ResourceAccount)으로 제한합니다. 원본 테이블 변경과 S3 객체 삭제 권한은 부여하지 않습니다.

## 5. 콘솔에서 시험하기

1. **DynamoDB → 테이블 → 항목 탐색**에서 part_id=part-001, quantity=10인 항목을 생성합니다. quantity를 7로 수정한 뒤 항목을 삭제합니다. S3 감사 버킷에서 세 JSON을 확인합니다. INSERT는 새 값 10, MODIFY는 이전 10과 새 7, REMOVE는 이전 7을 보여야 합니다.
2. 함수 환경 변수 FAIL_PART_ID를 part-fail-001로 설정합니다. 설정 적용 뒤 이 ID에 quantity=4를 넣고, Lambda 실행 로그의 실패와 실패 버킷에 객체가 생기는 것을 확인합니다. AWS가 전달한 실패 객체에서 원래 Records가 포함된 호출 입력을 확인합니다.
3. FAIL_PART_ID를 제거합니다. 실패 객체의 payload 문자열을 JSON으로 해석해 원래 Records를 포함한 호출 입력을 추출하고 **Lambda → 테스트**에 입력하고 동기 호출합니다. DynamoDB에 같은 쓰기를 다시 만들어서는 복구 증거가 되지 않습니다. 원래 eventID의 감사 객체가 생겼는지 확인합니다.
4. 같은 호출 입력을 한 번 더 실행합니다. 동일한 감사 객체의 버전 수가 늘지 않아야 합니다. 다른 정상 이벤트가 계속 저장되는지도 확인합니다.
5. 함수에서 실패 항목마다 ARCHIVE_FAILURE 문자열과 eventID·SequenceNumber를 기록합니다. **CloudWatch → 로그 그룹 → 지표 필터**에서 이 문자열에 해당하는 카운트 지표 PartsAudit/RecordFailures를 만듭니다. **CloudWatch → 경보**에서 parts-audit-failures를 생성합니다. 통계 Sum, 60초, 1회 평가, 1 이상, 결측치는 notBreaching입니다. 지표 필터와 경보를 2단계 전에 준비하여 실제 실패 때 ALARM 전이를 확인합니다.

## 6. 실기 평가표

| 영역 | 확인할 항목 | 배점 |
| --- | --- | --- |
| 저장소 | 테이블·스트림 5, 두 버킷 설정 5 | 10 |
| 기록 처리 | 세 동작과 전후 값 7, 조건부 쓰기와 중복 버전 방지 7 | 14 |
| 트리거 | 매핑·부분 실패 응답 5, 재시도·실패 대상 5 | 10 |
| 장애 복구 | 원본 실패 입력 보관 4, 같은 eventID 복구 및 재호출 6 | 10 |
| 권한·관측 | 역할 범위 3, 로그 보관·지표·실제 경보 3 | 6 |
| 합계 | 교사 실기 평가 | 50 |

세 변경 기록, 실패 객체, 재처리 결과, 감사 객체의 버전 목록과 경보 이력을 증거로 제출합니다. 정리할 때는 이벤트 소스 매핑을 먼저 비활성화하고 실패 대상 연결을 제거한 뒤, 실습용 함수·테이블·권한과 S3 객체 버전·삭제 마커를 정리합니다.

## 참고 자료

DynamoDB Streams 부분 배치 실패: https://docs.aws.amazon.com/lambda/latest/dg/services-ddb-batchfailurereporting.html

DynamoDB 이벤트의 실패 대상: https://docs.aws.amazon.com/lambda/latest/dg/services-dynamodb-errors.html

S3 조건부 쓰기: https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html

## 채점 결과 제출

교사가 확정한 뒤 채점 스크립트의 최종 출력을 복사합니다. 아래 양식에 비번호와 이름, 전체 출력을 입력하고 **Google Sheets로 제출**을 누릅니다. 입력한 비번호는 출력과 같아야 합니다.
