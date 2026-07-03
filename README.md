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

Make sure Python 3.12 and pip are available on your machine. The deploy script packages the Silver and Gold Lambda dependencies automatically.

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

The compose file now starts a local PostgreSQL container alongside LocalStack so you can verify the Gold sync step end to end.

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

## View the dashboard on AWS cheaply

If you want the real AWS data, the cheapest practical option in this repo is the small Superset service created by Terraform.

After `terraform apply`, use the outputs for:

- `superset_url`
- `superset_admin_password`
- `gold_postgres_endpoint`

Open the Superset URL in your browser and sign in with:

- Username: `admin`
- Password: the value from `superset_admin_password`

Then add a PostgreSQL database connection with:

- Host: the `gold_postgres_endpoint` output
- Port: `5432`
- Database: `gold`
- Username: `gold_app`
- Password: the Gold password stored in Secrets Manager

## Deployment

```powershell
cd h:\Fakultet\Cloud
.\infra\terraform\build-lambda-packages.ps1
cd infra\terraform
terraform init
terraform plan -var-file=example.tfvars -out=tfplan
terraform apply tfplan



