import json
import os
import boto3

iam = boto3.client("iam")
s3 = boto3.client("s3")
sns = boto3.client("sns")

def lambda_handler(event, context):
    role = os.environ["PROTECTED_ROLE_NAME"]
    body = s3.get_object(Bucket=os.environ["BACKUP_BUCKET"], Key=os.environ["BACKUP_KEY"])["Body"].read()
    policy = json.loads(body)
    iam.update_assume_role_policy(RoleName=role, PolicyDocument=json.dumps(policy))
    message = {"status": "remediated", "role": role, "event": event.get("detail", {}).get("eventName")}
    sns.publish(TopicArn=os.environ["SNS_TOPIC_ARN"], Subject="IAM trust policy remediated", Message=json.dumps(message))
    print(json.dumps(message))
    return message
