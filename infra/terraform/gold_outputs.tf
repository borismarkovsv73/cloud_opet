output "gold_bucket_name" {
  value       = aws_s3_bucket.gold.bucket
  description = "S3 bucket that stores Gold analytical Parquet data."
}

output "gold_metrics_lambda_name" {
  value       = aws_lambda_function.gold_metrics.function_name
  description = "Gold metrics Lambda name."
}

output "gold_sync_lambda_name" {
  value       = aws_lambda_function.gold_sync.function_name
  description = "Gold PostgreSQL sync Lambda name."
}

output "gold_postgres_endpoint" {
  value       = local.gold_postgres_host
  description = "PostgreSQL endpoint for the Gold layer when Terraform manages the database."
}

output "gold_postgres_secret_arn" {
  value       = local.gold_postgres_secret_arn
  description = "Secrets Manager ARN for the managed Gold PostgreSQL credentials."
}
