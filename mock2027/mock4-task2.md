# 2027 지방대회 대비 모의고사 4회 · 제2과제

| 항목 | 조건 |
| --- | --- |
| 과제명 | Fault-tolerant batch reconciliation |
| 난이도 / 시간 / 배점 | 상 / 4시간 / 50점 |
| 리전 | 서울 ap-northeast-2 |
| 채점 | 교사 실기 평가 50점 |
| 과제 범위 | 자체 제작 연습문제. 제1과제와 독립적으로 응시 |

## 1. 시나리오

정산 요청 파일을 S3에 올리면 워크플로우가 항목별로 정산을 처리합니다. 일시 오류는 재시도하고, 잘못된 항목은 실패 이유를 남긴 뒤 다른 항목을 계속 처리합니다. 같은 파일의 알림을 다시 받아도 정산 레코드가 중복되거나 기존 데이터가 바뀌면 안 됩니다.

구성 흐름은 S3 → EventBridge → Step Functions → Lambda·DynamoDB → S3 결과 파일·CloudWatch입니다. 실제 결제나 외부 시스템은 연동하지 않습니다.

## 2. 입력·이벤트·버전

- 버킷 이름은 reconcile-in-<계정ID>-<비번호>와 reconcile-out-<계정ID>-<비번호>입니다. 두 버킷 모두 버전 관리와 퍼블릭 액세스 차단 4개를 켜고, TLS 미사용 요청을 버킷 정책으로 거부합니다.
- 원본 버킷에 EventBridge 알림을 활성화합니다. 기본 이벤트 버스의 reconcile-upload 규칙은 해당 버킷의 Object Created 이벤트 중 batches/로 시작하고 .json으로 끝나는 객체만 매칭합니다.
- 대상은 Standard 상태 머신 reconcile-flow입니다. EventBridge 대상 역할은 해당 머신의 states:StartExecution만 허용합니다.
- 처리기는 이벤트의 버킷, 객체 키, version-id를 읽고 반드시 해당 S3 VersionId를 지정해 원본을 읽습니다. 동일 키의 최신 버전으로 대체하면 안 됩니다. 원본이 달라졌을 때도 특정 버전의 결과를 재현할 수 있어야 합니다.

정상 파일의 형태입니다. 한 배치의 items는 1~20개이며 배열 순서가 결과에 유지되어야 합니다. batch_id는 영문·숫자·하이픈 1~32자입니다. 외부 JSON이 파싱되지 않거나 batch_id·items 조건이 틀리면 Map을 실행하기 전에 워크플로우를 실패 처리합니다.

```json
{
  "batch_id": "exam-01",
  "items": [
    {"id":"A01","amount":1200},
    {"id":"A02","amount":-10},
    {"id":"A03","amount":2500,"transient":true},
    {"id":"A01","amount":1300}
  ]
}
```

## 3. 워크플로우와 상태 저장

- Lambda reconcile-load는 버전이 지정된 S3 파일을 읽고 배치 구조를 검증합니다. reconcile-apply는 한 항목을 검증하고 DynamoDB에 저장합니다. reconcile-report는 Map 결과를 집계하고 S3에 기록합니다. 런타임은 Python 3.12입니다.
- Step Functions Inline Map의 MaxConcurrency는 1입니다. 입력에 같은 id가 여러 번 나오면 앞선 유효 항목이 먼저 처리되어야 하기 때문입니다.
- 각 id는 영문·숫자·하이픈 1~32자, amount는 1~1,000,000 범위의 JSON 정수입니다. true/false는 금액으로 인정하지 않습니다. transient 필드는 생략하거나 불리언으로 지정합니다. 잘못된 항목은 REJECTED와 이유 INVALID_ITEM으로 기록합니다.
- reconcile-ledger는 On-demand, PK batch_id(String), SK item_id(String)입니다. 조건부 PutItem으로 처음 저장된 금액을 유지합니다. 이미 있는 키의 금액이 같으면 DUPLICATE, 다르면 REJECTED와 이유 AMOUNT_CONFLICT입니다. 조건 실패 후 조회에는 일관된 읽기를 사용합니다.
- 일시 오류는 연습용으로 재현합니다. 유효 항목에 transient=true가 있고 Step Functions Context의 해당 Task RetryCount가 0이면, 저장 전에 reconcile-apply에서 TransientError를 발생시킵니다. RetryCount는 상태 정의에서 Lambda 입력으로 전달합니다. 최초 실행에 값이 생략되는 경우 Lambda는 0으로 처리합니다.
- 해당 Task의 Retry는 TransientError에 대해 IntervalSeconds=1, BackoffRate=2, MaxAttempts=2로 설정합니다. 일시 오류를 해결한 후에는 기존 규칙대로 저장하거나 중복을 판정합니다. 예상하지 못한 권한·인프라 오류는 성공으로 집계하지 말고 실행을 실패 처리합니다.

