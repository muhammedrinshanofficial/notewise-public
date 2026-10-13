import json
import os

import boto3
from boto3.dynamodb.conditions import Key
from botocore.config import Config
from botocore.exceptions import ClientError

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["COURSE_METADATA_TABLE"])

s3 = boto3.client(
    "s3",
    region_name=os.environ["AWS_REGION"],
    config=Config(signature_version="s3v4"),
)

PROCESSED_BUCKET = os.environ["PROCESSED_BUCKET"]
URL_EXPIRY_SECONDS = 300


def response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def pdf_exists(pdf_key):
    # The clean-up rule (Step 12) deletes old PDFs, but the course_metadata
    # row stays COMPLETE. Asking S3 whether the file is still there lets the
    # page show "Expired" instead of a Download button that fails. A missing
    # file only answers "not found" because this role may list the processed
    # bucket (status_api_list_processed in main.tf).
    try:
        s3.head_object(Bucket=PROCESSED_BUCKET, Key=pdf_key)
        return True
    except ClientError as err:
        if err.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
            return False
        raise


def handler(event, context):
    params = event.get("queryStringParameters") or {}
    input_key = params.get("key", "")

    if not input_key:
        return response(400, {"error": "Missing 'key' query parameter"})

    result = table.query(
        IndexName="input_key-index",
        KeyConditionExpression=Key("input_key").eq(input_key),
        Limit=1
    )
    items = result.get("Items", [])

    if not items:
        return response(404, {"error": "No upload found for this reference"})

    item = items[0]
    status = item.get("status", "PROCESSING")
    body = {"status": status}

    if status == "COMPLETE" and "pdf_key" in item:
        if not pdf_exists(item["pdf_key"]):
            body["status"] = "EXPIRED"
        else:
            filename = os.path.basename(item["pdf_key"])
            body["download_url"] = s3.generate_presigned_url(
                "get_object",
                Params={
                    "Bucket": PROCESSED_BUCKET,
                    "Key": item["pdf_key"],
                    # Makes the browser download the file instead of opening it,
                    # so clicking "Download PDF" doesn't navigate away from the page.
                    "ResponseContentDisposition": f'attachment; filename="{filename}"',
                },
                ExpiresIn=URL_EXPIRY_SECONDS,
            )
    elif status == "FAILED":
        body["error"] = item.get("error_info", "Processing failed")

    return response(200, body)