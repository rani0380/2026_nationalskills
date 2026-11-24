# 2027 지방대회 대비 모의고사 6회 · 구현·검증 해설

응시 후 확인하는 보충 해설입니다. 두 과제의 기존 4시간·50점과 교사 실기 평가를 유지합니다. 예시 코드는 핵심 로직이며 전체 AWS 자동 배포 완성본은 아닙니다. 실제 AWS 계정 배포 검증은 수행하지 않았습니다.

## 1. 제1과제 처리 순서

SQS 메시지는 재전달될 수 있습니다. 최초 생성된 S3 보고서로 결과를 고정하고 DynamoDB는 그 보고서에서 복구 가능한 상태 기록으로 사용합니다.

| 단계 | 성공 조건 | 실패 시 |
| --- | --- | --- |
| 메시지 검증 | job_id·키·버전 적합 | 삭제하지 않음 |
| 기존 보고서 확인 | 원본 키·버전 일치 | 다르면 충돌 |
| 원본 처리 | 지정 버전·크기·CSV 정상 | 삭제하지 않음 |
| 최초 보고서 쓰기 | IfNoneMatch="*" | 412는 기존 결과 대조, 409는 제한 재시도 |
| DB 쓰기 | 보고서 값으로 DONE | 보고서와 메시지를 남김 |
| 큐 삭제 | DB까지 성공 | 재전달돼도 동일 결과 재사용 |

보고서가 있는데 DB만 실패했다면 기존 보고서로 DB 기록을 재시도합니다. 보고서를 삭제하거나 무조건 다시 쓰지 않습니다.

## 2. CSV 검증 예시

```python
import csv
import io

def summarize(raw):
    if not 0 < len(raw) <= 65536:
        raise ValueError("INVALID_SIZE")
    reader = csv.reader(io.StringIO(raw.decode("utf-8"), newline=""), strict=True)
    if next(reader, None) != ["device", "result"]:
        raise ValueError("INVALID_HEADER")
    total = passed = failed = 0
    for row in reader:
        if len(row) != 2 or not row[0].strip() or row[1] not in ("PASS", "FAIL"):
            raise ValueError("INVALID_ROW")
        total += 1
        if total > 100:
            raise ValueError("TOO_MANY_ROWS")
        passed += row[1] == "PASS"
        failed += row[1] == "FAIL"
    if total == 0:
        raise ValueError("EMPTY_DATA")
    return {"total": total, "pass": passed, "fail": failed}
```

호출 전 HeadObject와 GetObject에 같은 VersionId를 지정하고 Body.read(65537)로 읽습니다. Body는 반드시 닫습니다. UTF-8·CSV 예외는 실패입니다.

```python
import json

def save_first_report(s3, bucket, job_id, report):
    return s3.put_object(
        Bucket=bucket,
        Key="reports/" + job_id + ".json",
        Body=json.dumps(report, ensure_ascii=False).encode("utf-8"),
        ContentType="application/json",
        IfNoneMatch="*",
    )
```

ClientError HTTP 412는 기존 보고서 대조로, 409는 backoff 후 제한 재시도로 연결합니다. 위 함수만으로 전체 중복 처리가 완성되지는 않습니다. 예외를 성공으로 숨기지 않습니다.

## 3. 제1과제 권한·네트워크