## 4. 결과·IAM·운영

출력은 reconcile-out 버킷의 reports/<batch_id>/<실행이름>.json에 씁니다. 실행이름은 Step Functions Context의 Execution.Name을 사용합니다. 재실행은 새 실행 이름을 사용하고 이전 보고서를 유지합니다.

보고서 필드는 batch_id, source_version, accepted, duplicate, rejected, items입니다. 세 카운트는 각각 ACCEPTED, DUPLICATE, REJECTED의 건수입니다. items는 원래 순서의 배열이며 각 항목에 index(0부터 시작), status와 거부 시 reason을 포함합니다. 유효한 id가 있으면 item_id도 기록합니다.

- reconcile-load 역할은 입력 버킷 batches/*의 s3:GetObjectVersion만 사용합니다. reconcile-apply 역할은 지정 테이블의 PutItem/GetItem만 사용합니다. reconcile-report 역할은 출력 버킷 reports/*의 PutObject만 사용합니다. 각 함수의 CloudWatch 로그 권한은 별도로 허용합니다.
- 상태 머신 실행 역할의 앱 권한은 지정 Lambda 세 함수의 InvokeFunction으로 제한합니다. 실행 로그를 CloudWatch Logs로 보낼 수 있도록 별도 전달 권한을 추가할 수 있습니다.
- 로그 그룹 /aws/vendedlogs/states/reconcile-flow의 보관은 14일입니다. 워크플로우 로그는 ERROR 이상, 실행 데이터 기록은 끕니다.
- CloudWatch 경보 reconcile-execution-failed는 AWS/States ExecutionsFailed, 대상 상태 머신 ARN dimension, Sum 60초, 1회 평가, 1 이상, 결측치는 notBreaching입니다. SNS Standard reconcile-ops에 연결합니다. 이메일 구독은 과제 범위에 포함되지 않습니다.

## 5. 제출 전 실기 검증

1. 새 batch_id로 예시 파일을 batches/exam-01.json에 올립니다. 결과는 accepted=2, duplicate=0, rejected=2입니다. A03은 한 번 재시도한 뒤 성공하며, A01의 저장 금액은 1200입니다.
2. 같은 객체 버전의 이벤트를 다른 실행 이름으로 다시 입력합니다. accepted=0, duplicate=2, rejected=2이고 원본 테이블의 두 항목은 바뀌지 않아야 합니다. 두 보고서는 서로 다른 객체로 남습니다.
3. 같은 S3 키에 batch_id 또는 금액을 바꾼 새 버전을 저장합니다. 이전 version-id를 담은 이벤트를 다시 실행했을 때 그 버전의 내용을 읽었는지 source_version과 보고서로 확인합니다.
4. outside/ignored.json, batches/ignored.txt를 올려 실행이 시작되지 않는지 확인합니다. 입력 버킷 batches/bad.json에는 잘못된 JSON을 올려 실행 실패와 경보 ALARM 전이를 확인합니다.

## 6. 실기 평가표

| 영역 | 채점 항목 | 배점 |
| --- | --- | --- |
| 수집 | 버전·퍼블릭 차단·TLS 정책 4, 이벤트 필터 및 실행 역할 4, 이전 버전 실제 읽기 4 | 12 |
| 워크플로우 | 구조 검증과 순차 Map 4, TransientError 재시도와 성공 4, 영구 입력 오류가 다른 항목을 막지 않음 4 | 12 |
| 데이터 | 조건부 저장 4, 중복·금액 충돌 분리 및 기존 레코드 보존 5 | 9 |
| 결과와 IAM | 경로·버전·건수·순서 5, 함수별 최소 권한 5 | 10 |
| 운영 | 실패 로그와 보관·실행 데이터 설정 3, 실제 경보 전이 및 SNS 연결 4 | 7 |
| 합계 | 교사 실기 점수 | 50 |

실행 이력, 두 실행의 보고서, DynamoDB 조회 결과, 경보 상태를 증거로 제출합니다. 정리할 때는 EventBridge 규칙을 먼저 비활성화하고 실습 실행이 끝난 뒤 상태 머신·함수·권한·테이블·경보·SNS·로그를 정리합니다. S3는 본인 실습 버킷의 객체 버전과 삭제 마커까지 확인합니다.

## 참고 자료

EventBridge 이벤트 패턴: https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-create-pattern-operators.html

Step Functions Context 객체: https://docs.aws.amazon.com/step-functions/latest/dg/input-output-contextobject.html
