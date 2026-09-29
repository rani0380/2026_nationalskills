import base64
import json
import logging
import math
import os
import re
import time
import uuid
from datetime import datetime, timezone

import boto3
import pymysql
from botocore.config import Config

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

DB_HOST = os.environ["DB_HOST"]
DB_PORT = int(os.environ.get("DB_PORT", ""))
DB_NAME = os.environ.get("DB_NAME", "")
DB_USER = os.environ.get("DB_USER", "")
DB_SECRET_NAME = os.environ.get("DB_SECRET_NAME", "")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
TABLE_NAME = os.environ.get("TABLE_NAME", "")
HEALTH_PATH = os.environ.get("HEALTH_PATH", "/healthz")

# The table name cannot be a bound parameter, so it is whitelisted instead.
if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", TABLE_NAME):
    raise ValueError(f"invalid TABLE_NAME {TABLE_NAME!r}")

INSERT_SQL = (
    f"INSERT INTO `{TABLE_NAME}` "
    "(`id`, `device_id`, `metric`, `value`, `recorded_at`, `created_at`) "
    "VALUES (%s, %s, %s, %s, %s, %s)"
)

MAX_DEVICE_ID = 64  # VARCHAR(64)
MAX_METRIC = 64     # VARCHAR(64)

# Reused across invocations while the execution environment is warm.
_connection = None
_credentials = None


# ── credentials ────────────────────────────────────────────────────────────
# Without these, a blocked route to Secrets Manager hangs for 60s per attempt and
# the function hits its own timeout with nothing useful in the log.
SECRETS_CONFIG = Config(
    connect_timeout=2,
    read_timeout=3,
    retries={"max_attempts": 1, "mode": "standard"},
)


def _resolve_credentials():
    """Return (user, password), preferring Secrets Manager over the env var."""
    global _credentials
    if _credentials is not None:
        return _credentials

    if DB_SECRET_NAME:
        started = time.monotonic()
        client = boto3.client("secretsmanager", config=SECRETS_CONFIG)
        secret = client.get_secret_value(SecretId=DB_SECRET_NAME)
        LOG.info("secret %s resolved in %d ms", DB_SECRET_NAME,
                 (time.monotonic() - started) * 1000)
        parsed = json.loads(secret["SecretString"])
        _credentials = (parsed.get("username") or DB_USER, parsed["password"])
    else:
        _credentials = (DB_USER, DB_PASSWORD)
    return _credentials


# ── connection ─────────────────────────────────────────────────────────────
def _connect():
    global _connection
    if _connection is not None:
        try:
            _connection.ping(reconnect=True)
            return _connection
        except pymysql.MySQLError:
            _connection = None

    user, password = _resolve_credentials()
    started = time.monotonic()
    _connection = pymysql.connect(
        host=DB_HOST,
        port=DB_PORT,
        user=user,
        password=password,
        database=DB_NAME,
        charset="utf8mb4",
        autocommit=True,
        connect_timeout=5,
        read_timeout=10,
        write_timeout=10,
    )
    LOG.info("connected to %s:%d/%s in %d ms", DB_HOST, DB_PORT, DB_NAME,
             (time.monotonic() - started) * 1000)
    return _connection


def _drop_credentials():
    global _credentials
    _credentials = None


def _drop_connection():
    global _connection
    if _connection is not None:
        try:
            _connection.close()
        except Exception:  # noqa: BLE001 — closing a broken socket may raise anything
            pass
        _connection = None


# ── request parsing ────────────────────────────────────────────────────────
def _payload(event):
    """Accept a direct Invoke payload as well as an API Gateway proxy event."""
    if not isinstance(event, dict):
        raise ValueError("request body must be a JSON object")

    if "body" in event:
        body = event["body"]
        if body is None:
            raise ValueError("request body is empty")
        if event.get("isBase64Encoded"):
            body = base64.b64decode(body)
        # ALB sends an empty string rather than omitting the field.
        if isinstance(body, (bytes, str)) and not body.strip():
            raise ValueError("request body is empty")
        if isinstance(body, (bytes, str)):
            try:
                body = json.loads(body)
            except json.JSONDecodeError as exc:
                raise ValueError(f"request body is not valid JSON: {exc}") from exc
        event = body

    if not isinstance(event, dict):
        raise ValueError("request body must be a JSON object")
    return event


