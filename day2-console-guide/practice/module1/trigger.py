import json
import os
from urllib.parse import unquote_plus
import boto3

sfn = boto3.client("stepfunctions")

def lambda_handler(event, context):
    started = []
    for record in event.get("Records", []):
        key = unquote_plus(record["s3"]["object"]["key"])
        if key.startswith("input/") and key.endswith(".csv"):
            result = sfn.start_execution(
                stateMachineArn=os.environ["STATE_MACHINE_ARN"],
                input=json.dumps({"key": key}),
            )
            started.append(result["executionArn"])
    return {"started": started}
