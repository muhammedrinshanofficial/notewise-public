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

variable "unique_suffix" {
  description = "A unique suffix to make S3 bucket names globally unique (same one you used in bootstrap)"
  type        = string
}

variable "worker_image_tag" {
  description = "Version tag of the preprocessing worker image in ECR. A new tag per image version means the old image is never overwritten, so rolling back is one word."
  type        = string
  default     = "v3"
}
