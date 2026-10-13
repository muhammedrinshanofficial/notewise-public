output "state_bucket_name" {
  description = "S3 bucket name - copy this into main/backend.tf"
  value       = aws_s3_bucket.tf_state.bucket
}
