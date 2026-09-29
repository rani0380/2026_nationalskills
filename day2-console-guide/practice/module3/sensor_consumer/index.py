import base64
import json
import os
from datetime import datetime, timezone, timedelta
from decimal import Decimal
import boto3
from kafka import KafkaProducer
from kafka.sasl.oauth import AbstractTokenProvider
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider

REGION = os.environ["AWS_REGION"]
TABLE = boto3.resource("dynamodb").Table(os.environ["DDB_TABLE"])
KST = timezone(timedelta(hours=9))

class TokenProvider(AbstractTokenProvider):
    def token(self):
        token, _ = MSKAuthTokenProvider.generate_auth_token(REGION)
        return token

_producer = None

def get_producer():
    global _producer
    if _producer is None:
        _producer = KafkaProducer(
            bootstrap_servers=os.environ["BOOTSTRAP_SERVER"].split(","),
            security_protocol="SASL_SSL",
            sasl_mechanism="OAUTHBEARER",
            sasl_oauth_token_provider=TokenProvider(),
            acks="all", retries=3,
            request_timeout_ms=15000, max_block_ms=15000,
            value_serializer=lambda value: json.dumps(value, ensure_ascii=False).encode(),
            key_serializer=lambda value: value.encode(),
        )
    return _producer

def normalize_timestamp(value):
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        raise ValueError("timestamp must have a timezone")
    return dt.astimezone(KST).isoformat(timespec="seconds")

def classify(record):
    t, h = float(record["temperature"]), float(record["humidity"])
    reasons = []
    if t > 80: reasons.append(f"Temperature exceeded threshold: {t}°C")
    if t < 10: reasons.append(f"Temperature below threshold: {t}°C")
    if h > 90: reasons.append(f"Humidity exceeded threshold: {h}%")
    if h < 20: reasons.append(f"Humidity below threshold: {h}%")
    return reasons

def handler(event, context):
    count = 0
    for batch in event.get("records", {}).values():
        for message in batch:
            record = json.loads(base64.b64decode(message["value"]))
            record["timestamp"] = normalize_timestamp(record["timestamp"])
            reasons = classify(record)
            if reasons:
                record["status"] = "ALERT"
                record["alert_reason"] = "; ".join(reasons)
                get_producer().send(
                    os.environ["ALERT_TOPIC"],
                    key=record["sensorId"], value=record,
                ).get(timeout=20)
            else:
                TABLE.put_item(Item={
                    "sensorId": record["sensorId"],
                    "timestamp": record["timestamp"],
                    "temperature": str(record["temperature"]),
                    "humidity": Decimal(str(record["humidity"])),
                    "location": record["location"], "status": "NORMAL",
                })
            print(json.dumps({"sensorId": record["sensorId"],
                              "status": "ALERT" if reasons else "NORMAL"}))
            count += 1
    return {"processed": count}
