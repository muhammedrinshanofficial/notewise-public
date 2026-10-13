# **********************************************************************
# AWS E-LEARNING CONTENT AUTOMATION PIPELINE - MAIN INFRASTRUCTURE
# **********************************************************************
# File:     terraform/main/main.tf
# Region:   us-west-2 (variable aws_region)
# Prefix:   every resource name starts with var.project_name
#
# What it builds: an instructor uploads a lecture video; the pipeline
# transcribes it (Transcribe), writes English study notes (Bedrock /
# Claude), renders them as a PDF, and a hosted web page shows the status
# and a download button. No manual step after the upload.
#
# HOW THIS FILE IS ORGANISED
# Resources are grouped by the build step (and part) in which they were
# created, so the file reads like the project history. Terraform ignores
# the order of resources inside a file - it works out the dependencies by
# itself - so this order is only for human reading and changes nothing.
#
# Heading levels used below:
#   ****  STEP     - a major build step
#   ~~~~  Part     - a numbered chunk of a step
#   ~~    Piece    - a small task inside a part
#   ---   resource - one resource block and why it exists
#
# CONTENTS
#   Step 3   VPC, public subnet, locked-down security group
#   Step 4   S3 buckets and the course_metadata table
#   Step 5   IAM role skeleton
#   Step 6   ECR repository and ECS Fargate task definition
#   Step 7   Step Functions pipeline
#              Part 1  State machine and logging
#              Part 2  ECS RunTask permissions
#              Part 3  Transcribe (waitForTaskToken)
#              Part 4  Bedrock study notes
#              Part 5  RenderPdf
#   Step 8   Automatic upload trigger
#              Part 1  Dispatcher Lambda
#              Part 2  RenderPdf writes the result back
#              Part 3  Failure handling
#   Step 9   Frontend and upload API
#              Part 1  Upload-URL API
#              Part 2  CORS on raw_video
#              Part 3  CloudFront hosting
#              Part 4  Status / download endpoint
#   Step 10  CI/CD with GitHub Actions (OIDC sign-in role)
#   Step 11  Real preprocessing validation (worker permissions)
#   Step 12  Automatic clean-up of old files (S3 lifecycle rules)
#   Step 13  Upload size limit (signed upload form instead of signed link)
#
# NOT IN THIS FILE
#   Steps 0-2   bootstrap/ folder and backend.tf (remote state)
#   Step 9 P2b  frontend/index.html (the upload page itself; this file only
#               uploads it to S3 in Step 9 Part 3)
#   Step 10 P2-3  scripts/build_lambdas.py and
#               .github/workflows/terraform.yml
#   Step 11 P2  worker/Dockerfile and worker/validate.py (the container
#               code itself; this file only gives it permissions and runs it)
#   Step 13 P2-3  lambdas/get_upload_url/index.py and the upload function
#               in frontend/index.html (this file only changes CORS)

# **********************************************************************
# STEP 3: VPC, PUBLIC SUBNET AND LOCKED-DOWN SECURITY GROUP
# **********************************************************************
#
# The first real infrastructure. The ECS preprocessing worker runs in a
# PUBLIC subnet (not private) so it can pull its image from ECR without a
# NAT Gateway, which costs money. It is still safe: its security group has
# zero inbound rules, so nothing outside can start a connection to it.

# --- VPC ---
# The private network everything in the pipeline sits inside.

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

# --- Public subnet (for ECS Fargate worker - needs internet to pull from ECR) ---

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"

  tags = {
    Name    = "${var.project_name}-public-subnet"
    Project = var.project_name
  }
}

# --- Internet Gateway + routing, so the public subnet can reach the internet ---

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project_name}-igw"
    Project = var.project_name
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "${var.project_name}-public-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --- Security group for the ECS preprocessing worker ---
# Zero inbound rules: nothing can initiate a connection to it from
# outside. Outbound-only, so it can pull its image from ECR and call
# other AWS APIs, despite sitting in a public subnet.

resource "aws_security_group" "ecs_worker" {
  name        = "${var.project_name}-ecs-worker-sg"
  description = "Zero inbound - outbound only, for the ECS preprocessing worker"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-ecs-worker-sg"
    Project = var.project_name
  }
}

# --- Free VPC Gateway Endpoints for S3 and DynamoDB ---
# Keeps S3/DynamoDB traffic on AWS's internal network instead of routing
# it through a NAT Gateway (which costs money). Gateway endpoints are free.

