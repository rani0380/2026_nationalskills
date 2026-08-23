# 02_2과제 Module 1 설명서: Workflow

### 1.1 목표

학생 성적 CSV가 S3 `input/` 경로에 업로드되면 Step Functions가 실행되고, Lambda가 CSV를 검증하여 정상 데이터는 DynamoDB에 저장하고 오류 데이터는 S3 `error/`에 JSON으로 저장합니다. 처리 후 원본 CSV는 `processed/`로 이동합니다.

### 1.2 필수 리소스

| 항목 | 값 |
|---|---|
| Region | `ap-southeast-1` |
| S3 Bucket | `wsc2026-student-score-bucket-<비번호>` |
| Prefix | `input/`, `processed/`, `error/` |
| DynamoDB Table | `wsc2026-student-score` |
| Key | PK `studentId`, SK `examDate` |
| Processing Lambda | `wsc2026-student-score-function` |
| Runtime | `python3.12` |
| Lambda Env | `S3_BUCKET`, `DDB_TABLE` |
| Trigger Lambda | 선수 직접 작성 |
| Step Functions | `wsc2026-student-score-workflow`, `STANDARD` |
| Lambda Role | `wsc2026-lambda-student-role` |
| Step Functions Role | `wsc2026-stepfunction-student-role` |

### 1.3 S3 버킷과 폴더

```bash
aws configure set region ap-southeast-1
export BUCKET_NAME=wsc2026-student-score-bucket-${NUM}

aws s3api create-bucket \
  --bucket ${BUCKET_NAME} \
  --region ap-southeast-1 \
  --create-bucket-configuration LocationConstraint=ap-southeast-1

aws s3api put-object --bucket ${BUCKET_NAME} --key input/
aws s3api put-object --bucket ${BUCKET_NAME} --key processed/
aws s3api put-object --bucket ${BUCKET_NAME} --key error/
```

채점 전에는 `processed/`, `error/`가 비어 있어야 하며, 제공된 `test.csv`를 `input/test.csv`에 업로드합니다.

```bash
aws s3 rm s3://${BUCKET_NAME}/processed/ --recursive
aws s3 rm s3://${BUCKET_NAME}/error/ --recursive
aws s3 cp test.csv s3://${BUCKET_NAME}/input/test.csv
```

### 1.4 DynamoDB

```bash
aws dynamodb create-table \
  --table-name wsc2026-student-score \
  --attribute-definitions AttributeName=studentId,AttributeType=S AttributeName=examDate,AttributeType=S \
  --key-schema AttributeName=studentId,KeyType=HASH AttributeName=examDate,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST
```

채점 전 데이터 정리:

```bash
aws dynamodb scan --table-name wsc2026-student-score \
  --projection-expression "studentId, examDate" \
  --query "Items[]" --output json
```

데이터가 남아 있으면 키를 기준으로 삭제합니다.

### 1.5 성적 처리 Lambda TODO 완성

제공 `lambda-function.py`의 `calculate_grade`, `save_student`를 채워야 합니다.

핵심 구현:

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


def save_student(table, row):
    scores = [int(row[field].strip()) for field in SCORE_FIELDS]
    average = Decimal(str(round(sum(scores) / len(scores), 1)))
    grade = calculate_grade(float(average))
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    table.put_item(
        Item={
            "studentId": row["studentId"].strip(),
            "examDate": row["examDate"].strip(),
            "name": row["name"].strip(),
            "className": row["className"].strip(),
            "korean": int(row["korean"]),
            "english": int(row["english"]),
            "math": int(row["math"]),
            "science": int(row["science"]),
            "history": int(row["history"]),
            "average": average,
            "grade": grade,
            "createdAt": now,
        }
    )
```

`STU1020`은 `100, 98, 92, 97, 96`이므로 평균 `96.6`, 등급 `A`가 나와야 합니다. 채점 스크립트가 이 값을 직접 조회합니다.

### 1.6 Lambda 배포

```bash
cp lambda-function.py index.py
zip function.zip index.py

aws lambda create-function \
  --function-name wsc2026-student-score-function \
  --runtime python3.12 \
  --handler index.handler \
  --zip-file fileb://function.zip \
  --role arn:aws:iam::${ACCOUNT_ID}:role/wsc2026-lambda-student-role \
  --timeout 30 \
  --environment Variables="{S3_BUCKET=${BUCKET_NAME},DDB_TABLE=wsc2026-student-score}"
