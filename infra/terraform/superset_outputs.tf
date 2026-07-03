output "superset_public_dns" {
  value       = aws_lb.superset.dns_name
  description = "Public DNS name for the AWS Superset load balancer."
}

output "superset_public_ip" {
  value       = null
  description = "Superset is fronted by an ALB, so there is no fixed public IP."
}

output "superset_url" {
  value       = "http://${aws_lb.superset.dns_name}"
  description = "URL for the AWS-hosted Superset service."
}

output "superset_admin_password" {
  value       = random_password.superset_admin_password.result
  sensitive   = true
  description = "Initial Superset admin password."
}
