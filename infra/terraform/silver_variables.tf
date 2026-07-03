variable "silver_cron_expression" {
  description = "EventBridge cron expression for the Silver normalizer."
  type        = string
  default     = "cron(0 9 * * ? *)"
}