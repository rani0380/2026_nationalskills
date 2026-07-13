# 02_2과제 Module 1 설명서: Workflow

## 목표

S3에 학생 성적 CSV가 업로드되면 Step Functions가 실행되고, Lambda가 데이터를 검증한 뒤 정상 데이터는 DynamoDB에 저장하고 오류 데이터는 S3 `error/`에 남기는 서버리스 워크플로우를 구성합니다.

## 핵심 아키텍처

```text
S3 input/test.csv
  -> S3 Event Notification
  -> Trigger Lambda
  -> Step Functions Standard Workflow
  -> Processing Lambda
  -> DynamoDB 저장 + S3 error JSON 저장
  -> S3 processed/test.csv 이동
```

## 필수 리소스

| 항목 | 값 |
|---|---|
| Region | `ap-southeast-1` |
| S3 Bucket | `wsc2026-student-score-bucket-<비번호>` |
| Prefix | `input/`, `processed/`, `error/` |
| DynamoDB | `wsc2026-student-score` |
| Key | PK `studentId`, SK `examDate` |
| Processing Lambda | `wsc2026-student-score-function` |
| Runtime | `python3.12` |
| Lambda Env | `S3_BUCKET`, `DDB_TABLE` |
| Step Functions | `wsc2026-student-score-workflow`, `STANDARD` |
| IAM Role | `wsc2026-lambda-student-role`, `wsc2026-stepfunction-student-role` |

## 이론 설명

### S3 Prefix

S3의 `input/`, `processed/`, `error/`는 실제 폴더가 아니라 객체 key의 prefix입니다. 워크플로우에서는 prefix를 상태 구분값처럼 사용합니다.

| Prefix | 의미 |
|---|---|
| `input/` | 처리 대상 원본 |
| `processed/` | 처리 완료 파일 |
| `error/` | 검증 실패 또는 처리 실패 로그 |

### Lambda

Lambda는 CSV를 읽고 행 단위로 검증하는 이벤트 처리 함수입니다. 이 과제에서는 평균과 등급을 계산한 뒤 DynamoDB에 저장합니다.

검증 규칙:

| 검증 | 실패 사유 |
|---|---|
| 필수 필드 누락 | `MISSING_FIELD` |
| 점수 0~100 범위 초과 | `INVALID_SCORE` |
| 점수가 정수가 아님 | `INVALID_FORMAT` |
| 날짜 형식 오류 | `INVALID_DATE` |

### DynamoDB PK/SK

`studentId`는 학생을 구분하고, `examDate`는 같은 학생의 여러 시험 결과를 구분합니다. 두 값을 합쳐 하나의 성적 레코드를 유일하게 식별합니다.

### Step Functions

Step Functions는 처리 단계를 상태 기계로 관리합니다. Lambda 하나에 모든 로직을 넣는 것보다 파일 확인, 처리, 분기, 이동을 명확하게 나눌 수 있습니다.

## 구축 순서

1. `ap-southeast-1` 리전 설정
2. S3 버킷과 prefix 생성
3. DynamoDB 테이블 생성
4. Processing Lambda 코드 TODO 완성
5. Lambda 배포 및 환경변수 설정
6. Step Functions Standard workflow 작성
7. Trigger Lambda 작성
8. S3 Event Notification 연결
9. `test.csv` 업로드 후 결과 확인

## 핵심 명령

```bash
aws configure set region ap-southeast-1
export NUM=<비번호>
export BUCKET_NAME=wsc2026-student-score-bucket-${NUM}

aws s3api create-bucket \
  --bucket ${BUCKET_NAME} \
  --region ap-southeast-1 \
  --create-bucket-configuration LocationConstraint=ap-southeast-1

aws s3api put-object --bucket ${BUCKET_NAME} --key input/
aws s3api put-object --bucket ${BUCKET_NAME} --key processed/
aws s3api put-object --bucket ${BUCKET_NAME} --key error/
```

```bash
aws dynamodb create-table \
  --table-name wsc2026-student-score \
  --attribute-definitions AttributeName=studentId,AttributeType=S AttributeName=examDate,AttributeType=S \
  --key-schema AttributeName=studentId,KeyType=HASH AttributeName=examDate,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST
```

## Lambda TODO 핵심

`STU1020`은 평균이 `96.6`, 등급이 `A`가 되어야 합니다.

```python
def calculate_grade(average):
    if average >= 90:
        return "A"
    if average >= 80:
        return "B"
    if average >= 70:
        return "C"
    if average >= 60:
        return "D"
    return "F"
```

## 채점 확인

```bash
aws dynamodb get-item \
  --table-name wsc2026-student-score \
  --key '{"studentId":{"S":"STU1020"},"examDate":{"S":"2026-05-30"}}' \
  --query "Item.[studentId.S,average.N,grade.S]" \
  --output text

aws s3 ls s3://${BUCKET_NAME}/processed/test.csv
aws s3 ls s3://${BUCKET_NAME}/error/ | grep "error_"
```

기대값:

- `STU1020 96.6 A`
- `processed/test.csv` 존재
- `error/error_...json` 존재

## 자주 틀리는 부분

| 실수 | 해결 |
|---|---|
| `processed/`, `error/`에 이전 결과가 남음 | 채점 전 `aws s3 rm ... --recursive`로 정리 |
| Lambda handler 불일치 | 파일명을 `index.py`, handler를 `index.handler`로 맞춤 |
| 평균이 `96.6`이 아님 | float 오차를 피하고 소수 1자리로 저장 |
| Step Functions type이 Express | 반드시 `STANDARD` 사용 |
| S3 trigger가 모든 파일에 반응 | prefix `input/`, suffix `.csv` 설정 |
