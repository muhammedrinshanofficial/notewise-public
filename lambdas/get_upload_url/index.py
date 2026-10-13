import json
import os
import re
import uuid

import boto3
from botocore.config import Config

# Signature version 4 + the Lambda's own region, so the signed form
# points at the correct regional S3 endpoint.
s3 = boto3.client(
    "s3",
    region_name=os.environ["AWS_REGION"],
    config=Config(signature_version="s3v4"),
)

RAW_BUCKET = os.environ["RAW_BUCKET"]
# Keep this list in step with the language dropdown in frontend/index.html.
ALLOWED_LANGUAGES = {"en-US", "ml-IN", "hi-IN", "ta-IN", "es-ES", "fr-FR"}
# Formats Amazon Transcribe can read directly. Keep this list in step with
# submit_transcribe_job, worker/validate.py and frontend/index.html.
ALLOWED_EXTENSIONS = (".mp4", ".mp3", ".wav", ".m4a", ".flac", ".ogg", ".amr", ".webm")
URL_EXPIRY_SECONDS = 300

# Largest video S3 will accept through the signed upload form. The page
# and the preprocessing container check the same 2 GB, but this one is
# enforced by S3 itself, so it cannot be bypassed.
MAX_UPLOAD_BYTES = 2 * 1024 ** 3


def response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event, context):
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return response(400, {"error": "Request body must be valid JSON"})

    filename = body.get("filename", "")
    language_code = body.get("language_code", "")

    if language_code not in ALLOWED_LANGUAGES:
        return response(400, {
            "error": f"language_code must be one of {sorted(ALLOWED_LANGUAGES)}"
        })

    if not filename.lower().endswith(ALLOWED_EXTENSIONS):
        return response(400, {
            "error": "Unsupported file type. Allowed: " + ", ".join(ALLOWED_EXTENSIONS)
        })

    # Same character rule Transcribe job names need: 0-9a-zA-Z._-
    safe_name = re.sub(r"[^0-9a-zA-Z._-]", "_", os.path.basename(filename))[-100:]
    key = f"{uuid.uuid4()}/{safe_name}"

    # A signed upload FORM (presigned POST) instead of a plain signed link.
    # The rules inside it are checked by S3 on every upload:
    #   - content-length-range: the file must be 1 byte to 2 GB
    #   - the language metadata must be exactly the value chosen here, so
    #     the browser cannot change it after the link is issued
    # The language is stored as S3 object metadata, which is exactly what
    # the dispatcher Lambda already reads with head_object.
    post = s3.generate_presigned_post(
        Bucket=RAW_BUCKET,
        Key=key,
        Fields={"x-amz-meta-language-code": language_code},
        Conditions=[
            {"x-amz-meta-language-code": language_code},
            ["content-length-range", 1, MAX_UPLOAD_BYTES],
        ],
        ExpiresIn=URL_EXPIRY_SECONDS,
    )

    # "fields" replaces the old "required_headers": the browser sends
    # these as form fields, then the file itself as the last field.
    return response(200, {
        "upload_url": post["url"],
        "fields": post["fields"],
        "key": key,
    })