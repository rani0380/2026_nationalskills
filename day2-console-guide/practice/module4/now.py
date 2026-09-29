import os
import hmac
from datetime import datetime, timezone, timedelta

def lambda_handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    expected = os.environ["ORIGIN_SECRET"]
    supplied = headers.get("x-origin-verify", "")
    if not expected or not hmac.compare_digest(supplied, expected):
        return {"statusCode": 403, "body": "Forbidden"}
    now = datetime.now(timezone(timedelta(hours=9)))
    text = (f"현재 시간은 {now.year}년 {now.month}월 {now.day}일 "
            f"{now.hour}시 {now.minute}분 {now.second}초입니다.")
    return {"statusCode": 200,
            "headers": {"Content-Type": "text/plain; charset=utf-8",
                        "Cache-Control": "no-store"},
            "body": text}