resource "aws_vpc_endpoint" "s3" {
  vpc_id          = aws_vpc.main.id
  service_name    = "com.amazonaws.${var.aws_region}.s3"
  route_table_ids = [aws_route_table.public.id]

  tags = {
    Name    = "${var.project_name}-s3-endpoint"
    Project = var.project_name
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id          = aws_vpc.main.id
  service_name    = "com.amazonaws.${var.aws_region}.dynamodb"
  route_table_ids = [aws_route_table.public.id]

  tags = {
    Name    = "${var.project_name}-dynamodb-endpoint"
    Project = var.project_name
  }
}

# **********************************************************************
# STEP 4: S3 BUCKETS AND THE course_metadata TABLE
# **********************************************************************
#
# Three S3 buckets (raw / processed / frontend, as in the project proposal)
# plus the DynamoDB table that tracks every uploaded video.

# ~~ Piece 1: raw_video bucket ~~

# --- S3 bucket: raw instructor-uploaded video ---
# Private and encrypted. Only the pipeline (and signed upload links) touch it.

resource "aws_s3_bucket" "raw_video" {
  bucket = "${var.project_name}-raw-video-${var.unique_suffix}"

  tags = {
    Name    = "${var.project_name}-raw-video"
    Project = var.project_name
  }
}

resource "aws_s3_bucket_public_access_block" "raw_video" {
  bucket                  = aws_s3_bucket.raw_video.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw_video" {
  bucket = aws_s3_bucket.raw_video.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ~~ Piece 2: processed bucket ~~

# --- S3 bucket: processed output (transcript JSON, PDF study notes) ---
# Same lockdown as raw_video: private and encrypted.

resource "aws_s3_bucket" "processed" {
  bucket = "${var.project_name}-processed-${var.unique_suffix}"

  tags = {
    Name    = "${var.project_name}-processed"
    Project = var.project_name
  }
}

resource "aws_s3_bucket_public_access_block" "processed" {
  bucket                  = aws_s3_bucket.processed.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "processed" {
  bucket = aws_s3_bucket.processed.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ~~ Piece 3: frontend bucket ~~

# --- S3 bucket: static frontend web app ---
# Fully private. CloudFront (via Origin Access Control, Step 9 Part 3) is
# the only thing allowed to read from it - no public bucket policy.
# Created here with the other buckets; its public-access block and bucket
# policy are added in Step 9 Part 3, once CloudFront exists.

resource "aws_s3_bucket" "frontend" {
  bucket = "${var.project_name}-frontend-${var.unique_suffix}"

  tags = {
    Name    = "${var.project_name}-frontend"
    Project = var.project_name
  }
}

# ~~ Piece 4: course_metadata table ~~

# --- DynamoDB table: course/video metadata ---
# One row per uploaded video (key: video_id). Holds status (PROCESSING /
# COMPLETE / FAILED), language, and the finished PDF's location.
# The input_key index below was added later, in Step 9 Part 4.

resource "aws_dynamodb_table" "course_metadata" {
  name         = "${var.project_name}-course-metadata"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "video_id"

  attribute {
    name = "video_id"
    type = "S"
  }

  attribute {
    name = "input_key"
    type = "S"
  }

  # Lets the status endpoint look a row up by input_key (the S3 key,
  # which is the only thing the frontend actually knows) instead of
  # video_id (which only the dispatcher Lambda ever sees).
  global_secondary_index {
    name            = "input_key-index"
    hash_key        = "input_key"
    projection_type = "ALL"
  }

  tags = {
    Name    = "${var.project_name}-course-metadata"
    Project = var.project_name
  }
}

# **********************************************************************
# STEP 5: IAM ROLE SKELETON
# **********************************************************************
#
# One IAM role per AWS service component (ECS execution, ECS task, Lambda,
# Step Functions). The two roles whose job was already fixed got AWS-managed
# policies straight away. The other roles started empty and gained real
# permissions step by step, as each stage of the pipeline was built.

# --- ECS Task Execution Role ---
# Used by ECS itself (not your app code) to pull the image from ECR
# and write logs to CloudWatch. AWS provides a managed policy for
# this exact purpose - no need to write it by hand.

resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = { Project = var.project_name }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- ECS Task Role ---
# Used by YOUR CODE running inside the container (not ECS itself).
# Started empty on purpose. Its only permission (read the uploaded video
# from raw_video, for the validation check) is attached in Step 11.

resource "aws_iam_role" "ecs_task" {
  name = "${var.project_name}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = { Project = var.project_name }
}

# --- Lambda Execution Role (base, shared) ---
# Shared by the core pipeline Lambdas (dispatcher, transcribe submit and
# completion, study notes, PDF, failure handler). It starts with CloudWatch
# Logs permission only; each later step adds the permissions that Lambda
# needs. The two internet-facing Lambdas have their own roles (Step 9).

resource "aws_iam_role" "lambda_execution" {
  name = "${var.project_name}-lambda-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = { Project = var.project_name }
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- Step Functions Execution Role ---
# Used by the state machine itself to run each pipeline stage (ECS
# RunTask, Transcribe Lambda, Bedrock Lambda, PDF Lambda, failure Lambda).
# Its permissions are attached in Step 7 as each stage is added.

resource "aws_iam_role" "step_functions_execution" {
  name = "${var.project_name}-step-functions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
    }]
  })

  tags = { Project = var.project_name }
}

# **********************************************************************
# STEP 6: ECR REPOSITORY AND ECS FARGATE TASK DEFINITION
# **********************************************************************
#
# The preprocessing worker container. Infrastructure lives here; the
# container code lives in worker/Dockerfile and worker/validate.py (it
# started as a placeholder image and became the real video validation
# check in Step 11).

# --- ECR repository for the preprocessing worker image ---
# scan_on_push scans every pushed image for known vulnerabilities.

resource "aws_ecr_repository" "preprocessing_worker" {
  name                 = "${var.project_name}-preprocessing-worker"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Project = var.project_name }
}

# --- ECS Cluster ---
# Logical grouping for the ECS tasks.

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  tags = { Project = var.project_name }
}

# --- CloudWatch Log Group for the worker's container logs ---
# Retention is set to 14 days, because logs are otherwise kept forever (cost).

resource "aws_cloudwatch_log_group" "preprocessing_worker" {
  name              = "/ecs/${var.project_name}-preprocessing-worker"
  retention_in_days = 14

  tags = { Project = var.project_name }
}

# --- ECS Task Definition ---
# Not an aws_ecs_service - this task is launched on-demand per video
# by Step Functions' RunTask integration, not run as a
# continuously-running service.
# The image tag comes from var.worker_image_tag instead of :latest, so a
# new image version never overwrites the old one and rolling back is a
# one-word change.

resource "aws_ecs_task_definition" "preprocessing_worker" {
  family                   = "${var.project_name}-preprocessing-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "preprocessing-worker"
      image     = "${aws_ecr_repository.preprocessing_worker.repository_url}:${var.worker_image_tag}"
      essential = true
      # Fixed settings the validation script reads. The per-video value
      # (INPUT_KEY) is added by the state machine on every run.
      environment = [
        { name = "INPUT_BUCKET", value = aws_s3_bucket.raw_video.bucket },
        { name = "AWS_REGION", value = var.aws_region }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.preprocessing_worker.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "worker"
        }
      }
    }
  ])

  tags = { Project = var.project_name }
}

