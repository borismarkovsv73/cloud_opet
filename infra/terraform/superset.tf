locals {
  superset_name = "${var.project_name}-superset"
}

resource "random_password" "superset_secret_key" {
  length  = 32
  special = false
}

resource "random_password" "superset_admin_password" {
  length  = 16
  special = false
}

resource "aws_security_group" "superset_lb" {
  name        = "${var.project_name}-superset-lb-sg"
  description = "Allow HTTP access to the Superset load balancer"
  vpc_id      = aws_vpc.bronze.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.superset_allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.gold_tags, { Name = "${var.project_name}-superset-lb-sg" })
}

resource "aws_security_group" "superset_task" {
  name        = "${var.project_name}-superset-task-sg"
  description = "Allow Superset task traffic from the load balancer and outbound access to RDS"
  vpc_id      = aws_vpc.bronze.id

  ingress {
    from_port       = 8088
    to_port         = 8088
    protocol        = "tcp"
    security_groups = [aws_security_group.superset_lb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.gold_tags, { Name = "${var.project_name}-superset-task-sg" })
}

resource "aws_security_group_rule" "gold_postgres_from_superset" {
  count                    = var.gold_manage_postgres ? 1 : 0
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.gold_postgres[0].id
  source_security_group_id = aws_security_group.superset_task.id
}

resource "aws_iam_role" "superset_execution" {
  name               = "${var.project_name}-superset-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
  tags               = local.gold_tags
}

resource "aws_iam_role_policy_attachment" "superset_execution" {
  role       = aws_iam_role.superset_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_group" "superset" {
  name              = "/ecs/${local.superset_name}"
  retention_in_days = 7
  tags              = local.gold_tags
}

resource "aws_ecs_cluster" "superset" {
  name = local.superset_name
  tags = local.gold_tags
}

resource "aws_lb" "superset" {
  name               = "${var.project_name}-superset-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.superset_lb.id]
  subnets            = [aws_subnet.public.id]

  tags = merge(local.gold_tags, { Name = "${var.project_name}-superset-alb" })
}

resource "aws_lb_target_group" "superset" {
  name        = "${var.project_name}-superset-tg"
  port        = 8088
  protocol    = "HTTP"
  vpc_id      = aws_vpc.bronze.id
  target_type = "ip"

  health_check {
    path                = "/health"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.gold_tags, { Name = "${var.project_name}-superset-tg" })
}

resource "aws_lb_listener" "superset" {
  load_balancer_arn = aws_lb.superset.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.superset.arn
  }
}

resource "aws_ecs_task_definition" "superset" {
  family                   = local.superset_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.superset_task_cpu
  memory                   = var.superset_task_memory
  execution_role_arn       = aws_iam_role.superset_execution.arn

  container_definitions = jsonencode([
    {
      name      = "superset"
      image     = "apache/superset:4.0.2"
      essential = true
      portMappings = [
        {
          containerPort = 8088
          hostPort      = 8088
          protocol      = "tcp"
        }
      ]
      entryPoint = ["/bin/sh", "-c"]
      command = [
        "superset db upgrade && superset fab create-admin --username ${var.superset_admin_username} --firstname Superset --lastname Admin --email ${var.superset_admin_email} --password ${random_password.superset_admin_password.result} || true && superset init && superset run -h 0.0.0.0 -p 8088"
      ]
      environment = [
        {
          name  = "SUPERSET_SECRET_KEY"
          value = random_password.superset_secret_key.result
        },
        {
          name  = "SUPERSET_LOAD_EXAMPLES"
          value = "no"
        },
        {
          name  = "SQLALCHEMY_DATABASE_URI"
          value = "postgresql+psycopg2://${var.gold_postgres_user}:${random_password.gold_postgres[0].result}@${aws_db_instance.gold[0].address}:5432/${var.gold_postgres_database}"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.superset.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "superset"
        }
      }
    }
  ])

  tags = local.gold_tags
}

resource "aws_ecs_service" "superset" {
  name            = local.superset_name
  cluster         = aws_ecs_cluster.superset.id
  task_definition = aws_ecs_task_definition.superset.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public.id]
    security_groups  = [aws_security_group.superset_task.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.superset.arn
    container_name   = "superset"
    container_port   = 8088
  }

  depends_on = [aws_lb_listener.superset]

  tags = local.gold_tags
}