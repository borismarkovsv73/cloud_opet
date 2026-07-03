locals {
  gold_tags = merge(local.tags, { Layer = "Gold" })

  gold_bucket_name        = lower(replace("${var.project_name}-gold-${data.aws_caller_identity.current.account_id}-${var.region}", "_", "-"))
  gold_metrics_name       = "${var.project_name}-gold-metrics"
  gold_sync_name          = "${var.project_name}-gold-sync"
  gold_metrics_zip_path   = "${path.module}/.build/gold_metrics.zip"
  gold_sync_zip_path      = "${path.module}/.build/gold_sync.zip"
  gold_secret_resources   = local.gold_postgres_secret_arn != "" ? [local.gold_postgres_secret_arn] : ["*"]
  gold_item_types_prefix  = "gold/daily_item_counts"
  gold_users_prefix       = "gold/daily_users"
  gold_user_rankings_path = "gold/user_rankings"
  gold_post_rankings_path = "gold/post_rankings"
  gold_dq_prefix          = "gold/data_quality"
}

resource "aws_s3_bucket" "gold" {
  bucket = local.gold_bucket_name
  tags   = local.gold_tags
}

resource "aws_s3_bucket_public_access_block" "gold" {
  bucket                  = aws_s3_bucket.gold.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "gold" {
  bucket = aws_s3_bucket.gold.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "gold" {
  bucket = aws_s3_bucket.gold.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "gold" {
  bucket = aws_s3_bucket.gold.id

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

data "aws_iam_policy_document" "gold_lambda_runtime" {
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

resource "aws_iam_role" "gold_metrics" {
  name               = "${var.project_name}-gold-metrics-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.gold_tags
}

resource "aws_iam_role" "gold_sync" {
  name               = "${var.project_name}-gold-sync-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.gold_tags
}

resource "aws_iam_role_policy" "gold_metrics" {
  name = "${var.project_name}-gold-metrics-inline"
  role = aws_iam_role.gold_metrics.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      jsondecode(data.aws_iam_policy_document.gold_lambda_runtime.json).Statement,
      [
        {
          Sid      = "ReadSilverBucket"
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
          Resource = [aws_s3_bucket.silver.arn]
        },
        {
          Sid      = "ReadSilverObjects"
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = ["${aws_s3_bucket.silver.arn}/*"]
        },
        {
          Sid      = "WriteGoldObjects"
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:PutObject"]
          Resource = [aws_s3_bucket.gold.arn, "${aws_s3_bucket.gold.arn}/*"]
        }
      ]
    )
  })
}

resource "aws_iam_role_policy" "gold_sync" {
  name = "${var.project_name}-gold-sync-inline"
  role = aws_iam_role.gold_sync.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      jsondecode(data.aws_iam_policy_document.gold_lambda_runtime.json).Statement,
      [
        {
          Sid      = "ReadGoldBucket"
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
          Resource = [aws_s3_bucket.gold.arn]
        },
        {
          Sid      = "ReadGoldObjects"
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = ["${aws_s3_bucket.gold.arn}/*"]
        },
        {
          Sid      = "ReadPostgresSecret"
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = local.gold_secret_resources
        }
      ]
    )
  })
}

