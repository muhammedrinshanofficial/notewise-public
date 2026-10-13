import boto3
import json
import os

sfn = boto3.client("stepfunctions")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TOKEN_TABLE"])

def handler(event, context):
    detail = event["detail"]
    job_name = detail["TranscriptionJobName"]

    item = table.get_item(Key={"job_name": job_name}).get("Item")
    if item is None:
        # Job wasn't started by the pipeline (e.g. a manual console test)
        print(f"No task token for job {job_name} - ignoring")
        return

    task_token = item["task_token"]

    try:
        if detail["TranscriptionJobStatus"] == "COMPLETED":
            sfn.send_task_success(taskToken=task_token, output=json.dumps(detail))
        else:
            sfn.send_task_failure(
                taskToken=task_token,
                error="TranscribeJobFailed",
                cause=json.dumps(detail)
            )
    except (sfn.exceptions.TaskTimedOut, sfn.exceptions.TaskDoesNotExist):
        # The execution already timed out or was stopped - nothing to wake up
        print(f"Task for job {job_name} no longer waiting - skipping callback")

    table.delete_item(Key={"job_name": job_name})