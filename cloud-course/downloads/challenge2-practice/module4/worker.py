import os
import time
import boto3

sqs = boto3.client("sqs", region_name=os.getenv("AWS_REGION", "ap-northeast-2"))
queue_url = os.environ["SQS_QUEUE_URL"]
delay = int(os.getenv("PROCESSING_SECONDS", "5"))

while True:
    result = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=1, WaitTimeSeconds=10)
    for message in result.get("Messages", []):
        print("processing", message["MessageId"], flush=True)
        time.sleep(delay)
        sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=message["ReceiptHandle"])
        print("completed", message["MessageId"], flush=True)
