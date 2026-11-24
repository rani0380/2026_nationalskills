"""모의 6회 학생용 시작 코드. TODO 1~3을 구현하기 전에는 성공 처리되지 않습니다."""
import csv
import io
import json
import os
import re
import time

def validate_job(body):
    """TODO 1: JSON 문자열 -> 필수 세 필드 dict. 잘못된 입력은 ValueError.
    job_id: ^[A-Za-z0-9-]{1,40}$, source_key: inputs/ 아래 .csv,
    source_version: 비어 있지 않은 문자열, 'null' 거부.
    버킷 이름과 출력 키는 메시지에서 받아 사용하지 않습니다.
    """
    raise NotImplementedError("TODO 1: validate_job")

def summarize(raw):
    """TODO 2: UTF-8 bytes -> {'total': int, 'pass': int, 'fail': int}.
    최대 65536 bytes, 헤더 device,result, 데이터 1~100행.
    빈 행·누락/초과 열·빈 device·PASS/FAIL 외 값은 ValueError.
    csv.reader(..., strict=True) 사용을 권장합니다.
    """
    raise NotImplementedError("TODO 2: summarize")

def read_source(s3, bucket, job):
    args = {"Bucket": bucket, "Key": job["source_key"], "VersionId": job["source_version"]}
    if s3.head_object(**args)["ContentLength"] > 65536:
        raise ValueError("SOURCE_TOO_LARGE")
    response = s3.get_object(**args)
    try:
        raw = response["Body"].read(65537)
    finally:
        response["Body"].close()
    if len(raw) > 65536:
        raise ValueError("SOURCE_TOO_LARGE")
    return raw

def read_report(s3, bucket, report_key):
    """없는 key만 None. AccessDenied를 객체 없음으로 숨기지 않습니다."""
    from botocore.exceptions import ClientError
    try:
        response = s3.get_object(Bucket=bucket, Key=report_key)
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("NoSuchKey", "404"):
            return None
        raise
    try:
        raw = response["Body"].read(65537)
    finally:
        response["Body"].close()
    if len(raw) > 65536:
        raise ValueError("INVALID_EXISTING_REPORT")
    report = json.loads(raw)
    if not isinstance(report, dict):
        raise ValueError("INVALID_EXISTING_REPORT")
    return report

def match_report(job, report):
    for name in ("job_id", "source_key", "source_version"):
        if report.get(name) != job[name]:
            raise ValueError("JOB_CONFLICT")
    counts = [report.get(name) for name in ("total", "pass", "fail")]
    if any(type(value) is not int for value in counts):
        raise ValueError("INVALID_EXISTING_REPORT")
    total, passed, failed = counts
    if not 1 <= total <= 100 or min(passed, failed) < 0 or passed + failed != total:
        raise ValueError("INVALID_EXISTING_REPORT")
    return report

def get_or_create_report(s3, bucket, job):
    """TODO 3: 기존 보고서 확인 -> 없으면 원본 검증 -> 조건부 최초 쓰기.
    반환값: match_report를 통과한 보고서 dict.
    보고서 필드: job_id, source_key, source_version, total, pass, fail.
    Key는 'reports/' + job['job_id'] + '.json'.
    412: 기존 보고서를 읽어 원본 대조. 409: 짧은 backoff 후 제한 재시도.
    403 등 다른 오류는 그대로 실패. 무조건 put_object로 덮어쓰기 금지.
    처음부터 기존 보고서가 있으면 원본 재집계 없이 DB 복구에 재사용합니다.
    30초 처리 예산을 지키도록 재시도 횟수를 제한합니다.
    """
    raise NotImplementedError("TODO 3: get_or_create_report")

def process_message(message, s3, table, sqs, bucket, queue_url):
    job = validate_job(message["Body"])
    report = match_report(job, get_or_create_report(s3, bucket, job))
    report_key = "reports/" + job["job_id"] + ".json"
    table.put_item(Item={**report, "status": "DONE", "report_key": report_key})
    # 이 줄은 보고서와 DB가 모두 성공해야 도달합니다.
    sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=message["ReceiptHandle"])
    print("JOB_DONE", job["job_id"], flush=True)

def main():
    import boto3
    from botocore.config import Config
    required = ("QUEUE_URL", "BUCKET_NAME", "TABLE_NAME", "AWS_REGION")
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise ValueError("missing environment variables: " + ",".join(missing))
    region = os.environ["AWS_REGION"]
    # long polling은 20초이므로 SQS read timeout은 그보다 길게 설정합니다.
    sqs = boto3.client("sqs", region_name=region,
                       config=Config(connect_timeout=5, read_timeout=25,
                                     retries={"total_max_attempts": 1}))
    data_config = Config(connect_timeout=3, read_timeout=3,
                         retries={"total_max_attempts": 1})
    s3 = boto3.client("s3", region_name=region, config=data_config)
    table = boto3.resource("dynamodb", region_name=region,
                           config=data_config).Table(os.environ["TABLE_NAME"])
    print("WORKER_READY", flush=True)
    while True:
        try:
            messages = sqs.receive_message(
                QueueUrl=os.environ["QUEUE_URL"], MaxNumberOfMessages=1,
                WaitTimeSeconds=20, VisibilityTimeout=180,
            ).get("Messages", [])
        except Exception as exc:
            print("POLL_FAILED", type(exc).__name__, flush=True)
            time.sleep(2)
            continue
        for message in messages:
            try:
                process_message(message, s3, table, sqs,
                                os.environ["BUCKET_NAME"], os.environ["QUEUE_URL"])
            except Exception as exc:
                # 본문·토큰·자격증명은 출력하지 않습니다. 메시지는 삭제하지 않습니다.
                reason = str(exc)
                allowed = {"JOB_CONFLICT", "INVALID_SIZE", "INVALID_HEADER", "INVALID_ROW",
                           "EMPTY_DATA", "TOO_MANY_ROWS", "SOURCE_TOO_LARGE",
                           "INVALID_EXISTING_REPORT"}
                print("JOB_FAILED", reason if reason in allowed else type(exc).__name__, flush=True)

if __name__ == "__main__":
    main()
