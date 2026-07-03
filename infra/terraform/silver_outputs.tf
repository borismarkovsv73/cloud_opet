output "silver_bucket_name" {
  value       = aws_s3_bucket.silver.bucket
  description = "S3 bucket that stores normalized Silver data."
}

output "silver_lambda_name" {
  value       = aws_lambda_function.silver_normalizer.function_name
  description = "Silver normalization Lambda name."
}