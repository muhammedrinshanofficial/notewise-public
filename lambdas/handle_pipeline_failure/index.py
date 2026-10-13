import boto3
import os

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["COURSE_METADATA_TABLE"])

def handler(event, context):
    video_id = event.get("video_id")
    if not video_id:
        # Shouldn't happen - every execution starts with video_id set
        print("No video_id in failure event - nothing to update")
        return {"handled": False}

    error = event.get("error", {})
    table.update_item(
        Key={"video_id": video_id},
        UpdateExpression="SET #s = :status, error_info = :error",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":status": "FAILED",
            ":error": str(error)
        }
    )
    return {"handled": True}