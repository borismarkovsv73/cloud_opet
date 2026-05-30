output "bronze_bucket_name" {
  value       = aws_s3_bucket.bronze.bucket
  description = "S3 bucket that stores raw Bronze data."
}

output "vpc_id" {
  value       = aws_vpc.bronze.id
  description = "VPC used by the Bronze collectors."
}

output "hn_lambda_name" {
  value       = aws_lambda_function.hn_collector.function_name
  description = "Hacker News collector Lambda name."
}

output "x_lambda_name" {
  value       = aws_lambda_function.x_collector.function_name
  description = "X collector Lambda name."
}
