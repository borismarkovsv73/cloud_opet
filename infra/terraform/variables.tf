variable "region" {
  description = "AWS region for the Bronze layer."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for resource naming."
  type        = string
  default     = "social-bronze"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet."
  type        = string
  default     = "10.40.0.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet."
  type        = string
  default     = "10.40.1.0/24"
}

variable "hn_cron_expression" {
  description = "EventBridge cron expression for the Hacker News collector."
  type        = string
  default     = "cron(0 6 * * ? *)"
}

variable "x_cron_expression" {
  description = "EventBridge cron expression for the X collector."
  type        = string
  default     = "cron(30 6 * * ? *)"
}

variable "x_dataset_urls" {
  description = "Optional list of raw dataset URLs to download for the X Bronze path."
  type        = list(string)
  default     = []
}

variable "collector_log_retention_days" {
  description = "Retention period for Lambda log groups."
  type        = number
  default     = 14
}
