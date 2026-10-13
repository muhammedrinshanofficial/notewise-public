import boto3
import os
import re
import time

transcribe = boto3.client("transcribe")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TOKEN_TABLE"])

# Transcribe's MediaFormat values. The file's extension decides which one.
ALLOWED_MEDIA_FORMATS = {"mp4", "mp3", "wav", "m4a", "flac", "ogg", "amr", "webm"}

def handler(event, context):
    task_token = event["TaskToken"]
    input_key = event["input_key"]
    language_code = event["language_code"]
    video_id = event["video_id"]

    # Build a readable job name from the video's own filename, plus
    # video_id to guarantee uniqueness (Transcribe job names must be
    # unique account-wide, forever - a plain filename would collide
    # on any re-test using the same name). Transcribe only allows
    # 0-9a-zA-Z._- in job names, so strip anything else.
    base_name = os.path.splitext(os.path.basename(input_key))[0]
    base_name = re.sub(r"[^0-9a-zA-Z._-]", "_", base_name)[:100]
    job_name = f"{base_name}-{video_id}"

    # Transcribe must be told the file format. It comes from the file's
    # extension (get_upload_url only lets these through).
    media_format = os.path.splitext(input_key)[1].lstrip(".").lower()
    if media_format not in ALLOWED_MEDIA_FORMATS:
        raise ValueError(f"Unsupported media format: {media_format!r}")

    transcribe.start_transcription_job(
        TranscriptionJobName=job_name,
        Media={
            "MediaFileUri": f"s3://{os.environ['INPUT_BUCKET']}/{input_key}"
        },
        MediaFormat=media_format,
        LanguageCode=language_code,
        OutputBucketName=os.environ["OUTPUT_BUCKET"],
        OutputKey=f"transcripts/{job_name}.json"
    )

    # expires_at is a Unix timestamp in seconds. The state machine gives up
    # on Transcribe after 3600 s, so 2 hours leaves a safe margin. DynamoDB
    # deletes the row some time after this passes (usually within hours).
    table.put_item(Item={
        "job_name": job_name,
        "task_token": task_token,
        "expires_at": int(time.time()) + 7200
    })