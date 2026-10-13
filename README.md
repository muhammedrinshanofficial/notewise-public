# Notewise: lecture recordings to PDF study notes on AWS

Notewise is an event-driven pipeline on Amazon Web Services. A user opens a hosted web page, uploads a lecture video or audio file and chooses the language spoken in it. No manual step follows: the file is validated in a container, transcribed with Amazon Transcribe, turned into structured English notes by Claude Sonnet 4.6 on Amazon Bedrock, and rendered as a PDF. The page shows live status and a short-lived download link.

Everything is created with Terraform. This README explains every step needed to deploy your own copy.

> **Status.** The project was built and tested in the author's own AWS account. The steps below follow that deployment, but a full deployment from nothing, in a clean account, has not been run end to end yet. Read the "Known limits" section before you start.

## Contents

1. [What it does](#what-it-does)
2. [How it works](#how-it-works)
3. [Repository layout](#repository-layout)
4. [Before you start](#before-you-start)
5. [Placeholders used in this repository](#placeholders-used-in-this-repository)
6. [Deployment guide](#deployment-guide)
7. [Using the system](#using-the-system)
8. [Optional: automatic deployment with GitHub Actions](#optional-automatic-deployment-with-github-actions)
9. [Costs and safety](#costs-and-safety)
10. [Changing what the system accepts](#changing-what-the-system-accepts)
11. [Troubleshooting](#troubleshooting)
12. [Clean-up](#clean-up)
13. [Known limits](#known-limits)
14. [License](#license)

## What it does

- **Input:** video or audio in eight formats (MP4, MP3, WAV, M4A, FLAC, OGG, AMR, WEBM), up to 2 GB and 4 hours (limits of Amazon Transcribe).
- **Spoken languages:** English (`en-US`), Malayalam (`ml-IN`), Hindi (`hi-IN`), Tamil (`ta-IN`), Spanish (`es-ES`), French (`fr-FR`). The user picks one at upload.
- **Output:** a PDF in English with a title, a summary and key topics.
- **No accounts and no login.** Request throttling and an AWS Budgets cutoff are the cost safeguards.

## How it works

```
Browser -> CloudFront -> S3 (frontend)              page loads
Browser -> API Gateway -> get_upload_url            gets a signed upload form
Browser -> S3 raw_video                             file uploaded directly
S3 event -> dispatch_pipeline -> Step Functions + DynamoDB row
Step Functions: ECS validate -> Transcribe -> Bedrock -> render_pdf
EventBridge wakes Step Functions when Transcribe finishes
Browser -> API Gateway -> get_status -> DynamoDB + S3 -> download link
```

1. **PreprocessValidate (ECS Fargate).** Checks size, that `ffprobe` can read the file, that it has an audio track and that it is not longer than 4 hours. A bad file fails here, before anything costs money. Retried once, because Fargate sometimes cannot pull the image.
2. **TranscribeAudio.** A Lambda starts the Transcribe job and stores a Step Functions task token in DynamoDB. EventBridge reports the finished job, and a second Lambda wakes the run.
3. **GenerateStudyNotes.** A Lambda sends the transcript to Claude through the Bedrock Converse API and gets Markdown notes back.
4. **RenderPdf.** A Lambda builds the PDF with `fpdf2`, stores it in S3 and marks the upload `COMPLETE`.

Any failure goes to `HandlePipelineFailure` (marks the upload `FAILED`), then to a `PipelineFailed` Fail state.

S3 lifecycle rules delete recordings and transcripts after 1 day and PDFs after 2 days (S3 rounds up to midnight UTC, so real lifetimes are 1 to 2 days and 2 to 3 days).

## Repository layout

```
.
|-- README.md
|-- LICENSE
|-- .gitignore
|-- ci/terraform.yml.example         CI/CD workflow template (see the GitHub Actions section)
|-- scripts/build_lambdas.py         builds the Lambda zips the same way every time
|-- terraform/
|   |-- bootstrap/                   one-time: creates the Terraform state bucket (local state)
|   `-- main/                        the project (remote state)
|       |-- main.tf  variables.tf  provider.tf  backend.tf  outputs.tf
|-- worker/
|   |-- Dockerfile                   validation image (Alpine + python3 + boto3 + ffmpeg)
|   `-- validate.py                  the validation checks
|-- frontend/index.html              the web page (one self-contained file)
`-- lambdas/
    |-- get_upload_url/index.py
    |-- dispatch_pipeline/index.py
    |-- submit_transcribe_job/index.py
    |-- handle_transcribe_completion/index.py
    |-- generate_study_notes/index.py
    |-- render_pdf/index.py  requirements.txt
    |-- handle_pipeline_failure/index.py
    `-- get_status/index.py
```

Every Lambda file is called `index.py` because `main.tf` uses `handler = "index.handler"`. The folder name tells them apart. The libraries for `render_pdf` are not stored in Git; you install them in Step 5.

## Before you start

| You need | Notes |
|---|---|
| An AWS account with billing enabled | Everything is deployed in `us-west-2` by default (variable `aws_region`) |
| AWS CLI v2, signed in as a user or role that can create IAM roles, S3, Lambda, ECS, Step Functions, CloudFront and the other services used | Check with `aws sts get-caller-identity` |
| Terraform 1.5 or newer | Tested with 1.16.2; the AWS provider is pinned to `~> 5.0` |
| Docker | Needed to build and push the worker image |
| Python 3.12 and `pip` | Used to install the `render_pdf` libraries and to build the Lambda zips |
| Git | |
| Access to Anthropic Claude Sonnet 4.6 on Amazon Bedrock in `us-west-2` | Open the Bedrock console and make sure the model is available to your account. The first use of Anthropic models may ask for use-case details. The Lambda uses the inference profile ID `us.anthropic.claude-sonnet-4-6` |

Choose a **unique suffix** before you begin: lowercase letters and digits, short (for example your initials plus two digits). S3 bucket names are global, so the suffix is what makes your bucket names unique. You will use the same value in every step.

## Placeholders used in this repository

Personal values were replaced by placeholders before publishing. Replace them with your own values.

| Placeholder | Meaning | Used in |
|---|---|---|
| `<UNIQUE_SUFFIX>` | Your unique suffix (see above) | `terraform/main/backend.tf`, `ci/terraform.yml.example` |
| `<AWS_ACCOUNT_ID>` | Your 12-digit AWS account ID | `ci/terraform.yml.example` |
| `<GITHUB_OWNER>`, `<OWNER_ID>`, `<REPO_NAME>`, `<REPO_ID>` | Your GitHub user or organisation name, its numeric ID, your repository name and its numeric ID | the IAM trust policy in `terraform/main/main.tf` (two lines) |

You can find the account ID with `aws sts get-caller-identity --query Account --output text`. The numeric GitHub IDs are explained in the CI/CD section.

## Deployment guide

Run the commands from the repository root unless a step says otherwise. The commands below use Windows-friendly syntax where it matters; on Linux or macOS, replace backslashes in paths with forward slashes.

### Step 1: Get the code

```
git clone https://github.com/<GITHUB_OWNER>/<REPO_NAME>.git
cd <REPO_NAME>
```

### Step 2: Create the Terraform state bucket (bootstrap)

The main project keeps its state in an S3 bucket. That bucket must exist first, so it is created by a separate, one-time configuration with local state.

```
cd terraform/bootstrap
terraform init
terraform apply -var="unique_suffix=<UNIQUE_SUFFIX>"
```

When it finishes, note the output `state_bucket_name`. Keep the local state file that this step creates (it is ignored by Git); it is only needed if you later destroy the bucket.

### Step 3: Point the main project at that bucket

Open `terraform/main/backend.tf` and set the bucket name to the value of `state_bucket_name`. Terraform backend blocks cannot use variables, so this is typed by hand:

```
bucket = "elearning-pipeline-tfstate-<UNIQUE_SUFFIX>"
```

Also replace the two trust-policy lines in `terraform/main/main.tf` that contain `<GITHUB_OWNER>@<OWNER_ID>/<REPO_NAME>@<REPO_ID>` (see the CI/CD section for how to find the IDs). If you do not plan to use GitHub Actions, you can leave them as they are, but the role will then not be usable by any repository.

### Step 4: Check that the main configuration initialises

```
cd ../main
terraform init
terraform validate
cd ../..
```

`terraform init` connects to the state bucket. If it cannot find the bucket, recheck Step 3.

### Step 5: Install the `render_pdf` libraries

The PDF function needs `fpdf2` and its helpers inside its own folder, because Lambda does not include them. They are not stored in Git. Lambda runs Linux on x86-64 with Python 3.12, so the files must be built for that platform.

On Linux (or in WSL, or GitHub Codespaces):

```
python -m pip install -r lambdas/render_pdf/requirements.txt --target lambdas/render_pdf --no-compile --only-binary=:all:
```

On Windows or macOS, ask pip for the Linux wheels explicitly:

```
python -m pip install -r lambdas/render_pdf/requirements.txt --target lambdas/render_pdf --no-compile --only-binary=:all: --platform manylinux2014_x86_64 --platform manylinux_2_28_x86_64 --python-version 3.12 --implementation cp --abi cp312
```

Check the result: the compiled Pillow file must be a Linux one. List `lambdas/render_pdf/PIL` and confirm that the file named `_imaging...` ends in `linux-gnu.so`. If it ends in `.pyd` or `darwin.so`, the wrong platform was installed, and the PDF function will fail at run time. (The plain Linux command is the one proven by the CI workflow; the cross-platform form has not been tested.)

### Step 6: Build the Lambda zips

```
python scripts/build_lambdas.py
```

This writes one zip per Lambda folder into `lambdas/`. The script fixes timestamps, file order and permissions, so the same code always produces the same zip and Terraform only redeploys functions that really changed. It stops with a message if the Step 5 libraries are missing.

### Step 7: Deploy the infrastructure

```
cd terraform/main
terraform plan -var="unique_suffix=<UNIQUE_SUFFIX>"
terraform apply -var="unique_suffix=<UNIQUE_SUFFIX>"
```

Read the plan before you apply. It creates the VPC, the buckets, the DynamoDB tables, the Lambda functions, the state machine, ECS and ECR resources, the API, CloudFront, the IAM roles and the GitHub OIDC provider. At the end, Terraform prints three outputs:

| Output | Meaning |
|---|---|
| `frontend_url` | The address of the web page |
| `upload_api_url` | The API address (keep it private: there is no login) |
| `github_actions_role_arn` | The role used by GitHub Actions |

If apply stops with `EntityAlreadyExists` for the OIDC provider, another project in the same account already created the GitHub provider. Import it instead of creating it:

```
terraform import aws_iam_openid_connect_provider.github arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com
```

Then run `terraform apply` again.

### Step 8: Build and push the worker image

The state machine runs a container from the ECR repository that Step 7 created. The repository is empty until you push the image, so do this **before your first upload**. The tag must match the Terraform variable `worker_image_tag` (default `v3`).

Run the first command from anywhere, and the other two **from the `worker` folder**:

```
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com
```

```
cd worker
docker build --platform linux/amd64 -t <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/elearning-pipeline-preprocessing-worker:v3 .
docker push <AWS_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/elearning-pipeline-preprocessing-worker:v3
```

`--platform linux/amd64` matters on computers with ARM processors (for example Apple Silicon), because the Fargate task runs on x86-64. Confirm that the tag exists:

```
aws ecr describe-images --repository-name elearning-pipeline-preprocessing-worker --region us-west-2 --query "imageDetails[].imageTags"
```

**When you change the worker later:** push a **new** tag (for example `v4`), keep the old one, and only then change `worker_image_tag` in `terraform/main/variables.tf` and apply. If the task definition names a tag that does not exist, the container cannot start. Rolling back is a one-word change back to the old tag.

### Step 9: Set a budget (recommended)

Transcribe and Bedrock are billed per use, and the page has no login. In the AWS console, open Billing and Cost Management, then Budgets, and create a cost budget with an alert. The original deployment also used a budget action that restricts IAM users at 100%. Budgets are created in the console and are not part of this Terraform code.

### Step 10: Test it

1. Open `frontend_url` in a browser. Do a hard refresh (Ctrl+F5) if you see an old page.
2. Choose a **short** recording (a minute or two) and the language spoken in it. Click **Upload file**.
3. Watch the badge in "Recent uploads". It changes from "Sent for processing" to "Ready" in a few minutes. For deeper checks, open the Step Functions console and look at the execution graph.
4. Click **Download PDF**.

A negative test is also worth doing: rename a small text file to `lecture.mp3` and upload it. It should end as **Failed**, with `VALIDATION FAILED` in the CloudWatch log group `/ecs/elearning-pipeline-preprocessing-worker`, and no Transcribe job should start.

## Using the system

- The page accepts one file at a time, up to 2 GB and 4 hours.
- A PDF is kept for 2 to 3 days, then the page shows **Expired**. Download it soon.
- "Recent uploads" is stored in your own browser only. The reference shown after an upload is the S3 key, and the status API looks the upload up by it.
- Download links last 5 minutes and are created fresh at every click.

## Optional: automatic deployment with GitHub Actions

The workflow template is in `ci/terraform.yml.example`. With it, a pull request into `main` runs checks and `terraform plan`, and a merge to `main` runs `terraform apply`. GitHub signs in to AWS with a short-lived OIDC token, so no AWS keys are stored in GitHub.

> **Use a private repository for this.** The CI role has `AdministratorAccess`, because Terraform creates IAM roles and many other resources. Do not run this workflow in a public repository without first narrowing that role (see "Known limits").

1. **Create your own repository** and push this code to it. Do not use a fork if you want it private.
2. **Find the numeric IDs** (for repositories created on or after 15 July 2026, GitHub puts them in the OIDC token's subject):
   ```
   gh api users/<GITHUB_OWNER> --jq .id
   gh api repos/<GITHUB_OWNER>/<REPO_NAME> --jq .id
   ```
   The first command prints `<OWNER_ID>` and the second prints `<REPO_ID>`. For older repositories the subject is the shorter name-only form `repo:<GITHUB_OWNER>/<REPO_NAME>:...`. If the sign-in step fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`, the subject in the trust policy does not match the token.
3. **Update the trust policy** in `terraform/main/main.tf` (two lines, the `main` branch and `pull_request`), then apply it **from your own computer**. CI cannot assume a role that does not exist yet, or one whose trust policy it is locked out of:
   ```
   cd terraform/main
   terraform apply -var="unique_suffix=<UNIQUE_SUFFIX>"
   ```
4. **Install the workflow:**
   ```
   mkdir .github\workflows
   copy ci\terraform.yml.example .github\workflows\terraform.yml
   ```
   Open the new file and replace `<AWS_ACCOUNT_ID>` and `<UNIQUE_SUFFIX>`. They appear in the role ARN and in the `-var="unique_suffix=..."` option of the plan and apply steps.
5. **Run `terraform fmt -recursive`** from the `terraform` folder before every commit. The workflow fails on unformatted files.
6. Push a branch, open a pull request, read the plan in the run, merge, and CI applies it.

Working rules that keep this safe: every change goes through a branch and a pull request; the worker image is built and pushed by hand (CI does not build it); and the first deployment and any change to the CI role's trust policy are applied locally.

## Costs and safety

- **Cost follows the amount of audio, not idle time.** Nothing here runs when idle: no servers, no NAT Gateway, no provisioned databases. In the author's testing, about 85% of the money went to Transcribe (billed by audio length) and Bedrock (billed by tokens). Everything else together was small.
- **Safeguards:** API throttle of 2 requests per second (burst 5); the 2 GB and 4 hour limits enforced in the page, in S3 itself and in the container; early rejection of invalid files; lifecycle clean-up; a budget alert.
- **Security design:** all buckets private and encrypted; the frontend bucket readable only through CloudFront (Origin Access Control); each component has its own IAM role; upload forms and download links last 5 minutes; the container's security group has no inbound rules.
- **There is no authentication.** Anyone who knows the page address can upload. Keep the address private, keep the throttle and the budget, and add a login (a shared access code or Amazon Cognito) before sharing it widely.

## Changing what the system accepts

**Add a spoken language.** The language code only travels through the pipeline as text. Change two places together: the dropdown and the `LANGUAGES` map in `frontend/index.html`, and `ALLOWED_LANGUAGES` in `lambdas/get_upload_url/index.py`. The code must be supported by Amazon Transcribe. Check the quality with a real recording first.

**Add a file format.** The extension list lives in three places that must change together: `frontend/index.html` (the `accept` list and the extension check), `lambdas/get_upload_url/index.py` (`ALLOWED_EXTENSIONS`) and `lambdas/submit_transcribe_job/index.py` (`ALLOWED_MEDIA_FORMATS`). The format must be one Transcribe can read directly. `worker/validate.py` needs no change: it checks the content, not the file name.

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `terraform init` cannot find the state bucket | Wrong bucket name in `backend.tf` | Use the `state_bucket_name` output from Step 2 |
| Apply fails: bucket name already exists | Suffix not unique | Choose another suffix and use it everywhere |
| Apply fails: OIDC provider already exists | Another project in the account made it | Import it (Step 7) |
| Upload badge stays at "Sent for processing" | A stage is running or stuck | Step Functions execution graph; the Transcribe job; the EventBridge rule |
| Failed with `CannotPullContainerError` | The image tag is missing in ECR, or a network timeout | Check the tags (Step 8). One retry already covers a timeout |
| Failed after about a minute and a half | The file failed validation (twice, because of the retry) | Read the worker log group in CloudWatch |
| Bedrock `AccessDeniedException` | The model is not enabled for the account | Enable Claude Sonnet 4.6 in the Bedrock console (Step "Before you start") |
| Upload rejected (403) | The signed form expired after 5 minutes | Try the upload again |
| "Too many upload requests" | The throttle was reached | Wait a minute |
| PDF function error mentioning missing modules, or `.so` import errors | `render_pdf` libraries built for the wrong platform | Redo Step 5 and check for `linux-gnu.so` |
| Notes are nonsense | Wrong language chosen at upload | Upload again with the right language |
| PDF contains question marks | A character the PDF fonts cannot draw | Add it to `SYMBOL_MAP` in `lambdas/render_pdf/index.py` |
| Local `plan` shows all Lambdas changed | Local zips differ from CI-built zips | Harmless; let CI apply |
| CI cannot sign in to AWS | The trust policy does not match the token | See the CI/CD section, point 2 |
| Page cannot reach the API when opened from a file | A page opened from disk has a `null` origin that CORS rejects | Use the CloudFront address |

## Clean-up

To remove everything and stop all costs:

1. Empty the buckets that Terraform does not empty (use your suffix):
   ```
   aws s3 rm s3://elearning-pipeline-raw-video-<UNIQUE_SUFFIX> --recursive
   aws s3 rm s3://elearning-pipeline-processed-<UNIQUE_SUFFIX> --recursive
   ```
2. Delete the worker repository with its images (Terraform cannot delete a repository that still holds images):
   ```
   aws ecr delete-repository --repository-name elearning-pipeline-preprocessing-worker --force --region us-west-2
   ```
3. Destroy the project:
   ```
   cd terraform/main
   terraform destroy -var="unique_suffix=<UNIQUE_SUFFIX>"
   ```
4. Delete the leftover Lambda log groups in CloudWatch (they are created automatically and are not managed by Terraform).
5. Last, remove the state bucket. It is versioned, so empty it in the S3 console first (Empty removes all versions), then:
   ```
   cd ../bootstrap
   terraform destroy -var="unique_suffix=<UNIQUE_SUFFIX>"
   ```

## Known limits

- **Input limits:** 2 GB and 4 hours (Amazon Transcribe). MOV, MKV and AVI are not accepted.
- **No login.** The page is open.
- **The page shows only "Failed"** with no reason. The real reason is in CloudWatch Logs. The status API returns the stored raw error text, but the page does not display it.
- **Symbols in the PDF are spelled out** (for example `sqrt3`) instead of drawn, because the PDF library's built-in fonts only know Windows-1252. Words in non-Latin scripts that the model keeps in brackets become question marks.
- **English notes only.**
- **Language quality varies.** Transcription accuracy differs between languages. The notes call has no output token limit, and long lectures in languages that use many tokens per word (such as Hindi and Tamil) have not been tested.
- **A rejected file takes about a minute and a half to fail,** because the validation stage is retried once.
- **The core Lambda functions share one IAM role,** and the CI role has `AdministratorAccess`. Per-function roles and a narrower CI role are not done yet.
- **Not tested:** a deployment from scratch in a clean AWS account, and the cross-platform `pip` command in Step 5.

## License

Released under the MIT License. See the `LICENSE` file.