```

함수명 파일에 하이픈이 있으면 Python import가 불편하므로 실제 배포 시에는 `index.py`로 이름을 바꾸고 `--handler index.handler`를 쓰는 편이 안전합니다.

### 1.7 Step Functions 정의

State Machine 이름은 `wsc2026-student-score-workflow`, 타입은 `STANDARD`입니다.

흐름:

1. `CheckS3File`: S3 HeadObject
2. `ProcessStudentData`: Lambda invoke
3. `CheckResult`: `statusCode == 200`이면 processed 이동
4. `MoveToProcessed`: `input/test.csv`를 `processed/test.csv`로 복사 후 원본 삭제
5. 실패 시 `MoveToError`

State Machine 정의의 핵심 형태:

```json
{
  "StartAt": "CheckS3File",
  "States": {
    "CheckS3File": {
      "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:s3:headObject",
      "Parameters": {
        "Bucket": "wsc2026-student-score-bucket-<비번호>",
        "Key.$": "$.key"
      },
      "Next": "ProcessStudentData"
    },
    "ProcessStudentData": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "wsc2026-student-score-function",
        "Payload.$": "$"
      },
      "OutputPath": "$.Payload",
      "Retry": [
        {
          "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2
        }
      ],
      "Next": "CheckResult"
    },
    "CheckResult": {
      "Type": "Choice",
      "Choices": [
        {
          "Variable": "$.statusCode",
          "NumericEquals": 200,
          "Next": "MoveToProcessed"
        }
      ],
      "Default": "MoveToError"
    }
  }
}
```

Copy/Delete 작업은 `arn:aws:states:::aws-sdk:s3:copyObject`, `deleteObject`를 사용합니다. Step Functions role에는 S3와 Lambda invoke 권한이 필요합니다.

### 1.8 S3 Trigger Lambda

S3 `input/*.csv` 업로드 이벤트를 받아 Step Functions를 시작합니다.

```python
import json
import os
import urllib.parse
import boto3

sf = boto3.client("stepfunctions")
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]


def handler(event, context):
    for record in event.get("Records", []):
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        if not key.startswith("input/") or not key.endswith(".csv"):
            continue
        sf.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            input=json.dumps({"key": key}),
        )
    return {"started": True}
```

S3 notification:

- Event: `s3:ObjectCreated:*`
- Prefix: `input/`
- Suffix: `.csv`

### 1.9 채점 확인

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

---



## 1.10 이 페이지만 보고 완성하는 사전 준비

[Module 1 지급파일 다운로드](downloads/task02-modules/module1.zip)

압축파일에는 lambda-function.py, lambda.md, workflow.md, test.csv가 들어 있습니다. CloudShell에 업로드하고 다음 변수를 먼저 설정합니다.

```bash
unzip module1.zip
cd module1

aws configure set region ap-southeast-1
export NUM=<실제 비번호>
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET_NAME=wsc2026-student-score-bucket-$NUM

printf 'ACCOUNT=%s\nBUCKET=%s\n' "$ACCOUNT_ID" "$BUCKET_NAME"
```

NUM에는 꺾쇠를 넣지 않습니다. 이후 명령은 같은 CloudShell 세션에서 실행합니다.

## 1.11 Processing Lambda 전체 완성 코드

지급 lambda-function.py를 index.py로 복사하고 아래 코드로 맞춥니다. DynamoDB는 Python float를 허용하지 않으므로 average는 Decimal로 저장해야 합니다.

```python
import csv
import io
import json
import os
import re
from datetime import datetime, timezone
from decimal import Decimal

import boto3

REQUIRED_FIELDS = ["examDate", "studentId", "name", "className", "korean", "english", "math", "science", "history"]
SCORE_FIELDS = ["korean", "english", "math", "science", "history"]

s3_client = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")


def validate_row(row):
    for field in REQUIRED_FIELDS:
        if not (row.get(field) or "").strip():
            return "MISSING_FIELD"

    exam_date = row.get("examDate", "").strip()
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", exam_date):
        return "INVALID_DATE"
    try:
        datetime.strptime(exam_date, "%Y-%m-%d")
    except ValueError:
        return "INVALID_DATE"

    for field in SCORE_FIELDS:
        value = row.get(field, "").strip()
        if not value.lstrip("+-").isdigit():
            return "INVALID_FORMAT"
        score = int(value)
        if score < 0 or score > 100:
            return "INVALID_SCORE"

    return None


def save_error(bucket, row, error_reason, timestamp):
    student_id = (row.get("studentId") or "unknown").strip()
    error_key = f"error/error_{timestamp}_{student_id}.json"

    body = {
        "studentId": student_id,
        "examDate": (row.get("examDate") or "").strip(),
        "error_reason": error_reason,
        "raw_data": {k: (v or "").strip() for k, v in row.items()},
    }

    s3_client.put_object(
        Bucket=bucket,
        Key=error_key,
        Body=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        ContentType="application/json; charset=utf-8",
    )


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


def save_student(table, row):
    scores = [int(row[field].strip()) for field in SCORE_FIELDS]
    average = Decimal(str(round(sum(scores) / len(scores), 1)))
    grade = calculate_grade(float(average))
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    table.put_item(Item={
        "studentId": row["studentId"].strip(),
        "examDate": row["examDate"].strip(),
        "name": row["name"].strip(),
        "className": row["className"].strip(),
        "korean": int(row["korean"]),
        "english": int(row["english"]),
        "math": int(row["math"]),
        "science": int(row["science"]),
        "history": int(row["history"]),
        "average": average,
        "grade": grade,
        "createdAt": now,
    })


def handler(event, context):
    bucket = os.environ.get("S3_BUCKET")
    table_name = os.environ.get("DDB_TABLE")

    if not bucket or not table_name:
        return {"statusCode": 400, "processed": 0, "errors": 0}

    key = event.get("key")
    if not key or not key.startswith("input/"):
        return {"statusCode": 400, "processed": 0, "errors": 0}

    try:
        response = s3_client.get_object(Bucket=bucket, Key=key)
        csv_text = response["Body"].read().decode("utf-8")
    except Exception:
        return {"statusCode": 400, "processed": 0, "errors": 0}

    reader = csv.DictReader(io.StringIO(csv_text))
    rows = list(reader)

    table = dynamodb.Table(table_name)
    processed = 0
    errors = 0
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")

    for row in rows:
        error_reason = validate_row(row)
        if error_reason:
            save_error(bucket, row, error_reason, timestamp)
            errors += 1
        else:
            save_student(table, row)
            processed += 1

    return {"statusCode": 200, "processed": processed, "errors": errors}
```

지급 test.csv는 정상 5행, 오류 4행입니다. STU1020의 다섯 점수는 100, 98, 92, 97, 96이므로 평균은 정확히 96.6이고 등급은 A입니다.

## 1.12 IAM Role을 처음부터 만들기

### Processing Lambda Role

trust-lambda.json:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
```

```bash
aws iam create-role \
  --role-name wsc2026-lambda-student-role \
  --assume-role-policy-document file://trust-lambda.json

aws iam attach-role-policy \
  --role-name wsc2026-lambda-student-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

processing-policy.json의 두 placeholder를 실제 값으로 치환합니다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::<BUCKET_NAME>/*"
    },
    {
      "Effect": "Allow",
      "Action": "dynamodb:PutItem",
      "Resource": "arn:aws:dynamodb:ap-southeast-1:<ACCOUNT_ID>:table/wsc2026-student-score"
    }
  ]
}
```

```bash
sed -i "s/<ACCOUNT_ID>/${ACCOUNT_ID}/g; s/<BUCKET_NAME>/${BUCKET_NAME}/g" processing-policy.json

aws iam put-role-policy \
  --role-name wsc2026-lambda-student-role \
  --policy-name wsc2026-processing-inline \
  --policy-document file://processing-policy.json
```

### Step Functions Role

trust-sfn.json:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "states.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
```

```bash
aws iam create-role \
  --role-name wsc2026-stepfunction-student-role \
  --assume-role-policy-document file://trust-sfn.json
```

sfn-policy.json:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "lambda:InvokeFunction",
      "Resource": "arn:aws:lambda:ap-southeast-1:<ACCOUNT_ID>:function:wsc2026-student-score-function"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::<BUCKET_NAME>/*"
    }
  ]
}
```

```bash
sed -i "s/<ACCOUNT_ID>/${ACCOUNT_ID}/g; s/<BUCKET_NAME>/${BUCKET_NAME}/g" sfn-policy.json

aws iam put-role-policy \
  --role-name wsc2026-stepfunction-student-role \
  --policy-name wsc2026-workflow-inline \
  --policy-document file://sfn-policy.json
```

## 1.13 Processing Lambda 배포와 단독 테스트

```bash
cp lambda-function.py index.py
# CloudShell Editor에서 index.py의 TODO 두 곳을 1.11 코드처럼 완성
zip -j processing.zip index.py

aws lambda create-function \
  --function-name wsc2026-student-score-function \
  --runtime python3.12 \
  --handler index.handler \
  --zip-file fileb://processing.zip \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/wsc2026-lambda-student-role" \
  --timeout 30 \
  --memory-size 256 \
  --environment "Variables={S3_BUCKET=${BUCKET_NAME},DDB_TABLE=wsc2026-student-score}"
```

Role 생성 직후 create-function이 AssumeRole 오류를 내면 10초 정도 기다렸다 다시 실행합니다.

단독 테스트:

```bash
aws s3 cp test.csv "s3://${BUCKET_NAME}/input/test.csv"

aws lambda invoke \
  --function-name wsc2026-student-score-function \
  --payload '{"key":"input/test.csv"}' \
  --cli-binary-format raw-in-base64-out \
  processing-result.json

cat processing-result.json
```

기대 결과는 statusCode 200, processed 5, errors 4입니다.

## 1.14 Step Functions 전체 정의

workflow.json을 만들고 <BUCKET_NAME>을 치환합니다.

```json
{
  "Comment": "Student score CSV workflow",
  "StartAt": "CheckS3File",
  "States": {
    "CheckS3File": {
      "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:s3:headObject",
      "Parameters": {
        "Bucket": "<BUCKET_NAME>",
        "Key.$": "$.key"
      },
      "ResultPath": "$.head",
      "Catch": [{
        "ErrorEquals": ["States.ALL"],
        "Next": "WorkflowFailed"
      }],
      "Next": "ProcessStudentData"
    },
    "ProcessStudentData": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "wsc2026-student-score-function",
        "Payload": {"key.$": "$.key"}
      },
      "ResultPath": "$.lambda",
      "Retry": [{
        "ErrorEquals": [
          "Lambda.ServiceException",
          "Lambda.AWSLambdaException",
          "Lambda.SdkClientException",
          "Lambda.TooManyRequestsException"
        ],
        "IntervalSeconds": 2,
        "MaxAttempts": 3,
        "BackoffRate": 2
      }],
      "Catch": [{
        "ErrorEquals": ["States.ALL"],
        "Next": "MoveToErrorCopy"
      }],
      "Next": "CheckResult"
    },
    "CheckResult": {
      "Type": "Choice",
      "Choices": [{
        "Variable": "$.lambda.Payload.statusCode",
        "NumericEquals": 200,
        "Next": "MoveToProcessedCopy"
      }],
      "Default": "MoveToErrorCopy"
    },
    "MoveToProcessedCopy": {
      "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:s3:copyObject",
      "Parameters": {
        "Bucket": "<BUCKET_NAME>",
        "CopySource.$": "States.Format('<BUCKET_NAME>/{}', $.key)",
        "Key.$": "States.Format('processed/{}', States.ArrayGetItem(States.StringSplit($.key, '/'), 1))"
      },
      "ResultPath": null,
      "Next": "DeleteProcessedInput"
    },
    "DeleteProcessedInput": {
      "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:s3:deleteObject",
      "Parameters": {
        "Bucket": "<BUCKET_NAME>",
        "Key.$": "$.key"
      },
      "ResultPath": null,
      "Next": "WorkflowSucceeded"
    },
    "MoveToErrorCopy": {
      "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:s3:copyObject",
      "Parameters": {
        "Bucket": "<BUCKET_NAME>",
        "CopySource.$": "States.Format('<BUCKET_NAME>/{}', $.key)",
        "Key.$": "States.Format('error/{}', States.ArrayGetItem(States.StringSplit($.key, '/'), 1))"
      },
      "ResultPath": null,
      "Next": "DeleteErrorInput"
    },
    "DeleteErrorInput": {
      "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:s3:deleteObject",
      "Parameters": {
        "Bucket": "<BUCKET_NAME>",
        "Key.$": "$.key"
      },
      "ResultPath": null,
      "Next": "WorkflowFailed"
    },
    "WorkflowSucceeded": {"Type": "Succeed"},
    "WorkflowFailed": {
      "Type": "Fail",
      "Error": "StudentScoreWorkflowFailed",
      "Cause": "Input check or processing failed"
    }
  }
}
```

```bash
sed -i "s/<BUCKET_NAME>/${BUCKET_NAME}/g" workflow.json

aws stepfunctions create-state-machine \
  --name wsc2026-student-score-workflow \
  --type STANDARD \
  --definition file://workflow.json \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/wsc2026-stepfunction-student-role"

export STATE_MACHINE_ARN=$(aws stepfunctions list-state-machines \
  --query "stateMachines[?name=='wsc2026-student-score-workflow'].stateMachineArn | [0]" \
  --output text)
```

지급 test.csv는 오류 행이 포함되어도 파일 읽기와 행별 처리가 성공하므로 statusCode 200입니다. 따라서 오류 JSON 4개를 만들면서 원본은 processed/test.csv로 이동합니다.

## 1.15 Trigger Lambda 전체 구성

Trigger 전용 Role을 만듭니다.

```bash
aws iam create-role \
  --role-name wsc2026-trigger-lambda-role \
  --assume-role-policy-document file://trust-lambda.json

aws iam attach-role-policy \
  --role-name wsc2026-trigger-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

trigger-policy.json:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "states:StartExecution",
    "Resource": "<STATE_MACHINE_ARN>"
  }]
}
```

```bash
sed -i "s|<STATE_MACHINE_ARN>|${STATE_MACHINE_ARN}|g" trigger-policy.json
aws iam put-role-policy \
  --role-name wsc2026-trigger-lambda-role \
  --policy-name wsc2026-trigger-inline \
  --policy-document file://trigger-policy.json
```

trigger.py:

```python
import json
import os
import urllib.parse
import boto3

stepfunctions = boto3.client("stepfunctions")
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]


def handler(event, context):
    executions = []

    for record in event.get("Records", []):
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        if not key.startswith("input/") or not key.endswith(".csv"):
            continue

        response = stepfunctions.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            input=json.dumps({"key": key}),
        )
        executions.append(response["executionArn"])

    return {"started": len(executions), "executions": executions}
```

```bash
zip -j trigger.zip trigger.py

aws lambda create-function \
  --function-name wsc2026-student-score-trigger \
  --runtime python3.12 \
  --handler trigger.handler \
  --zip-file fileb://trigger.zip \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/wsc2026-trigger-lambda-role" \
  --timeout 15 \
  --environment "Variables={STATE_MACHINE_ARN=${STATE_MACHINE_ARN}}"

export TRIGGER_ARN=$(aws lambda get-function-configuration \
  --function-name wsc2026-student-score-trigger \
  --query FunctionArn --output text)
```

## 1.16 S3 Event Notification 연결

S3가 Trigger Lambda를 호출할 수 있는 Resource-based permission을 먼저 추가합니다.

```bash
aws lambda add-permission \
  --function-name wsc2026-student-score-trigger \
  --statement-id AllowS3Invoke \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::${BUCKET_NAME}" \
  --source-account "$ACCOUNT_ID"
```

notification.json:

```json
{
  "LambdaFunctionConfigurations": [{
    "Id": "student-score-input-csv",
    "LambdaFunctionArn": "<TRIGGER_ARN>",
    "Events": ["s3:ObjectCreated:*"],
    "Filter": {
      "Key": {
        "FilterRules": [
          {"Name": "prefix", "Value": "input/"},
          {"Name": "suffix", "Value": ".csv"}
        ]
      }
    }
  }]
}
```

```bash
sed -i "s|<TRIGGER_ARN>|${TRIGGER_ARN}|g" notification.json

aws s3api put-bucket-notification-configuration \
  --bucket "$BUCKET_NAME" \
  --notification-configuration file://notification.json

aws s3api get-bucket-notification-configuration --bucket "$BUCKET_NAME"
```

put-bucket-notification-configuration은 기존 Notification 전체를 교체합니다. 기존 알림이 있다면 먼저 조회해 새 설정과 합쳐야 합니다. Prefix input/와 Suffix .csv를 모두 지정하면 error/ JSON 생성으로 Trigger가 재호출되는 것을 막습니다.

## 1.17 최종 통합 테스트

이전에 단독 테스트했다면 결과를 정리하고 다시 업로드합니다. 아래 삭제는 echo로 현재 과제 버킷 이름을 확인한 뒤 실행합니다.

```bash
echo "$BUCKET_NAME"
aws s3 rm "s3://${BUCKET_NAME}/input/" --recursive
aws s3 rm "s3://${BUCKET_NAME}/processed/" --recursive
aws s3 rm "s3://${BUCKET_NAME}/error/" --recursive

aws s3api put-object --bucket "$BUCKET_NAME" --key input/
aws s3api put-object --bucket "$BUCKET_NAME" --key processed/
aws s3api put-object --bucket "$BUCKET_NAME" --key error/

aws s3 cp test.csv "s3://${BUCKET_NAME}/input/test.csv"
```

10~30초 후 확인합니다.

```bash
aws stepfunctions list-executions \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --max-results 5 \
  --query 'executions[*].[status,startDate,name]' --output table

aws dynamodb get-item \
  --table-name wsc2026-student-score \
  --key '{"studentId":{"S":"STU1020"},"examDate":{"S":"2026-05-30"}}' \
  --query "Item.[studentId.S,average.N,grade.S]" --output text

aws s3 ls "s3://${BUCKET_NAME}/processed/test.csv"
aws s3 ls "s3://${BUCKET_NAME}/error/" | grep "error_"
```

기대 결과:

```text
STU1020    96.6    A
processed/test.csv 존재
error/error_*.json 4개
```

오류 JSON 내용 확인:

```bash
ERROR_KEY=$(aws s3api list-objects-v2 \
  --bucket "$BUCKET_NAME" --prefix error/error_ \
  --query 'Contents[0].Key' --output text)
aws s3 cp "s3://${BUCKET_NAME}/${ERROR_KEY}" -
```

## 1.18 장애 진단표

| 증상 | 원인 | 해결 |
|---|---|---|
| Float types are not supported | average를 float로 저장 | Decimal(str(round(..., 1))) 사용 |
| Trigger가 실행되지 않음 | Lambda Resource Policy 누락 | add-permission 후 Notification 저장 |
| Trigger가 반복 실행됨 | input/ Filter 누락 | Prefix input/, Suffix .csv 적용 |
| Workflow AccessDenied | SFN Role 권한 부족 | Lambda Invoke, S3 Get/Put/Delete 확인 |
| Choice가 Default로 감 | 결과 경로 불일치 | $.lambda.Payload.statusCode 확인 |
| processed/test.csv 없음 | Copy/Delete 상태 실패 | Execution event history 확인 |
| handler 오류 | ZIP 파일명 불일치 | index.py와 index.handler 사용 |
| State Machine이 EXPRESS | type 누락 | STANDARD로 다시 생성 |
| 결과가 이전 시험과 섞임 | S3/DDB 잔존 데이터 | 현재 과제 리소스만 범위를 확인해 정리 |
| Notification 저장 실패 | S3 호출 권한 검증 실패 | Lambda add-permission을 먼저 실행 |

로그:

```bash
aws logs tail /aws/lambda/wsc2026-student-score-trigger --since 10m
aws logs tail /aws/lambda/wsc2026-student-score-function --since 10m
```

## 1.19 제출 직전 체크리스트

- Region은 ap-southeast-1이다.
- 버킷 이름 끝에 실제 비번호가 들어갔다.
- DynamoDB PK/SK는 studentId/examDate String이다.
- Processing Lambda는 python3.12, index.handler다.
- S3_BUCKET과 DDB_TABLE 환경변수가 정확하다.
- Workflow 이름이 정확하고 STANDARD다.
- S3 Notification은 input/ + .csv만 처리한다.
- 최근 Execution은 SUCCEEDED다.
- STU1020 결과는 96.6 A다.
- processed/test.csv와 error/error_*.json이 존재한다.
- 채점 출력에 Access Key, Secret 또는 Session Token이 없다.
