# Remote backend for the real project. The state lives in the S3 bucket
# that bootstrap/ created, and uses Terraform's native S3 locking
# (use_lockfile) - no separate lock table needed.
#
# Terraform backend blocks can't use variables, so the bucket name below
# is hardcoded. It must match the state_bucket_name output from bootstrap/.

terraform {
  backend "s3" {
    bucket       = "elearning-pipeline-tfstate-<UNIQUE_SUFFIX>"
    key          = "elearning-pipeline/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
  }
}
