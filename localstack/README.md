# LocalStack Demo

This folder contains the offline demo path for the Bronze layer.

It uses LocalStack to emulate the AWS services needed for the pipeline plus a local Postgres container for Gold sync:

- S3
- Lambda
- IAM
- EventBridge
- CloudWatch Logs
- PostgreSQL

## What You Need

- Docker Desktop running
- AWS CLI installed
- Python 3.12 with pip available

You do not need the LocalStack CLI for this setup.

## How It Works

1. Docker starts a LocalStack container.
2. `deploy-localstack.ps1` creates the Bronze, Silver, and Gold buckets and Lambda functions.
3. `invoke-localstack.ps1` runs the collectors.
4. The collectors write raw data into the LocalStack S3 bucket.
5. The Silver Lambda normalizes Bronze data into Parquet in a second bucket.
6. The Gold Lambdas calculate KPI Parquet files and sync them into PostgreSQL.

## Start LocalStack

```powershell
docker compose -f docker-compose.localstack.yml up -d
```

## Start Superset

```powershell
docker compose -f docker-compose.localstack.yml up -d superset
```

Open http://localhost:8088 and sign in with `admin` / `admin`.

Connect Superset to PostgreSQL using host `localhost`, port `5432`, database `gold`, user `gold_app`, and password `gold_password`.

## Deploy The Local Resources

From the project root:

```powershell
.\localstack\deploy-localstack.ps1
```

## Invoke The Collectors

```powershell
.\localstack\invoke-localstack.ps1 -Function hn
.\localstack\invoke-localstack.ps1 -Function x
.\localstack\invoke-localstack.ps1 -Function silver
.\localstack\invoke-localstack.ps1 -Function gold
.\localstack\invoke-localstack.ps1 -Function goldsync
```

## Check The Output

```powershell
aws --endpoint-url=http://localhost:4566 s3 ls s3://social-bronze-local --recursive
aws --endpoint-url=http://localhost:4566 s3 ls s3://social-silver-local --recursive
aws --endpoint-url=http://localhost:4566 s3 ls s3://social-gold-local --recursive
```

If you see objects in the Gold bucket and rows in the local Postgres database, the local pipeline works through Gold.

## Important Detail

The Lambda containers use `http://localstack:4566` internally.

That is different from the host-side AWS CLI, which uses `http://localhost:4566`.

## Notes

- This local setup is for development and demonstration only.
- The AWS Terraform stack still targets real AWS.