# **********************************************************************
# STEP 7: STEP FUNCTIONS PIPELINE
# **********************************************************************
#
# The pipeline itself: Preprocess/validate (ECS) -> Transcribe -> study
# notes (Bedrock) -> render PDF. It was built stage by stage, replacing
# placeholder states with real integrations one at a time, so this step is
# split into Parts 1-5 below.

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Part 1 - State machine and logging
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
# The state machine is ONE resource, so it appears once here in its final
# form. Its stages were added over time:
#   PreprocessValidate    - Part 2 (real validation added in Step 11)
#   TranscribeAudio       - Part 3
#   GenerateStudyNotes    - Part 4
#   RenderPdf             - Part 5
#   HandlePipelineFailure - Step 8 Part 3 (plus the Catch on every stage)
#   PipelineFailed        - Correction (ends a failed run as FAILED)

# --- CloudWatch Log Group for the state machine's execution logs ---

resource "aws_cloudwatch_log_group" "step_functions" {
  name              = "/aws/vendedlogs/states/${var.project_name}-pipeline"
  retention_in_days = 14

  tags = { Project = var.project_name }
}

# --- Step Functions: the pipeline state machine ---
# Any stage that fails routes to HandlePipelineFailure, which marks the
# matching course_metadata row as FAILED instead of leaving it stuck at
# PROCESSING forever, then ends the run in a Fail state so the run itself
# shows as Failed. Every stage uses a ResultPath so its output is added
# to the data instead of replacing the original input (input_key etc.).

resource "aws_sfn_state_machine" "pipeline" {
  name     = "${var.project_name}-pipeline"
  role_arn = aws_iam_role.step_functions_execution.arn

  definition = jsonencode({
    Comment = "E-Learning pipeline: preprocess (ECS) -> transcribe -> generate study notes (Bedrock) -> render PDF"
    StartAt = "PreprocessValidate"
    States = {
      PreprocessValidate = {
        Type     = "Task"
        Resource = "arn:aws:states:::ecs:runTask.sync"
        Parameters = {
          LaunchType     = "FARGATE"
          Cluster        = aws_ecs_cluster.main.arn
          TaskDefinition = aws_ecs_task_definition.preprocessing_worker.arn
          NetworkConfiguration = {
            AwsvpcConfiguration = {
              Subnets        = [aws_subnet.public.id]
              SecurityGroups = [aws_security_group.ecs_worker.id]
              AssignPublicIp = "ENABLED"
            }
          }
          # Hands this run's video to the container as the INPUT_KEY
          # environment variable (the "Value.$" name means: copy it from
          # the state machine's own data).
          Overrides = {
            ContainerOverrides = [{
              Name = "preprocessing-worker"
              Environment = [{
                Name      = "INPUT_KEY"
                "Value.$" = "$.input_key"
              }]
            }]
          }
        }
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "HandlePipelineFailure"
        }]
        # One retry, because Fargate sometimes cannot pull the image from ECR
        # (a short network timeout, not a problem with the video). A bad
        # file is retried once too, so it fails after about two runs.
        Retry = [{
          ErrorEquals     = ["States.TaskFailed"]
          IntervalSeconds = 10
          MaxAttempts     = 1
          BackoffRate     = 1
        }]
        ResultPath = "$.ecsResult"
        Next       = "TranscribeAudio"
      }
      TranscribeAudio = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke.waitForTaskToken"
        Parameters = {
          FunctionName = aws_lambda_function.submit_transcribe_job.arn
          Payload = {
            "TaskToken.$"     = "$$.Task.Token"
            "input_key.$"     = "$.input_key"
            "language_code.$" = "$.language_code"
            "video_id.$"      = "$.video_id"
          }
        }
        TimeoutSeconds = 3600
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "HandlePipelineFailure"
        }]
        ResultPath = "$.transcribeResult"
        Next       = "GenerateStudyNotes"
      }
      GenerateStudyNotes = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.generate_study_notes.arn
          "Payload.$"  = "$"
        }
        ResultSelector = {
          "notes.$" = "$.Payload.notes"
        }
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "HandlePipelineFailure"
        }]
        ResultPath = "$.studyNotesResult"
        Next       = "RenderPdf"
      }
      RenderPdf = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.render_pdf.arn
          "Payload.$"  = "$"
        }
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "HandlePipelineFailure"
        }]
        ResultPath = "$.renderPdfResult"
        End        = true
      }
      HandlePipelineFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.handle_pipeline_failure.arn
          "Payload.$"  = "$"
        }
        ResultPath = "$.failureHandled"
        Next       = "PipelineFailed"
      }
      # The failure handler has saved the reason (status FAILED). This last
      # state ends the run as FAILED, so the Step Functions console shows
      # the real result instead of "Succeeded".
      PipelineFailed = {
        Type  = "Fail"
        Error = "PipelineFailed"
        Cause = "A pipeline stage failed. The reason is saved in the course_metadata table (status FAILED)."
      }
    }
  })

  # include_execution_data is false so the logs do not copy the data of
  # every step (which includes the study notes text). The logs still show
  # which state ran, how long it took and whether it failed; the data
  # itself is still visible in each execution's history in the Step
  # Functions console.
  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.step_functions.arn}:*"
    include_execution_data = false
    level                  = "ALL"
  }

  tags = { Project = var.project_name }
}

# --- IAM: lets Step Functions write execution logs ---
# There is no AWS-managed policy for this specific purpose, so it is inline.

