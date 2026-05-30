# Bronze Layer

AWS Bronze layer

## Overview

- `infra/terraform/` - AWS infrastructure
- `lambda/hn_collector/` - Hacker News collector
- `lambda/x_collector/` - X collector
- `localstack/` - local demo
- `docker-compose.localstack.yml` - LocalStack container

## Data

- Hacker News is collected for the previous UTC day and stored raw in S3
- X uses raw datasets or generated sample data

## Run locally

```powershell
docker compose -f docker-compose.localstack.yml up -d
.\localstack\deploy-localstack.ps1
.\localstack\invoke-localstack.ps1 -Function hn
.\localstack\invoke-localstack.ps1 -Function x
aws --endpoint-url=http://localhost:4566 s3 ls s3://social-bronze-local --recursive
```

## Deploy to AWS

```powershell
cd infra\terraform
terraform init
terraform plan
terraform apply
```



