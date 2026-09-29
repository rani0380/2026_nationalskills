import base64
import json
import os
import boto3

s3 = boto3.client("s3")
sns = boto3.client("sns")

def handler(event, context):
    count = 0
    for batch in event.get("records", {}).values():
        for message in batch:
            record = json.loads(base64.b64decode(message["value"]))
            stamp = record["timestamp"]
            key = f"alert/{record['sensorId']}/{stamp[:10]}/{stamp}.json"
            body = json.dumps(record, ensure_ascii=False)
            s3.put_object(Bucket=os.environ["S3_BUCKET"], Key=key,
                          Body=body.encode(), ContentType="application/json")
            sns.publish(TopicArn=os.environ["SNS_TOPIC_ARN"],
                        Subject=f"Sensor alert {record['sensorId']}", Message=body)
            print(json.dumps({"saved": key}))
            count += 1
    return {"processed": count}
