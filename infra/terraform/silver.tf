locals {
  silver_tags = merge(local.tags, { Layer = "Silver" })

  silver_bucket_name      = lower(replace("${var.project_name}-silver-${data.aws_caller_identity.current.account_id}-${var.region}", "_", "-"))
  silver_function_name    = "${var.project_name}-silver-normalizer"
  silver_zip_path         = "${path.module}/.build/silver_normalizer.zip"
  silver_users_prefix     = "silver/users"
  silver_posts_prefix     = "silver/posts"
  silver_relations_prefix = "silver/post_relations"
}

resource "aws_s3_bucket" "silver" {
  bucket = local.silver_bucket_name
  tags   = local.silver_tags
}

resource "aws_s3_bucket_public_access_block" "silver" {
  bucket                  = aws_s3_bucket.silver.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "silver" {
  bucket = aws_s3_bucket.silver.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "silver" {
  bucket = aws_s3_bucket.silver.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "silver" {
  bucket = aws_s3_bucket.silver.id

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

data "aws_iam_policy_document" "silver_lambda_runtime" {
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

  statement {
    sid     = "ListBronzeBucket"
    actions = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [
      aws_s3_bucket.bronze.arn,
    ]
  }

  statement {
    sid     = "ReadBronzeObjects"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.bronze.arn}/*",
    ]
  }

  statement {
    sid     = "WriteSilverObjects"
    actions = ["s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${aws_s3_bucket.silver.arn}/*",
    ]
  }

  statement {
    sid     = "ManageSilverBucket"
    actions = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [
      aws_s3_bucket.silver.arn,
    ]
  }
}

resource "aws_iam_role" "silver_lambda" {
  name               = "${var.project_name}-silver-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.silver_tags
}

resource "aws_iam_role_policy" "silver_lambda" {
  name   = "${var.project_name}-silver-inline"
  role   = aws_iam_role.silver_lambda.id
  policy = data.aws_iam_policy_document.silver_lambda_runtime.json
}

data "aws_iam_policy_document" "silver_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.silver.arn,
      "${aws_s3_bucket.silver.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AllowSilverWrites"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.silver_lambda.arn]
    }

    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.silver.arn}/${local.silver_users_prefix}/*",
      "${aws_s3_bucket.silver.arn}/${local.silver_posts_prefix}/*",
      "${aws_s3_bucket.silver.arn}/${local.silver_relations_prefix}/*",
    ]
  }
}

resource "aws_s3_bucket_policy" "silver" {
  bucket = aws_s3_bucket.silver.id
  policy = data.aws_iam_policy_document.silver_bucket.json
}

resource "aws_lambda_function" "silver_normalizer" {
  function_name = local.silver_function_name
  role          = aws_iam_role.silver_lambda.arn
  handler       = "app.lambda_handler"
  runtime       = "python3.12"
  timeout       = 900
  memory_size   = 1024

  filename         = local.silver_zip_path
  source_code_hash = filebase64sha256(local.silver_zip_path)

  vpc_config {
    subnet_ids         = [aws_subnet.private.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      BRONZE_BUCKET           = aws_s3_bucket.bronze.bucket
      SILVER_BUCKET           = aws_s3_bucket.silver.bucket
      BRONZE_HN_PREFIX        = local.hn_prefix
      BRONZE_X_PREFIX         = local.x_prefix
      SILVER_USERS_PREFIX     = local.silver_users_prefix
      SILVER_POSTS_PREFIX     = local.silver_posts_prefix
      SILVER_RELATIONS_PREFIX = local.silver_relations_prefix
    }
  }

  tags = local.silver_tags
}

resource "aws_cloudwatch_log_group" "silver" {
  name              = "/aws/lambda/${aws_lambda_function.silver_normalizer.function_name}"
  retention_in_days = var.collector_log_retention_days
}

resource "aws_cloudwatch_event_rule" "silver_daily" {
  name                = "${var.project_name}-silver-daily"
  schedule_expression = var.silver_cron_expression
  tags                = local.silver_tags
}

resource "aws_cloudwatch_event_target" "silver_daily" {
  rule      = aws_cloudwatch_event_rule.silver_daily.name
  target_id = "silver-normalizer"
  arn       = aws_lambda_function.silver_normalizer.arn
}

resource "aws_lambda_permission" "silver_events" {
  statement_id  = "AllowExecutionFromEventBridgeSilver"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.silver_normalizer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.silver_daily.arn
}