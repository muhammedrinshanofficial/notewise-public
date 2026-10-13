variable "aws_region" {
  description = "AWS region for this project"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Short name used as a prefix for resources + cost allocation tags"
  type        = string
  default     = "elearning-pipeline"
}

# S3 bucket names must be GLOBALLY unique across all of AWS, not just your
# account. So we require you to pass a unique suffix rather than guessing
# one - e.g. your name or a random string.
variable "unique_suffix" {
  description = "A unique suffix to make S3 bucket names globally unique (e.g. your name or initials)"
  type        = string
}
