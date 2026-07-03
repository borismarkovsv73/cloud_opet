variable "gold_metrics_cron_expression" {
  description = "EventBridge cron expression for the Gold metrics Lambda."
  type        = string
  default     = "cron(0 10 * * ? *)"
}

variable "gold_sync_cron_expression" {
  description = "EventBridge cron expression for the Gold PostgreSQL sync Lambda."
  type        = string
  default     = "cron(30 10 * * ? *)"
}

variable "gold_manage_postgres" {
  description = "Whether Terraform should provision the Gold PostgreSQL database inside the VPC."
  type        = bool
  default     = true
}

variable "gold_postgres_instance_class" {
  description = "RDS instance class for the managed Gold PostgreSQL database."
  type        = string
  default     = "db.t3.micro"
}

variable "gold_postgres_allocated_storage" {
  description = "Allocated storage in GB for the managed Gold PostgreSQL database."
  type        = number
  default     = 20
}

variable "gold_postgres_backup_retention_days" {
  description = "Backup retention window in days for the managed Gold PostgreSQL database."
  type        = number
  default     = 7
}

variable "gold_postgres_secret_arn" {
  description = "Optional Secrets Manager ARN that stores PostgreSQL connection details."
  type        = string
  default     = ""
}

variable "gold_postgres_host" {
  description = "PostgreSQL host for the Gold sync Lambda."
  type        = string
  default     = ""
}

variable "gold_postgres_port" {
  description = "PostgreSQL port for the Gold sync Lambda."
  type        = number
  default     = 5432
}

variable "gold_postgres_database" {
  description = "PostgreSQL database name for the Gold sync Lambda."
  type        = string
  default     = "gold"
}

variable "gold_postgres_user" {
  description = "PostgreSQL user for the Gold sync Lambda."
  type        = string
  default     = "gold_app"
}

variable "gold_postgres_password" {
  description = "Optional PostgreSQL password for the Gold sync Lambda when not using a secret."
  type        = string
  default     = ""
  sensitive   = true
}