resource "aws_iam_role_policy" "step_functions_logging" {
  name = "${var.project_name}-sfn-logging"
  role = aws_iam_role.step_functions_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogDelivery",
        "logs:GetLogDelivery",
        "logs:UpdateLogDelivery",
        "logs:DeleteLogDelivery",
        "logs:ListLogDeliveries",
        "logs:PutResourcePolicy",
        "logs:DescribeResourcePolicies",
        "logs:DescribeLogGroups"
      ]
      Resource = "*"
    }]
  })
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Part 2 - ECS RunTask permissions
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# --- IAM: lets Step Functions actually launch and monitor the ECS task ---

resource "aws_iam_role_policy" "step_functions_ecs" {
  name = "${var.project_name}-sfn-ecs-runtask"
  role = aws_iam_role.step_functions_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecs:RunTask", "ecs:StopTask", "ecs:DescribeTasks"]
        Resource = "*"
      },
      {
        # Step Functions has to be allowed to hand these two roles to ECS -
        # without this, RunTask fails even though the roles themselves exist.
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          aws_iam_role.ecs_task.arn,
          aws_iam_role.ecs_task_execution.arn
        ]
      },
      {
        # The .sync integration manages an EventBridge rule behind the
        # scenes to detect when the ECS task stops - this is what lets
        # Step Functions "wait" for it instead of just firing and forgetting.
        Effect = "Allow"
        Action = [
          "events:PutTargets",
          "events:PutRule",
          "events:DescribeRule"
        ]
        Resource = "*"
      }
    ]
  })
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Part 3 - Transcribe (waitForTaskToken)
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
# Transcribe runs as a separate job, so Step Functions pauses until it is
# told the job is done:
#   submit Lambda -> Transcribe job -> EventBridge -> completion Lambda
#   -> SendTaskSuccess/Failure -> state machine resumes.
# The language is chosen by the instructor at upload time and passed in
# explicitly (language_code). Auto-detection was dropped because it
# misidentified Malayalam.

# ~~ Piece 1: Transcribe permissions on the shared Lambda role ~~

# --- Extra permissions for lambda_execution role: Transcribe ---
# Transcribe has no separate service role of its own - it just uses the
# permissions of whichever caller (this Lambda's role) invokes
# StartTranscriptionJob. So this grants read on raw_video (input) and
# write on processed (transcript output), plus the Transcribe API actions.

