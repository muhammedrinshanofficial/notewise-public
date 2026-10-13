terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # NOTE: This bootstrap config intentionally has NO backend block.
  # It uses local state (a .tfstate file on your machine) because it's
  # creating the S3 bucket + DynamoDB table that the REAL project will
  # later use as its remote backend. You can't point Terraform at a
  # backend that doesn't exist yet - chicken and egg.
  #
  # You'll only ever run this bootstrap once (or rarely, if you need to
  # recreate the backend).
}

provider "aws" {
  region = var.aws_region
}
