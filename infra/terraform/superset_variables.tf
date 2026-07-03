variable "superset_task_cpu" {
  description = "Fargate CPU units for the Superset task."
  type        = string
  default     = "512"
}

variable "superset_task_memory" {
  description = "Fargate memory in MiB for the Superset task."
  type        = string
  default     = "1024"
}

variable "superset_allowed_cidr" {
  description = "CIDR allowed to reach Superset on port 8088."
  type        = string
  default     = "0.0.0.0/0"
}

variable "superset_admin_username" {
  description = "Initial Superset admin username."
  type        = string
  default     = "admin"
}

variable "superset_admin_email" {
  description = "Initial Superset admin email."
  type        = string
  default     = "admin@example.com"
}