resource "aws_iam_role_policy" "lambda_transcribe" {
  name = "${var.project_name}-lambda-transcribe"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["transcribe:StartTranscriptionJob", "transcribe:GetTranscriptionJob"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.raw_video.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.processed.arn}/*"
      }
    ]
  })
}

# ~~ Piece 2: DynamoDB token table ~~

# --- DynamoDB table: maps Transcribe job names to Step Functions task tokens ---
# A Step Functions task token is too long to attach to a Transcribe job, so
# it is stored here, keyed by job name, and looked up when the completion
# Lambda fires. (The TTL on expires_at was added later, in the hardening
# pass, so orphaned rows delete themselves.)

resource "aws_dynamodb_table" "transcribe_tokens" {
  name         = "${var.project_name}-transcribe-tokens"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_name"

  attribute {
    name = "job_name"
    type = "S"
  }

  # Orphaned token rows (a job that never completed) delete themselves
  # after expires_at passes, instead of sitting in the table forever.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = { Project = var.project_name }
}

# --- IAM: let the Lambdas read/write the Transcribe token table ---

resource "aws_iam_role_policy" "lambda_transcribe_token_table" {
  name = "${var.project_name}-lambda-transcribe-token-table"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:DeleteItem"]
      Resource = aws_dynamodb_table.transcribe_tokens.arn
    }]
  })
}

# ~~ Piece 3: Transcribe Lambdas (submit + completion) ~~

# --- IAM: lets any Lambda on the shared role signal Step Functions back ---
# Needed by handle_transcribe_completion (the only waitForTaskToken stage)
# to call SendTaskSuccess / SendTaskFailure.

resource "aws_iam_role_policy" "lambda_step_functions_callback" {
  name = "${var.project_name}-lambda-step-functions-callback"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:SendTaskSuccess", "states:SendTaskFailure"]
      Resource = "*"
    }]
  })
}

# --- Lambda: submits the Transcribe job ---
# Invoked by Step Functions with .waitForTaskToken. Starts the transcription
# job using the language_code the instructor chose at upload (English or
# Malayalam), stores the task token in DynamoDB keyed by job name, then
# returns. Step Functions stays paused until the completion Lambda fires.

resource "aws_lambda_function" "submit_transcribe_job" {
  function_name    = "${var.project_name}-submit-transcribe-job"
  role             = aws_iam_role.lambda_execution.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = "${path.module}/../../lambdas/submit_transcribe_job.zip"
  source_code_hash = filebase64sha256("${path.module}/../../lambdas/submit_transcribe_job.zip")

  environment {
    variables = {
      INPUT_BUCKET  = aws_s3_bucket.raw_video.bucket
      OUTPUT_BUCKET = aws_s3_bucket.processed.bucket
      TOKEN_TABLE   = aws_dynamodb_table.transcribe_tokens.name
    }
  }
}

# --- Lambda: handles Transcribe job completion ---
# Triggered by the EventBridge rule below whenever a Transcribe job
# finishes. Pulls the task token back out of DynamoDB using the job name
# and wakes the paused Step Functions execution.

resource "aws_lambda_function" "handle_transcribe_completion" {
  function_name    = "${var.project_name}-handle-transcribe-completion"
  role             = aws_iam_role.lambda_execution.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 10
  filename         = "${path.module}/../../lambdas/handle_transcribe_completion.zip"
  source_code_hash = filebase64sha256("${path.module}/../../lambdas/handle_transcribe_completion.zip")

  environment {
    variables = {
      TOKEN_TABLE = aws_dynamodb_table.transcribe_tokens.name
    }
  }
}

# ~~ Piece 4: EventBridge rule for Transcribe completion ~~

# --- EventBridge rule: watches for Transcribe job completion ---
# AWS automatically emits an event whenever a Transcribe job changes state.
# This rule catches COMPLETED and FAILED and routes them to the completion
# Lambda.

resource "aws_cloudwatch_event_rule" "transcribe_state_change" {
  name = "${var.project_name}-transcribe-state-change"

  event_pattern = jsonencode({
    source      = ["aws.transcribe"]
    detail-type = ["Transcribe Job State Change"]
    detail      = { TranscriptionJobStatus = ["COMPLETED", "FAILED"] }
  })
}

# --- Wire the rule to the completion Lambda ---

resource "aws_cloudwatch_event_target" "transcribe_completion_lambda" {
  rule = aws_cloudwatch_event_rule.transcribe_state_change.name
  arn  = aws_lambda_function.handle_transcribe_completion.arn
}

# --- Let EventBridge actually invoke the Lambda ---
# Without this, the rule can fire but EventBridge is not authorised to
# call the Lambda.

resource "aws_lambda_permission" "eventbridge_invoke_transcribe_completion" {
  statement_id  = "AllowEventBridgeInvokeTranscribe"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.handle_transcribe_completion.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.transcribe_state_change.arn
}

# ~~ Piece 5: Wire Transcribe into the state machine ~~

# --- Let Step Functions invoke the Transcribe submit Lambda ---
# (The TranscribeAudio state itself is part of the state machine above.)

resource "aws_iam_role_policy" "step_functions_lambda_transcribe" {
  name = "${var.project_name}-sfn-lambda-invoke-transcribe"
  role = aws_iam_role.step_functions_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.submit_transcribe_job.arn
    }]
  })
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Part 4 - Bedrock study notes (Claude Sonnet 4.6)
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
# Bedrock's Converse API is synchronous, so unlike Transcribe this is a
# plain Task state: no waiting and no callback.

# ~~ Piece 1: Bedrock permissions ~~

# --- Extra permissions for lambda_execution role: Bedrock ---
# Lets the study-notes Lambda call Claude through Bedrock's Converse API.
# bedrock:InvokeModel is the only permission needed: there is no separate
# "bedrock:Converse" IAM action, AWS authorises Converse through
# InvokeModel. The s3:GetObject lets it read the transcript from processed.

resource "aws_iam_role_policy" "lambda_bedrock" {
  name = "${var.project_name}-lambda-bedrock"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.processed.arn}/*"
      }
    ]
  })
}

# ~~ Piece 2: Study-notes Lambda ~~

# --- Lambda: generates study notes via Bedrock ---
# Fetches the transcript from processed/transcripts/, sends it to Claude
# (which translates if needed and writes structured Markdown notes), and
# returns the notes text. Uses a cross-region inference profile ID, which
# Bedrock requires for this model.

resource "aws_lambda_function" "generate_study_notes" {
  function_name    = "${var.project_name}-generate-study-notes"
  role             = aws_iam_role.lambda_execution.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 300
  filename         = "${path.module}/../../lambdas/generate_study_notes.zip"
  source_code_hash = filebase64sha256("${path.module}/../../lambdas/generate_study_notes.zip")

  environment {
    variables = {
      MODEL_ID         = "us.anthropic.claude-sonnet-4-6"
      PROCESSED_BUCKET = aws_s3_bucket.processed.bucket
    }
  }
}

# ~~ Piece 3: Wire into the state machine ~~

# --- Let Step Functions invoke the study-notes Lambda ---

resource "aws_iam_role_policy" "step_functions_lambda_bedrock" {
  name = "${var.project_name}-sfn-lambda-invoke-bedrock"
  role = aws_iam_role.step_functions_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.generate_study_notes.arn
    }]
  })
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Part 5 - RenderPdf (final pipeline stage)
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
# The first Lambda with a third-party library (fpdf2), packaged into its
# zip by scripts/build_lambdas.py. No extra IAM was needed at this point;
# its DynamoDB permission is added in Step 8 Part 2.

# --- Lambda: renders study notes into a PDF and uploads it ---
# Called directly by Step Functions (plain Task, same as GenerateStudyNotes).
# Parses the Markdown-structured notes, builds a PDF with fpdf2, uploads it
# to processed/study-notes/, and marks the course_metadata row COMPLETE.

resource "aws_lambda_function" "render_pdf" {
  function_name    = "${var.project_name}-render-pdf"
  role             = aws_iam_role.lambda_execution.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = "${path.module}/../../lambdas/render_pdf.zip"
  source_code_hash = filebase64sha256("${path.module}/../../lambdas/render_pdf.zip")

  environment {
    variables = {
      PROCESSED_BUCKET      = aws_s3_bucket.processed.bucket
      COURSE_METADATA_TABLE = aws_dynamodb_table.course_metadata.name
    }
  }
}

# --- Let Step Functions invoke the render_pdf Lambda ---

resource "aws_iam_role_policy" "step_functions_lambda_pdf" {
  name = "${var.project_name}-sfn-lambda-invoke-pdf"
  role = aws_iam_role.step_functions_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.render_pdf.arn
    }]
  })
}

# **********************************************************************
# STEP 8: AUTOMATIC UPLOAD TRIGGER
# **********************************************************************
#
# Replaces manual "Start execution" clicks: when a video lands in S3, a
# dispatcher Lambda starts the pipeline. It also records every upload in
# course_metadata and handles failures so no row stays stuck at PROCESSING.

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Part 1 - Dispatcher Lambda
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# --- IAM: dispatcher's permissions ---
# Read the uploaded object's metadata, create the initial course_metadata
# row, and start the pipeline.

resource "aws_iam_role_policy" "lambda_dispatcher" {
  name = "${var.project_name}-lambda-dispatcher"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.raw_video.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.course_metadata.arn
      },
      {
        Effect   = "Allow"
        Action   = ["states:StartExecution"]
        Resource = aws_sfn_state_machine.pipeline.arn
      }
    ]
  })
}

# --- Lambda: dispatches a new upload into the pipeline ---
# Triggered directly by S3 on upload. Decodes the S3 key, reads the
# language, starts a Step Functions execution (with a name made from a
# hash of bucket+key, so a duplicate S3 event is harmless), and writes the
# initial course_metadata row.

resource "aws_lambda_function" "dispatch_pipeline" {
  function_name    = "${var.project_name}-dispatch-pipeline"
  role             = aws_iam_role.lambda_execution.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = "${path.module}/../../lambdas/dispatch_pipeline.zip"
  source_code_hash = filebase64sha256("${path.module}/../../lambdas/dispatch_pipeline.zip")

  environment {
    variables = {
      COURSE_METADATA_TABLE = aws_dynamodb_table.course_metadata.name
      STATE_MACHINE_ARN     = aws_sfn_state_machine.pipeline.arn
      DEFAULT_LANGUAGE_CODE = "en-US"
    }
  }
}

# --- Let S3 invoke the dispatcher Lambda directly ---

resource "aws_lambda_permission" "s3_invoke_dispatcher" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dispatch_pipeline.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.raw_video.arn
}

# --- S3 event notification: new upload -> dispatcher Lambda directly ---

resource "aws_s3_bucket_notification" "raw_video_upload" {
  bucket = aws_s3_bucket.raw_video.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.dispatch_pipeline.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.s3_invoke_dispatcher]
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Part 2 - RenderPdf writes the result back to course_metadata
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# --- IAM: lets any Lambda on the shared role update course_metadata ---
# Used by render_pdf (marks a row COMPLETE) and handle_pipeline_failure
# (marks a row FAILED).

resource "aws_iam_role_policy" "lambda_course_metadata" {
  name = "${var.project_name}-lambda-course-metadata"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:UpdateItem"]
      Resource = aws_dynamodb_table.course_metadata.arn
    }]
  })
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Part 3 - Failure handling
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
# Every real stage in the state machine has a Catch that sends errors to
# HandlePipelineFailure, which runs the Lambda below.

# --- Lambda: marks course_metadata as FAILED when any pipeline stage errors ---

resource "aws_lambda_function" "handle_pipeline_failure" {
  function_name    = "${var.project_name}-handle-pipeline-failure"
  role             = aws_iam_role.lambda_execution.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 10
  filename         = "${path.module}/../../lambdas/handle_pipeline_failure.zip"
  source_code_hash = filebase64sha256("${path.module}/../../lambdas/handle_pipeline_failure.zip")

  environment {
    variables = {
      COURSE_METADATA_TABLE = aws_dynamodb_table.course_metadata.name
    }
  }
}

# --- Let Step Functions invoke the failure-handler Lambda ---

resource "aws_iam_role_policy" "step_functions_lambda_failure_handler" {
  name = "${var.project_name}-sfn-lambda-invoke-failure-handler"
  role = aws_iam_role.step_functions_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.handle_pipeline_failure.arn
    }]
  })
}

# **********************************************************************
# STEP 9: FRONTEND AND UPLOAD API
# **********************************************************************
#
# The hosted web page and the two small APIs behind it. The browser uploads
# the video DIRECTLY to S3 with a short-lived signed link (videos are far
# too large to pass through API Gateway/Lambda). The two internet-facing
# Lambdas each get their own narrow IAM role instead of the shared one.

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Part 1 - Upload-URL API
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# --- Dedicated IAM role for the upload-URL Lambda ---
# Separate from lambda_execution on purpose: this is internet-facing code,
# so it gets the smallest permission set possible - write to raw_video,
# nothing else.

resource "aws_iam_role" "upload_api" {
  name = "${var.project_name}-upload-api-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = { Project = var.project_name }
}

resource "aws_iam_role_policy_attachment" "upload_api_basic" {
  role       = aws_iam_role.upload_api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- IAM: upload role may write to raw_video ---
# A signed upload link only works if the role that signed it is itself
# allowed to do the action.

resource "aws_iam_role_policy" "upload_api_s3" {
  name = "${var.project_name}-upload-api-s3"
  role = aws_iam_role.upload_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "${aws_s3_bucket.raw_video.arn}/*"
    }]
  })
}

# --- Lambda: issues a short-lived signed upload form (size-limited, Step 13) ---

resource "aws_lambda_function" "get_upload_url" {
  function_name    = "${var.project_name}-get-upload-url"
  role             = aws_iam_role.upload_api.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 10
  filename         = "${path.module}/../../lambdas/get_upload_url.zip"
  source_code_hash = filebase64sha256("${path.module}/../../lambdas/get_upload_url.zip")

  environment {
    variables = {
      RAW_BUCKET = aws_s3_bucket.raw_video.bucket
    }
  }

  tags = { Project = var.project_name }
}

# --- API Gateway (HTTP API) in front of the Lambdas ---
# One API shared by the upload and status endpoints. CORS only allows the
# CloudFront site's address, so browsers on other websites cannot call it.
# (Scripts like curl still can - CORS is a browser-only protection.)

resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["https://${aws_cloudfront_distribution.frontend.domain_name}"]
    allow_methods = ["POST", "GET", "OPTIONS"]
    allow_headers = ["content-type", "authorization"]
  }

  tags = { Project = var.project_name }
}

# --- API route: POST /upload-url ---

resource "aws_apigatewayv2_integration" "get_upload_url" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.get_upload_url.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_upload_url" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /upload-url"
  target    = "integrations/${aws_apigatewayv2_integration.get_upload_url.id}"
}

# --- API stage with throttling ---
# Throttling caps request volume. There is no login or passcode, so this
# and the AWS Budgets cutoff are the cost safeguards: keep the API URL
# private.

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 5
    throttling_rate_limit  = 2
  }

  tags = { Project = var.project_name }
}

# --- Let API Gateway invoke the upload-URL Lambda ---

resource "aws_lambda_permission" "apigw_invoke_get_upload_url" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_upload_url.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Part 2 - CORS on raw_video
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
# (Part 2b, the upload page itself, is frontend/index.html and is uploaded
# in Part 3 below.)

# --- CORS: let the frontend upload directly to raw_video ---
# Browsers refuse cross-site uploads unless the bucket explicitly allows
# them (curl does not care, browsers do). Only the CloudFront site's
# address is allowed. Uploads still need a signed link, so this does not
# open the bucket to anyone.
# The method is POST because, since Step 13, uploads are a signed form
# (it was PUT when uploads used a plain signed link).

resource "aws_s3_bucket_cors_configuration" "raw_video" {
  bucket = aws_s3_bucket.raw_video.id

  cors_rule {
    allowed_methods = ["POST"]
    allowed_origins = ["https://${aws_cloudfront_distribution.frontend.domain_name}"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Part 3 - CloudFront hosting for the frontend
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
# The frontend bucket is locked down and served only through CloudFront,
# with the real API URL generated into config.js by Terraform.

# --- Frontend bucket: block all public access ---
# Completes the lockdown of the bucket created in Step 4.

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Frontend bucket: explicit encryption ---
# S3 already encrypts every new object by default. This block states it
# in the code, so the frontend bucket matches raw_video and processed.
# AES256 is encryption that CloudFront can read without extra permissions.

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- Origin Access Control ---
# Lets CloudFront authenticate to S3 with a signed request, instead of the
# bucket needing to be public. This is the modern replacement for the
# older "Origin Access Identity" approach.

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.project_name}-frontend-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# --- CloudFront distribution ---
# PriceClass_100 keeps this to US/Canada/Europe edge locations only -
# cheaper, and fine for a project with no global audience.
# CachingOptimized (658327ea-f89d-4fab-a63d-7e88639e58f6) is an
# AWS-managed cache policy suited to static sites - no need to hand-write
# cache header rules.

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "frontend-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    target_origin_id       = "frontend-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Project = var.project_name }
}

# --- Let CloudFront (and only CloudFront) read from the bucket ---
# Scoped via SourceArn to this exact distribution, not "any CloudFront
# distribution in AWS" - same least-privilege pattern used elsewhere.

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn }
      }
    }]
  })
}

# --- Upload the frontend page itself ---

resource "aws_s3_object" "frontend_index" {
  bucket        = aws_s3_bucket.frontend.id
  key           = "index.html"
  source        = "${path.module}/../../frontend/index.html"
  etag          = filemd5("${path.module}/../../frontend/index.html")
  content_type  = "text/html"
  cache_control = "no-cache"
}

# --- Generate and upload config.js ---
# The real API URL is written here by Terraform, so it is never hardcoded
# in index.html or committed to the repo.

resource "aws_s3_object" "frontend_config" {
  bucket        = aws_s3_bucket.frontend.id
  key           = "config.js"
  content       = "const API_URL = \"${aws_apigatewayv2_api.main.api_endpoint}\";"
  content_type  = "application/javascript"
  cache_control = "no-cache"
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Part 4 - Status / download endpoint
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
# The page only knows a video's S3 key, so the course_metadata table has an
# input_key index to look rows up by it (see Step 4).

# --- Dedicated IAM role for the status Lambda ---
# Separate from lambda_execution, same reasoning as upload_api: this is
# internet-facing code, so it gets only what it needs - read
# course_metadata via the index, and generate presigned GET URLs for
# finished PDFs.

resource "aws_iam_role" "status_api" {
  name = "${var.project_name}-status-api-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = { Project = var.project_name }
}

resource "aws_iam_role_policy_attachment" "status_api_basic" {
  role       = aws_iam_role.status_api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- IAM: status role permissions (query the index, read processed PDFs) ---

resource "aws_iam_role_policy" "status_api_permissions" {
  name = "${var.project_name}-status-api-permissions"
  role = aws_iam_role.status_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Query"]
        Resource = "${aws_dynamodb_table.course_metadata.arn}/index/input_key-index"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.processed.arn}/*"
      }
    ]
  })
}

# --- IAM: lets the status Lambda tell "file expired" from "no access" ---
# Asking S3 for a file that does not exist only answers "not found" if the
# caller may list the bucket. Without this, S3 answers "access denied" and
# the Lambda could not tell an expired PDF (deleted by Step 12) from a
# real permission problem.

resource "aws_iam_role_policy" "status_api_list_processed" {
  name = "${var.project_name}-status-api-list-processed"
  role = aws_iam_role.status_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:ListBucket"]
      Resource = aws_s3_bucket.processed.arn
    }]
  })
}

# --- Lambda: looks up a video's status by its S3 key ---
# Returns a presigned download link once the PDF is ready, or EXPIRED once
# the clean-up rule (Step 12) has deleted it.

resource "aws_lambda_function" "get_status" {
  function_name    = "${var.project_name}-get-status"
  role             = aws_iam_role.status_api.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 10
  filename         = "${path.module}/../../lambdas/get_status.zip"
  source_code_hash = filebase64sha256("${path.module}/../../lambdas/get_status.zip")

  environment {
    variables = {
      COURSE_METADATA_TABLE = aws_dynamodb_table.course_metadata.name
      PROCESSED_BUCKET      = aws_s3_bucket.processed.bucket
    }
  }

  tags = { Project = var.project_name }
}

# --- API route: GET /status ---

resource "aws_apigatewayv2_integration" "get_status" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.get_status.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_status" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /status"
  target    = "integrations/${aws_apigatewayv2_integration.get_status.id}"
}

# --- Let API Gateway invoke the status Lambda ---

resource "aws_lambda_permission" "apigw_invoke_get_status" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_status.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# **********************************************************************
#   Step 10  CI/CD with GitHub Actions (OIDC sign-in role)
# **********************************************************************
#
# Every change to the repo is checked automatically, and changes merged to
# main are deployed automatically, with no AWS access keys stored in
# GitHub.
#
# Part 1 (below) is the only part that lives in this file.
#   Part 2  scripts/build_lambdas.py - reproducible Lambda zips
#   Part 3  .github/workflows/terraform.yml - the workflow
#   Part 4  first pull-request run

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Part 1 - GitHub OIDC provider and IAM role
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# --- GitHub as a trusted identity provider ---
# Lets GitHub Actions prove who it is to AWS with a short-lived token, so
# no AWS access keys are ever stored in GitHub.

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = { Project = var.project_name }
}

# --- Role that GitHub Actions assumes ---
# The trust policy is the real security control: only this repository, and
# only runs on the main branch or from pull requests, can assume it.
# GitHub's sub claim includes permanent numeric IDs for the owner and
# repository (owner@ID/repo@ID), so those IDs must appear here too.

resource "aws_iam_role" "github_actions" {
  name = "${var.project_name}-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:<GITHUB_OWNER>@<OWNER_ID>/<REPO_NAME>@<REPO_ID>:ref:refs/heads/main",
            "repo:<GITHUB_OWNER>@<OWNER_ID>/<REPO_NAME>@<REPO_ID>:pull_request"
          ]
        }
      }
    }]
  })

  tags = { Project = var.project_name }
}

# --- Permissions for the GitHub Actions role ---
# Terraform here creates IAM roles, S3, CloudFront, Lambda and more, so the
# role needs broad rights. Tightening this is a known future item.

resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# **********************************************************************
# STEP 11: REAL PREPROCESSING VALIDATION
# **********************************************************************
#
# The PreprocessValidate container stopped being a placeholder: it now
# checks that the uploaded file is a real video, has an audio track and
# is within the size and duration limits, and fails the upload early
# (before Transcribe and Bedrock cost anything) if not.
#   Part 1  Worker permissions (below, in this file)
#   Part 2  worker/Dockerfile and worker/validate.py (outside this file)

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Part 1 - Worker permissions
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# --- IAM: lets the preprocessing worker read the uploaded video ---
# This goes on the ecs_task role (the one YOUR code inside the container
# uses), not the execution role (which only pulls the image and writes
# logs). Read-only on raw_video: the container checks the video and
# never changes anything.

resource "aws_iam_role_policy" "ecs_task_raw_video" {
  name = "${var.project_name}-ecs-task-raw-video"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.raw_video.arn}/*"
    }]
  })
}

# **********************************************************************
# STEP 12: AUTOMATIC CLEAN-UP OF OLD FILES
# **********************************************************************
#
# Without these rules every video, transcript and PDF would stay in S3
# forever and keep costing storage. S3 lifecycle rules delete files by
# age on their own, so no code or schedule is needed. S3 checks the rules
# about once a day, so a file can live up to a day longer than the number
# of days set here.
#   Raw videos          1 day   (only needed while the pipeline runs)
#   Transcripts         1 day   (only needed while the notes are written)
#   PDF study notes     2 days  (the deliverable people download)
# One day is the shortest time a lifecycle rule can use (there are no
# hours), and S3 rounds the expiry up to the next midnight UTC. So a
# 1-day file lives 1 to 2 days, and a PDF lives 2 to 3 days.
# The frontend bucket is not touched: it holds the website itself.

# --- Lifecycle rule: raw_video ---
# Deletes every uploaded video 1 day after upload. The pipeline is long
# finished by then, and nothing reads the video again.

resource "aws_s3_bucket_lifecycle_configuration" "raw_video" {
  bucket = aws_s3_bucket.raw_video.id

  rule {
    id     = "expire-raw-videos"
    status = "Enabled"

    # An empty filter means the rule applies to the whole bucket.
    filter {}

    expiration {
      days = 1
    }
  }
}

# --- Lifecycle rules: processed ---
# One bucket holds two kinds of file with different lifetimes, so there
# are two rules, each limited to its own folder (prefix). The prefixes
# must match the keys written by the Lambdas: transcripts/<job>.json
# (Transcribe output) and study-notes/<job>.pdf (render_pdf).

resource "aws_s3_bucket_lifecycle_configuration" "processed" {
  bucket = aws_s3_bucket.processed.id

  rule {
    id     = "expire-transcripts"
    status = "Enabled"

    filter {
      prefix = "transcripts/"
    }

    expiration {
      days = 1
    }
  }

  rule {
    id     = "expire-study-notes"
    status = "Enabled"

    filter {
      prefix = "study-notes/"
    }

    expiration {
      days = 2
    }
  }
}

# **********************************************************************
# STEP 13: UPLOAD SIZE LIMIT
# **********************************************************************
#
# The upload link used to accept a file of any size. The upload-URL
# Lambda now issues a signed upload FORM (presigned POST) with rules
# written into it: S3 itself rejects a file bigger than 2 GB, or one sent
# with a different language than the one the Lambda approved. Because S3
# enforces the rule, the page can no longer be bypassed.
#   Part 1  CORS on raw_video changed from PUT to POST (Step 9 Part 2,
#           above in this file)
#   Part 2  lambdas/get_upload_url/index.py (outside this file)
#   Part 3  frontend/index.html, the upload function (outside this file)
