import hashlib
import os
from urllib.parse import unquote_plus, quote
import boto3

cf = boto3.client("cloudfront")

def lambda_handler(event, context):
    results = []
    for record in event.get("Records", []):
        obj = record["s3"]["object"]
        key = unquote_plus(obj["key"])
        if not key.startswith("static/"):
            continue
        marker = "|".join([record["s3"]["bucket"]["name"], key,
                           obj.get("versionId", ""), obj.get("sequencer", "")])
        caller = hashlib.sha256(marker.encode()).hexdigest()
        response = cf.create_invalidation(
            DistributionId=os.environ["DISTRIBUTION_ID"],
            InvalidationBatch={"Paths": {"Quantity": 1,
                "Items": ["/" + quote(key, safe="/")]},
                "CallerReference": caller})
        results.append(response["Invalidation"]["Id"])
    return {"invalidations": results}
