import boto3
import json
import os
from botocore.config import Config

s3 = boto3.client("s3")

# boto3 stops waiting for a response after 60 seconds by default, which
# would cut off a long lecture even though the Lambda itself is allowed
# 300 seconds. 290 leaves a little room before the Lambda's own limit.
# max_attempts = 1 stops it silently retrying a slow call, which would
# also run past the Lambda's limit.
bedrock = boto3.client(
    "bedrock-runtime",
    config=Config(read_timeout=290, retries={"max_attempts": 1}),
)

MODEL_ID = os.environ["MODEL_ID"]
PROCESSED_BUCKET = os.environ["PROCESSED_BUCKET"]

def handler(event, context):
    job_name = event["transcribeResult"]["TranscriptionJobName"]
    language_code = event["language_code"]

    transcript_key = f"transcripts/{job_name}.json"
    obj = s3.get_object(Bucket=PROCESSED_BUCKET, Key=transcript_key)
    transcript_data = json.loads(obj["Body"].read())
    transcript_text = transcript_data["results"]["transcripts"][0]["transcript"]

    prompt = f"""You are producing study notes for an e-learning platform.
The following is a raw speech-to-text transcript of an instructional video,
in {language_code}. The transcript may contain minor transcription errors,
filler words, repeated phrases, or occasionally a rough/garbled patch where
the transcription model mis-heard a word or phrase - use context to work
around any such rough patches rather than treating them literally.

If the transcript is not already in English, translate the content into
English as you write the notes - the final output must be entirely in
English regardless of the source language.

Produce the study notes in this exact structure, using Markdown formatting:

# <A short, descriptive title for the video's topic>

## Summary
<A 2-4 sentence overview of what the video covers>

## Key Topics
<For each major topic discussed, a "### <topic name>" heading, followed by
2-5 bullet points covering the important points made about that topic, in
the order they were discussed>

Write only the study notes themselves - no preamble, no meta-commentary
about the transcript, no closing remarks.

Transcript:
{transcript_text}
"""

    response = bedrock.converse(
        modelId=MODEL_ID,
        messages=[
            {"role": "user", "content": [{"text": prompt}]}
        ]
    )

    notes_text = response["output"]["message"]["content"][0]["text"]

    return {"notes": notes_text}