| 역할 | 권한 |
| --- | --- |
| Execution Role | ECR 인증·report-worker 이미지 pull, /report/worker 로그 |
| Task Role SQS | 원본 큐 ReceiveMessage·DeleteMessage·GetQueueAttributes |
| Task Role S3 | inputs/* GetObjectVersion, reports/* GetObject·PutObject |
| Task Role DynamoDB | report-jobs PutItem·GetItem |
| 필요 시 ListBucket | 지정 버킷 inputs/*·reports/* prefix |
| 교사 | 보고서 버전 조회용 ListBucketVersions |

두 역할의 신뢰 주체는 ecs-tasks.amazonaws.com입니다. ECR API·DKR·Logs·SQS의 Private DNS와 SG 443, S3·DynamoDB Gateway RT를 확인합니다. S3 Endpoint 정책은 ECR의 prod-ap-northeast-2-starport-layer-bucket 읽기를 막지 않아야 합니다. 의존성은 이미지 빌드 때 설치합니다.

## 4. 제1과제 검증 명령

입력 파일을 문제 페이지에서 받아 현재 디렉터리에 둡니다.

```bash
export AWS_DEFAULT_REGION=ap-northeast-2
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STUDENT_NO=001
BUCKET="report-data-$ACCOUNT_ID-$STUDENT_NO"
QUEUE_URL=$(aws sqs get-queue-url --queue-name report-jobs --query QueueUrl --output text)
SOURCE_VERSION=$(aws s3api put-object --bucket "$BUCKET" \
  --key inputs/input.csv --body input.csv --query VersionId --output text)
test -n "$SOURCE_VERSION" && test "$SOURCE_VERSION" != null
jq -n --arg v "$SOURCE_VERSION" \
  '{job_id:"exam-001",source_key:"inputs/input.csv",source_version:$v}' > normal-job.json
aws sqs send-message --queue-url "$QUEUE_URL" --message-body file://normal-job.json
# 작업 완료 후 조회
aws s3api get-object --bucket "$BUCKET" --key reports/exam-001.json report.json
cat report.json
aws dynamodb get-item --table-name report-jobs \
  --key '{"job_id":{"S":"exam-001"}}' --consistent-read
```

같은 JSON을 두 번 더 보내고 완료 후 정확한 key의 실제 버전이 1개인지 확인합니다.

```bash
aws sqs send-message --queue-url "$QUEUE_URL" --message-body file://normal-job.json
aws sqs send-message --queue-url "$QUEUE_URL" --message-body file://normal-job.json
aws s3api list-object-versions --bucket "$BUCKET" \
  --prefix reports/exam-001.json \
  --query "Versions[?Key=='reports/exam-001.json'].[VersionId,IsLatest]"
```

DLQ receive-message는 메시지를 잠시 숨깁니다. 경보 확인 전에 반복 수신·삭제하지 않고 visible·not-visible을 함께 봅니다.

## 5. 제2과제 버전 업로드

```bash
export AWS_DEFAULT_REGION=ap-northeast-2
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STUDENT_NO=001
CONFIG_BUCKET="config-store-$ACCOUNT_ID-$STUDENT_NO"
V1=$(aws s3api put-object --bucket "$CONFIG_BUCKET" --key config/site.json \
  --body site-v1.json --query VersionId --output text)
V2=$(aws s3api put-object --bucket "$CONFIG_BUCKET" --key config/site.json \
  --body site-v2.json --query VersionId --output text)
INVALID=$(aws s3api put-object --bucket "$CONFIG_BUCKET" --key config/site.json \
  --body site-invalid.json --query VersionId --output text)
printf 'v1=%s\nv2=%s\ninvalid=%s\n' "$V1" "$V2" "$INVALID"
```

EC2 역할은 실제 버킷 config/site.json의 GetObjectVersion과 별도 SSM·로그 권한을 가집니다. 세 파일을 같은 key에 올리고 각 VersionId를 기록합니다.

## 6. 제2과제 검증·파일 교체 예시

Document schemaVersion 2.2의 BucketName·VersionId String에 interpolationType=ENV_VAR를 지정합니다. 최신 Agent에서 SSM_BucketName·SSM_VersionId를 읽고 없으면 실패합니다. 원시 매개변수를 셸에 직접 삽입하지 않습니다.

```python
import json
import os
import tempfile
from pathlib import Path

def validate_config(raw):
    if not 0 < len(raw) <= 65536:
        raise ValueError("INVALID_SIZE")
    value = json.loads(raw)
    message = value.get("message") if isinstance(value, dict) else None
    if not isinstance(message, str):
        raise ValueError("INVALID_MESSAGE")
    message = message.strip()
    if not 1 <= len(message) <= 80 or any(ord(c) < 32 or ord(c) == 127 for c in message):
        raise ValueError("INVALID_MESSAGE")
    return message

def atomic_write(path, body):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".config-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o644)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)
```

호출 순서는 실제 버전 다운로드 → 제한 읽기 → validate_config → 페이지 bytes·정보 JSON bytes 생성 → atomic_write(index.html) → atomic_write(deployment.json) → localhost 본문 비교입니다. 읽기·검증 실패 시 CONFIG_DEPLOY_FAILED와 exit 1을 내며 기존 파일을 변경하지 않습니다. 파일 교체 오류도 성공으로 숨기지 않습니다.

각 replace는 원자적이지만 두 파일 전체가 한 트랜잭션은 아닙니다. 이 문제는 다운로드·설정 검증 실패 시 보존을 평가하며, OS 중단·디스크 장애 순간의 완전한 복구는 요구하지 않습니다.

## 7. Association·실패 로그 검증 명령

AssociationId는 이름과 다릅니다. 콘솔에서 확인합니다.

```bash
ASSOCIATION_ID="콘솔에서-확인한-연결ID"
aws ssm start-associations-once --association-ids "$ASSOCIATION_ID"
aws ssm describe-association-executions --association-id "$ASSOCIATION_ID"
```

Association의 실행 이력만으로 지정 로그 그룹에 stdout이 수집된다고 가정하지 않습니다. 같은 Document를 Run Command로 시험할 때 출력 옵션을 명시합니다.

```bash
jq -n --arg b "$CONFIG_BUCKET" --arg v "$INVALID" \
  '{BucketName:[$b],VersionId:[$v]}' > invalid-parameters.json
COMMAND_ID=$(aws ssm send-command --document-name config-deploy \
  --targets Key=tag:Role,Values=web \
  --parameters file://invalid-parameters.json \
  --cloud-watch-output-config \
    'CloudWatchOutputEnabled=true,CloudWatchLogGroupName=/config-lab/commands' \
  --query Command.CommandId --output text)
aws ssm list-command-invocations --command-id "$COMMAND_ID" --details
```

/config-lab/commands 그룹·14일 보관·metric filter·경보를 먼저 만듭니다. 필터 생성 전의 과거 실패 로그만으로 새 지표가 생기지는 않습니다. 두 대상의 Failed·nonzero와 파일 hash 보존을 각각 확인하고 Association을 v1으로 복원합니다.

## 8. 자주 발생하는 오류

| 증상 | 확인 순서 |
| --- | --- |
| 이미지 pull 실패 | ECR DNS·SG → S3 RT·레이어 버킷 정책 → Execution Role |
| 로그 없음 | logs Endpoint·그룹·실행 역할 |
| 보고서 버전 증가 | 무조건 put_object·412 후 overwrite |
| DB 누락 | Task Role PutItem·Gateway RT·기존 보고서 재사용 |
| SSM Offline | instance profile·Agent·ssm/ssmmessages·시각 |
| 지정 버전과 다른 문구 | --version-id 누락·latest 읽기 |
| invalid 후 빈 페이지 | 검증 전 리다이렉션·truncate |
| 실패인데 Success | 예외 후 exit 0·종료 코드 유실 |
| 경보 없음 | 출력 옵션·EC2 로그 권한·필터·namespace/name |

## 9. 채점 확인

제1과제는 10+10+16+8+6=50점, 제2과제는 10+8+12+14+6=50점입니다. 기존 부분점수를 유지합니다. 코드 모양만으로 동작 점수를 인정하지 않고 보고서·정확한 key의 버전 수·DB·두 노드 hash·실패 로그·경보 이력을 확인합니다.

## 참고 문서

S3 조건부 쓰기: https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html

ECR Endpoint: https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html

SSM 매개변수: https://docs.aws.amazon.com/systems-manager/latest/userguide/documents-syntax-data-elements-parameters.html

Run Command 로그: https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-rc-setting-up-cwlogs.html
