# Outputs will go here once main.tf has real resources
# (e.g. vpc_id, raw_bucket_name, processed_bucket_name, dynamodb_table_name)

output "upload_api_url" {
  description = "Base URL of the upload API"
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "frontend_url" {
  description = "The live CloudFront URL for the frontend"
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

output "github_actions_role_arn" {
  description = "Role ARN that GitHub Actions assumes (used in the workflow file)"
  value       = aws_iam_role.github_actions.arn
}