import json
import os
import subprocess
import sys

import boto3
from botocore.config import Config

# Same limits the web page already checks. The page can be bypassed,
# so this is the check that actually enforces them.
MAX_BYTES = 2 * 1024 ** 3
MAX_SECONDS = 4 * 60 * 60


def fail(message):
    # Printed to CloudWatch Logs, then a non-zero exit code tells ECS
    # (and so Step Functions) that this stage failed.
    print(f"VALIDATION FAILED: {message}", flush=True)
    sys.exit(1)


def main():
    bucket = os.environ["INPUT_BUCKET"]
    key = os.environ["INPUT_KEY"]

    s3 = boto3.client(
        "s3",
        region_name=os.environ["AWS_REGION"],
        config=Config(signature_version="s3v4"),
    )

    # Check 1: file size (asks S3 only for the file's info, no download)
    size = s3.head_object(Bucket=bucket, Key=key)["ContentLength"]
    print(f"Checking s3://{bucket}/{key} ({size} bytes)", flush=True)
    if size == 0:
        fail("the file is empty")
    if size > MAX_BYTES:
        fail("the file is larger than 2 GB")

    # Check 2: ask ffprobe to read the video's header through a
    # short-lived signed link, so the whole file is never downloaded.
    url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket, "Key": key},
        ExpiresIn=600,
    )
    try:
        result = subprocess.run(
            [
                "ffprobe", "-v", "error",
                "-show_entries", "format=duration:stream=codec_type",
                "-of", "json",
                url,
            ],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        fail("reading the video header took too long")

    if result.returncode != 0:
        # The signed link is hidden so it never lands in the logs.
        print(result.stderr.replace(url, "<signed-url>"), flush=True)
        fail("the file is not a readable audio or video file")

    info = json.loads(result.stdout)
    streams = info.get("streams", [])

    # Audio-only files (mp3, wav, ...) have no video track, so only the
    # audio track is required.
    if not any(s.get("codec_type") == "audio" for s in streams):
        fail("the file has no audio track, so there is nothing to transcribe")

    try:
        duration = float(info["format"]["duration"])
    except (KeyError, ValueError):
        # Some formats (a browser-recorded .webm, for example) do not store
        # the duration in the header. Transcribe still enforces its own
        # 4 hour limit, so the file is not rejected here.
        duration = None
        print("Duration not stored in the file - skipping the duration check", flush=True)

    if duration is not None and duration > MAX_SECONDS:
        fail("the recording is longer than 4 hours")

    if duration is None:
        print("Validation passed: has audio, duration unknown", flush=True)
    else:
        print(f"Validation passed: {duration:.0f} seconds, has audio", flush=True)


main()