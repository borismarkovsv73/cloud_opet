locals {
  gold_postgres_secret_arn = var.gold_manage_postgres ? aws_secretsmanager_secret.gold_postgres[0].arn : var.gold_postgres_secret_arn
  gold_postgres_host       = var.gold_manage_postgres ? aws_db_instance.gold[0].address : var.gold_postgres_host
  gold_postgres_password   = var.gold_manage_postgres ? random_password.gold_postgres[0].result : var.gold_postgres_password
}

resource "random_password" "gold_postgres" {
  count   = var.gold_manage_postgres ? 1 : 0
  length  = 24
  special = false
}

resource "aws_db_subnet_group" "gold" {
  count      = var.gold_manage_postgres ? 1 : 0
  name       = "${var.project_name}-gold-db-subnet-group"
  subnet_ids = [aws_subnet.private.id, aws_subnet.private_2.id]

  tags = merge(local.gold_tags, { Name = "${var.project_name}-gold-db-subnet-group" })
}

resource "aws_security_group" "gold_postgres" {
  count       = var.gold_manage_postgres ? 1 : 0
  name        = "${var.project_name}-gold-postgres-sg"
  description = "Allow PostgreSQL from Lambda security group only"
  vpc_id      = aws_vpc.bronze.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  tags = merge(local.gold_tags, { Name = "${var.project_name}-gold-postgres-sg" })
}

resource "aws_db_instance" "gold" {
  count                   = var.gold_manage_postgres ? 1 : 0
  identifier              = "${var.project_name}-gold-postgres"
  engine                  = "postgres"
  instance_class          = var.gold_postgres_instance_class
  allocated_storage       = var.gold_postgres_allocated_storage
  db_name                 = var.gold_postgres_database
  username                = var.gold_postgres_user
  password                = random_password.gold_postgres[0].result
  publicly_accessible     = false
  storage_encrypted       = true
  skip_final_snapshot     = true
  deletion_protection     = true
  backup_retention_period = var.gold_postgres_backup_retention_days
  db_subnet_group_name    = aws_db_subnet_group.gold[0].name
  vpc_security_group_ids  = [aws_security_group.gold_postgres[0].id]

  tags = merge(local.gold_tags, { Name = "${var.project_name}-gold-postgres" })
}

resource "aws_secretsmanager_secret" "gold_postgres" {
  count                   = var.gold_manage_postgres ? 1 : 0
  name                    = "${var.project_name}-gold-postgres"
  recovery_window_in_days = 7

  tags = local.gold_tags
}

resource "aws_secretsmanager_secret_version" "gold_postgres" {
  count     = var.gold_manage_postgres ? 1 : 0
  secret_id = aws_secretsmanager_secret.gold_postgres[0].id
  secret_string = jsonencode({
    host     = aws_db_instance.gold[0].address
    port     = aws_db_instance.gold[0].port
    database = var.gold_postgres_database
    username = var.gold_postgres_user
    password = random_password.gold_postgres[0].result
  })
}