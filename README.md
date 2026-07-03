# Bronze Layer

AWS Bronze layer

## Overview

- `infra/terraform/` - AWS infrastructure
- `lambda/hn_collector/` - Hacker News collector
- `lambda/x_collector/` - X collector
- `localstack/` - local demo
- `docker-compose.localstack.yml` - LocalStack container
- `silver/` - Silver schema notes
- `gold/` - Gold schema, architecture, and PostgreSQL schema

## Data

- Hacker News is collected for the previous UTC day and stored raw in S3
- X uses raw datasets or generated sample data

## Silver layer

The Silver layer normalizes Bronze into Parquet tables:

- `users`
- `posts`
- `post_relations`

See [silver/README.md](silver/README.md) for the column layout.

## Gold layer

The Gold layer turns Silver into daily analytical facts and KPI tables.

See [gold/README.md](gold/README.md) for the architecture, schema, and dashboard suggestions.

## Run locally

```powershell
docker compose -f docker-compose.localstack.yml up -d
.\localstack\deploy-localstack.ps1
.\localstack\invoke-localstack.ps1 -Function hn
.\localstack\invoke-localstack.ps1 -Function x
.\localstack\invoke-localstack.ps1 -Function silver
.\localstack\invoke-localstack.ps1 -Function gold
.\localstack\invoke-localstack.ps1 -Function goldsync
aws --endpoint-url=http://localhost:4566 s3 ls s3://social-bronze-local --recursive
aws --endpoint-url=http://localhost:4566 s3 ls s3://social-silver-local --recursive
aws --endpoint-url=http://localhost:4566 s3 ls s3://social-gold-local --recursive
```

## View the dashboard locally

Start Superset with the same compose file:

```powershell
docker compose -f docker-compose.localstack.yml up -d superset
```

Then open http://localhost:8088 in your browser and sign in with:

- Username: `admin`
- Password: `admin`

Add a PostgreSQL database connection with:

- Host: `localhost`
- Port: `5432`
- Database: `gold`
- Username: `gold_app`
- Password: `gold_password`

After that, create datasets from the Gold fact tables and build charts from [gold/README.md](gold/README.md).

## Deploy to AWS

```powershell
cd h:\Fakultet\Cloud
.\infra\terraform\build-lambda-packages.ps1
cd infra\terraform
terraform init
terraform plan -var-file=example.tfvars -out=tfplan
terraform apply tfplan
```



