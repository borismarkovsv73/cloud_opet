provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
    Layer     = "Bronze"
  }

  primary_availability_zone   = "${var.region}${var.availability_zone_suffix}"
  secondary_availability_zone = "${var.region}${var.availability_zone_suffix_2}"
  bucket_name                 = lower(replace("${var.project_name}-${data.aws_caller_identity.current.account_id}-${var.region}", "_", "-"))
  hn_prefix                   = "bronze/hackernews"
  x_prefix                    = "bronze/x"
  hn_function_name            = "${var.project_name}-hn-collector"
  x_function_name             = "${var.project_name}-x-collector"
  hn_zip_path                 = "${path.module}/.build/hn_collector.zip"
  x_zip_path                  = "${path.module}/.build/x_collector.zip"
}

resource "aws_s3_bucket" "bronze" {
  bucket = local.bucket_name
  tags   = local.tags
}

resource "aws_s3_bucket_public_access_block" "bronze" {
  bucket                  = aws_s3_bucket.bronze.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {
      prefix = ""
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_vpc" "bronze" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(local.tags, { Name = "${var.project_name}-vpc" })
}

resource "aws_internet_gateway" "bronze" {
  vpc_id = aws_vpc.bronze.id
  tags   = merge(local.tags, { Name = "${var.project_name}-igw" })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.bronze.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  availability_zone       = local.primary_availability_zone
  tags                    = merge(local.tags, { Name = "${var.project_name}-public-a" })
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.bronze.id
  cidr_block              = var.private_subnet_cidr
  map_public_ip_on_launch = false
  availability_zone       = local.primary_availability_zone
  tags                    = merge(local.tags, { Name = "${var.project_name}-private-a" })
}

resource "aws_subnet" "private_2" {
  vpc_id                  = aws_vpc.bronze.id
  cidr_block              = var.private_subnet_2_cidr
  map_public_ip_on_launch = false
  availability_zone       = local.secondary_availability_zone
  tags                    = merge(local.tags, { Name = "${var.project_name}-private-b" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.bronze.id
  tags   = merge(local.tags, { Name = "${var.project_name}-public-rt" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.bronze.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.project_name}-nat-eip" })
}

resource "aws_nat_gateway" "bronze" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.bronze]
  tags          = merge(local.tags, { Name = "${var.project_name}-nat" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.bronze.id
  tags   = merge(local.tags, { Name = "${var.project_name}-private-rt" })
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.bronze.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_2" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "lambda" {
  name        = "${var.project_name}-lambda-sg"
  description = "Least-privilege egress for Bronze collectors"
  vpc_id      = aws_vpc.bronze.id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.bronze.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = merge(local.tags, { Name = "${var.project_name}-s3-endpoint" })
}

data "archive_file" "hn_collector" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/hn_collector"
  output_path = local.hn_zip_path
}

data "archive_file" "x_collector" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/x_collector"
  output_path = local.x_zip_path
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "shared_lambda_runtime" {
  statement {
    sid       = "CreateLogGroup"
    actions   = ["logs:CreateLogGroup"]
    resources = ["*"]
  }

  statement {
    sid     = "WriteLogEvents"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/*:*",
    ]
  }

  statement {
    sid = "ManageVpcNetworking"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "hn_lambda" {
  name               = "${var.project_name}-hn-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role" "x_lambda" {
  name               = "${var.project_name}-x-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "hn_lambda" {
  name = "${var.project_name}-hn-inline"
  role = aws_iam_role.hn_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      jsondecode(data.aws_iam_policy_document.shared_lambda_runtime.json).Statement,
      [
        {
          Sid      = "WriteHackerNewsBronzeObjects"
          Effect   = "Allow"
          Action   = ["s3:PutObject"]
          Resource = ["${aws_s3_bucket.bronze.arn}/${local.hn_prefix}/*"]
        }
      ]
    )
  })
}

resource "aws_iam_role_policy" "x_lambda" {
  name = "${var.project_name}-x-inline"
  role = aws_iam_role.x_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      jsondecode(data.aws_iam_policy_document.shared_lambda_runtime.json).Statement,
      [
        {
          Sid      = "WriteXBronzeObjects"
          Effect   = "Allow"
          Action   = ["s3:PutObject"]
          Resource = ["${aws_s3_bucket.bronze.arn}/${local.x_prefix}/*"]
        }
      ]
    )
  })
}

data "aws_iam_policy_document" "bronze_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.bronze.arn,
      "${aws_s3_bucket.bronze.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AllowHnWritesFromVpcEndpoint"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.hn_lambda.arn]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.bronze.arn}/${local.hn_prefix}/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [aws_vpc_endpoint.s3.id]
    }
  }

  statement {
    sid    = "AllowXWritesFromVpcEndpoint"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.x_lambda.arn]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.bronze.arn}/${local.x_prefix}/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [aws_vpc_endpoint.s3.id]
    }
  }
}

resource "aws_s3_bucket_policy" "bronze" {
  bucket = aws_s3_bucket.bronze.id
  policy = data.aws_iam_policy_document.bronze_bucket.json
}

resource "aws_lambda_function" "hn_collector" {
  function_name = local.hn_function_name
  role          = aws_iam_role.hn_lambda.arn
  handler       = "app.lambda_handler"
  runtime       = "python3.12"
  timeout       = 300
  memory_size   = 512

  filename         = data.archive_file.hn_collector.output_path
  source_code_hash = data.archive_file.hn_collector.output_base64sha256

  vpc_config {
    subnet_ids         = [aws_subnet.private.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.bronze.bucket
      PREFIX      = local.hn_prefix
    }
  }

  tags = local.tags
}

resource "aws_lambda_function" "x_collector" {
  function_name = local.x_function_name
  role          = aws_iam_role.x_lambda.arn
  handler       = "app.lambda_handler"
  runtime       = "python3.12"
  timeout       = 300
  memory_size   = 512

  filename         = data.archive_file.x_collector.output_path
  source_code_hash = data.archive_file.x_collector.output_base64sha256

  vpc_config {
    subnet_ids         = [aws_subnet.private.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      BUCKET_NAME    = aws_s3_bucket.bronze.bucket
      PREFIX         = local.x_prefix
      X_DATASET_URLS = join(",", var.x_dataset_urls)
    }
  }

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "hn" {
  name              = "/aws/lambda/${aws_lambda_function.hn_collector.function_name}"
  retention_in_days = var.collector_log_retention_days
}

resource "aws_cloudwatch_log_group" "x" {
  name              = "/aws/lambda/${aws_lambda_function.x_collector.function_name}"
  retention_in_days = var.collector_log_retention_days
}

resource "aws_cloudwatch_event_rule" "hn_daily" {
  name                = "${var.project_name}-hn-daily"
  schedule_expression = var.hn_cron_expression
  tags                = local.tags
}

resource "aws_cloudwatch_event_rule" "x_daily" {
  name                = "${var.project_name}-x-daily"
  schedule_expression = var.x_cron_expression
  tags                = local.tags
}

resource "aws_cloudwatch_event_target" "hn_daily" {
  rule      = aws_cloudwatch_event_rule.hn_daily.name
  target_id = "hn-collector"
  arn       = aws_lambda_function.hn_collector.arn
}

resource "aws_cloudwatch_event_target" "x_daily" {
  rule      = aws_cloudwatch_event_rule.x_daily.name
  target_id = "x-collector"
  arn       = aws_lambda_function.x_collector.arn
}

resource "aws_lambda_permission" "hn_events" {
  statement_id  = "AllowExecutionFromEventBridgeHN"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.hn_collector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.hn_daily.arn
}

resource "aws_lambda_permission" "x_events" {
  statement_id  = "AllowExecutionFromEventBridgeX"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.x_collector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.x_daily.arn
}