def _text(payload, field, limit):
    value = payload.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} is required and must be a non-empty string")
    value = value.strip()
    if len(value) > limit:
        raise ValueError(f"{field} must be at most {limit} characters")
    return value


def _number(payload, field):
    value = payload.get(field)
    if isinstance(value, bool) or value is None:
        raise ValueError(f"{field} is required and must be a number")
    if isinstance(value, str):
        try:
            value = float(value)
        except ValueError as exc:
            raise ValueError(f"{field} must be a number") from exc
    if not isinstance(value, (int, float)):
        raise ValueError(f"{field} must be a number")
    value = float(value)
    if math.isnan(value) or math.isinf(value):
        raise ValueError(f"{field} must be a finite number")
    return value


# ALB rejects a response that is missing any of these fields with a 502.
STATUS_TEXT = {
    200: "200 OK",
    201: "201 Created",
    400: "400 Bad Request",
    405: "405 Method Not Allowed",
    502: "502 Bad Gateway",
}


def _response(status, body):
    return {
        "statusCode": status,
        "statusDescription": STATUS_TEXT.get(status, str(status)),
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
        "isBase64Encoded": False,
    }


def _method(event):
    """ALB and API Gateway v1 use httpMethod; v2 / Function URL nest it."""
    if not isinstance(event, dict):
        return "POST"
    if "httpMethod" in event:
        return str(event["httpMethod"]).upper()
    http = event.get("requestContext", {}).get("http", {}) if isinstance(
        event.get("requestContext"), dict) else {}
    if "method" in http:
        return str(http["method"]).upper()
    return "POST"  # direct Invoke carries no method


def _path(event):
    if not isinstance(event, dict):
        return ""
    if "path" in event:
        return str(event["path"])
    http = event.get("requestContext", {}).get("http", {}) if isinstance(
        event.get("requestContext"), dict) else {}
    return str(http.get("path", ""))


# ── handler ────────────────────────────────────────────────────────────────
def lambda_handler(event, context):
    method = _method(event)

    # Target group health check — never touches the database, so a database
    # outage does not take the target out of service on its own.
    if method in ("GET", "HEAD") and _path(event) == HEALTH_PATH:
        return _response(200, {"status": "ok", "service": "ingest"})

    if method != "POST":
        return _response(405, {"error": "method not allowed"})

    try:
        payload = _payload(event)
        device_id = _text(payload, "device_id", MAX_DEVICE_ID)
        metric = _text(payload, "metric", MAX_METRIC)
        value = _number(payload, "value")
    except ValueError as exc:
        return _response(400, {"error": str(exc)})

    reading_id = str(uuid.uuid4())
    # Both columns are DATETIME (no time zone). The reader treats them as UTC,
    # so they are stamped here rather than left to the server's CURRENT_TIMESTAMP.
    now = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)

    try:
        connection = _connect()
    except pymysql.MySQLError as exc:
        _drop_connection()
        LOG.exception("cannot connect to %s:%d/%s", DB_HOST, DB_PORT, DB_NAME)
        return _response(502, {"error": f"database connection failed: {exc}"})
    except Exception as exc:  # noqa: BLE001 — Secrets Manager / IAM / network
        _drop_credentials()
        _drop_connection()
        LOG.exception("cannot resolve database credentials")
        return _response(502, {"error": f"cannot resolve database credentials: {exc}"})

    try:
        with connection.cursor() as cursor:
            cursor.execute(
                INSERT_SQL, (reading_id, device_id, metric, value, now, now)
            )
    except pymysql.MySQLError as exc:
        _drop_connection()
        LOG.exception("insert failed for device_id=%s metric=%s", device_id, metric)
        return _response(502, {"error": f"database write failed: {exc}"})

    LOG.info("inserted id=%s device_id=%s metric=%s", reading_id, device_id, metric)
    return _response(
        201,
        {
            "id": reading_id,
            "device_id": device_id,
            "metric": metric,
            "value": value,
            "recorded_at": now.isoformat() + "Z",
            "created_at": now.isoformat() + "Z",
        },
    )
