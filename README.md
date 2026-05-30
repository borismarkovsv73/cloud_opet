# Bronze Layer

This workspace contains the Bronze layer for a social data lake built with AWS-style medallion architecture.

The Bronze layer only collects and stores raw source data. It does not enrich, normalize, or transform the payloads.

## What This Project Does

- Collects Hacker News stories, asks, comments, jobs, and polls from the previous UTC day
- Stores the raw Hacker News API responses in S3
- Stores raw X datasets or generated raw sample data in S3
- Keeps the Bronze layer inside a VPC for the AWS deployment

## Main Folders

- `infra/terraform/` - production AWS infrastructure with Terraform
- `lambda/hn_collector/` - Hacker News Bronze collector
- `lambda/x_collector/` - X Bronze collector
- `localstack/` - local-only demo and deployment scripts
- `docker-compose.localstack.yml` - LocalStack container definition

Generated folders you can ignore:

- `.localstack/` - LocalStack runtime data
- `.localstack-build/` - zipped Lambda artifacts created by the local deploy script

You do not need every folder for every use case:

- If you want the AWS version, you mainly need `infra/terraform/` and `lambda/`
- If you want the offline demo, you mainly need `localstack/`, `lambda/`, and `docker-compose.localstack.yml`

## How To Tell If It Works

For the local demo:

```powershell
docker compose -f docker-compose.localstack.yml up -d
.\localstack\deploy-localstack.ps1
.\localstack\invoke-localstack.ps1 -Function hn
.\localstack\invoke-localstack.ps1 -Function x
aws --endpoint-url=http://localhost:4566 s3 ls s3://social-bronze-local --recursive
```

If those commands succeed, the Bronze layer is working locally.

For AWS, the equivalent test is to deploy Terraform and confirm the Lambda outputs and S3 objects in the AWS console.

## Data Layout

The Bronze bucket stores raw, source-shaped objects only.

- `bronze/hackernews/raw/...` for raw Hacker News API page responses grouped by source type
- `bronze/x/...` for raw X data or generated sample records

## AWS Infrastructure

The Terraform stack creates:

- a VPC with public and private subnets
- a NAT gateway for outbound API access
- an S3 gateway endpoint
- two Lambda functions
- daily EventBridge schedules
- least-privilege IAM roles

## Source Notes

- Hacker News uses the Algolia API at `https://hn.algolia.com/api`
- The collector pulls previous-day pages for story, ask, comment, job, and poll sources
- X uses raw datasets or generated sample data when a public dataset is not available

## Deploy To AWS

From `infra/terraform/`:

```powershell
terraform init
terraform plan
terraform apply
```

## Local Demo Without AWS

If you cannot access AWS, use the local demo documented in [localstack/README.md](localstack/README.md).

