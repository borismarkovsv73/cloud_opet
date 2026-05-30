# LocalStack Demo

This folder contains the offline demo path for the Bronze layer.

It uses LocalStack to emulate the AWS services needed for the collectors:

- S3
- Lambda
- IAM
- EventBridge
- CloudWatch Logs

## What You Need

- Docker Desktop running
- AWS CLI installed

You do not need the LocalStack CLI for this setup.

## How It Works

1. Docker starts a LocalStack container.
2. `deploy-localstack.ps1` creates the bucket and Lambda functions.
3. `invoke-localstack.ps1` runs the collectors.
4. The collectors write raw data into the LocalStack S3 bucket.

## Start LocalStack

```powershell
docker compose -f docker-compose.localstack.yml up -d
```

## Deploy The Local Resources

From the project root:

```powershell
.\localstack\deploy-localstack.ps1
```

## Invoke The Collectors

```powershell
.\localstack\invoke-localstack.ps1 -Function hn
.\localstack\invoke-localstack.ps1 -Function x
```

## Check The Output

```powershell
aws --endpoint-url=http://localhost:4566 s3 ls s3://social-bronze-local --recursive
```

If you see objects in the bucket, the local Bronze pipeline works.

## Important Detail

The Lambda containers use `http://localstack:4566` internally.

That is different from the host-side AWS CLI, which uses `http://localhost:4566`.

## Notes

- This local setup is for development and demonstration only.
- The AWS Terraform stack still targets real AWS.