data "aws_iam_policy_document" "gold_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.gold.arn,
      "${aws_s3_bucket.gold.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AllowGoldWritesFromMetricsLambda"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.gold_metrics.arn]
    }

    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.gold.arn}/${local.gold_item_types_prefix}/*",
      "${aws_s3_bucket.gold.arn}/${local.gold_users_prefix}/*",
      "${aws_s3_bucket.gold.arn}/${local.gold_user_rankings_path}/*",
      "${aws_s3_bucket.gold.arn}/${local.gold_post_rankings_path}/*",
      "${aws_s3_bucket.gold.arn}/${local.gold_dq_prefix}/*",
    ]
  }
}

resource "aws_s3_bucket_policy" "gold" {
  bucket = aws_s3_bucket.gold.id
  policy = data.aws_iam_policy_document.gold_bucket.json
}

resource "aws_lambda_function" "gold_metrics" {
  function_name = local.gold_metrics_name
  role          = aws_iam_role.gold_metrics.arn
  handler       = "app.lambda_handler"
  runtime       = "python3.12"
  timeout       = 900
  memory_size   = 1024

  filename         = local.gold_metrics_zip_path
  source_code_hash = filebase64sha256(local.gold_metrics_zip_path)

  vpc_config {
    subnet_ids         = [aws_subnet.private.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      SILVER_BUCKET           = aws_s3_bucket.silver.bucket
      GOLD_BUCKET             = aws_s3_bucket.gold.bucket
      SILVER_USERS_PREFIX     = local.silver_users_prefix
      SILVER_POSTS_PREFIX     = local.silver_posts_prefix
      SILVER_RELATIONS_PREFIX = local.silver_relations_prefix
      GOLD_PREFIX             = "gold"
    }
  }

  tags = local.gold_tags
}

resource "aws_lambda_function" "gold_sync" {
  function_name = local.gold_sync_name
  role          = aws_iam_role.gold_sync.arn
  handler       = "app.lambda_handler"
  runtime       = "python3.12"
  timeout       = 900
  memory_size   = 1024

  filename         = local.gold_sync_zip_path
  source_code_hash = filebase64sha256(local.gold_sync_zip_path)

  vpc_config {
    subnet_ids         = [aws_subnet.private.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      GOLD_BUCKET         = aws_s3_bucket.gold.bucket
      POSTGRES_SECRET_ARN = local.gold_postgres_secret_arn
      POSTGRES_HOST       = local.gold_postgres_host
      POSTGRES_PORT       = tostring(var.gold_postgres_port)
      POSTGRES_DATABASE   = var.gold_postgres_database
      POSTGRES_USER       = var.gold_postgres_user
      POSTGRES_PASSWORD   = var.gold_manage_postgres ? "" : var.gold_postgres_password
    }
  }

  tags = local.gold_tags
}

resource "aws_cloudwatch_log_group" "gold_metrics" {
  name              = "/aws/lambda/${aws_lambda_function.gold_metrics.function_name}"
  retention_in_days = var.collector_log_retention_days
}

resource "aws_cloudwatch_log_group" "gold_sync" {
  name              = "/aws/lambda/${aws_lambda_function.gold_sync.function_name}"
  retention_in_days = var.collector_log_retention_days
}

resource "aws_cloudwatch_event_rule" "gold_metrics_daily" {
  name                = "${var.project_name}-gold-metrics-daily"
  schedule_expression = var.gold_metrics_cron_expression
  tags                = local.gold_tags
}

resource "aws_cloudwatch_event_rule" "gold_sync_daily" {
  name                = "${var.project_name}-gold-sync-daily"
  schedule_expression = var.gold_sync_cron_expression
  tags                = local.gold_tags
}

resource "aws_cloudwatch_event_target" "gold_metrics_daily" {
  rule      = aws_cloudwatch_event_rule.gold_metrics_daily.name
  target_id = "gold-metrics"
  arn       = aws_lambda_function.gold_metrics.arn
}

resource "aws_cloudwatch_event_target" "gold_sync_daily" {
  rule      = aws_cloudwatch_event_rule.gold_sync_daily.name
  target_id = "gold-sync"
  arn       = aws_lambda_function.gold_sync.arn
}

resource "aws_lambda_permission" "gold_metrics_events" {
  statement_id  = "AllowExecutionFromEventBridgeGoldMetrics"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.gold_metrics.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.gold_metrics_daily.arn
}

resource "aws_lambda_permission" "gold_sync_events" {
  statement_id  = "AllowExecutionFromEventBridgeGoldSync"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.gold_sync.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.gold_sync_daily.arn
}
