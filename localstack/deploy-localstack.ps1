param(
    [string]$EndpointUrl = "http://localhost:4566",
    [string]$Region = "us-east-1",
    [string]$BucketName = "social-bronze-local"
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$buildDir = Join-Path $root ".localstack-build"
$lambdaDir = Join-Path $root "lambda"
$hnDir = Join-Path $lambdaDir "hn_collector"
$xDir = Join-Path $lambdaDir "x_collector"
$silverDir = Join-Path $lambdaDir "silver_normalizer"
$goldMetricsDir = Join-Path $lambdaDir "gold_metrics"
$goldSyncDir = Join-Path $lambdaDir "gold_sync"
$silverRequirements = Join-Path $root "requirements-silver-local.txt"
$goldRequirements = Join-Path $root "requirements-gold-local.txt"

function Invoke-AwsCli {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $awsCommand = Get-Command aws -ErrorAction SilentlyContinue
  if (-not $awsCommand) {
    $awsCommand = Get-Command aws.exe -ErrorAction SilentlyContinue
  }

  if (-not $awsCommand) {
    throw "AWS CLI not found. Install the AWS CLI and make sure 'aws' is available on PATH before running this script."
  }

  $stdoutFile = Join-Path $env:TEMP "aws-stdout-$([guid]::NewGuid().ToString()).txt"
  $stderrFile = Join-Path $env:TEMP "aws-stderr-$([guid]::NewGuid().ToString()).txt"

  $process = Start-Process -FilePath $awsCommand.Source -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
  $output = if (Test-Path $stdoutFile) { Get-Content $stdoutFile -Raw } else { "" }
  $errorOutput = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw } else { "" }

  if (Test-Path $stdoutFile) { Remove-Item $stdoutFile -Force }
  if (Test-Path $stderrFile) { Remove-Item $stderrFile -Force }

  [pscustomobject]@{
    ExitCode = $process.ExitCode
    Output   = ($output + $errorOutput).Trim()
  }
}

function New-LambdaZip {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceMount,
    [Parameter(Mandatory = $true)]
    [string]$RequirementsFile,
    [Parameter(Mandatory = $true)]
    [string]$OutputZipName
  )

  $zipBuildScript = @"
set -e
mkdir -p /tmp/build
python -m pip install --no-cache-dir --disable-pip-version-check -t /tmp/build -r $RequirementsFile
cp -r /src/. /tmp/build/
python - <<'PY'
import os
import zipfile

build_dir = '/tmp/build'
zip_path = '/out/$OutputZipName'

with zipfile.ZipFile(zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
  for root, _, files in os.walk(build_dir):
    for file_name in files:
      file_path = os.path.join(root, file_name)
      archive.write(file_path, os.path.relpath(file_path, build_dir))
PY
"@

  $zipBuildScript = $zipBuildScript -replace "`r", ""

  docker run --rm `
    -v "${SourceMount}:/src:ro" `
    -v "${projectMount}:/project:ro" `
    -v "${buildDir}:/out" `
    python:3.12-slim `
    bash -lc $zipBuildScript
}

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$hnZip = Join-Path $buildDir "hn_collector.zip"
$xZip = Join-Path $buildDir "x_collector.zip"
$silverZip = Join-Path $buildDir "silver_normalizer.zip"
$goldMetricsZip = Join-Path $buildDir "gold_metrics.zip"
$goldSyncZip = Join-Path $buildDir "gold_sync.zip"

if (Test-Path $hnZip) { Remove-Item $hnZip -Force }
if (Test-Path $xZip) { Remove-Item $xZip -Force }
if (Test-Path $silverZip) { Remove-Item $silverZip -Force }
if (Test-Path $goldMetricsZip) { Remove-Item $goldMetricsZip -Force }
if (Test-Path $goldSyncZip) { Remove-Item $goldSyncZip -Force }

Compress-Archive -Path (Join-Path $hnDir "*") -DestinationPath $hnZip
Compress-Archive -Path (Join-Path $xDir "*") -DestinationPath $xZip

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker is required to package the Silver Lambda for LocalStack. Install Docker Desktop and try again."
}

if (-not (Test-Path $silverRequirements)) {
  throw "Missing $silverRequirements. Add the Silver local requirements file before running this script."
}

if (-not (Test-Path $goldRequirements)) {
  throw "Missing $goldRequirements. Add the Gold local requirements file before running this script."
}

$silverSourceMount = "$($silverDir -replace '\\', '/')"
$projectMount = "$($root -replace '\\', '/')"
$goldMetricsSourceMount = "$($goldMetricsDir -replace '\\', '/')"
$goldSyncSourceMount = "$($goldSyncDir -replace '\\', '/')"

New-LambdaZip -SourceMount $silverSourceMount -RequirementsFile "/project/requirements-silver-local.txt" -OutputZipName "silver_normalizer.zip"
New-LambdaZip -SourceMount $goldMetricsSourceMount -RequirementsFile "/project/requirements-gold-local.txt" -OutputZipName "gold_metrics.zip"
New-LambdaZip -SourceMount $goldSyncSourceMount -RequirementsFile "/project/requirements-gold-local.txt" -OutputZipName "gold_sync.zip"

$env:AWS_ACCESS_KEY_ID = "test"
$env:AWS_SECRET_ACCESS_KEY = "test"
$env:AWS_DEFAULT_REGION = $Region

Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 's3', 'mb', "s3://$BucketName") | Out-Null

$silverBucketName = "social-silver-local"
Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 's3', 'mb', "s3://$silverBucketName") | Out-Null

$goldBucketName = "social-gold-local"
Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 's3', 'mb', "s3://$goldBucketName") | Out-Null

$roleArn = "arn:aws:iam::000000000000:role/lambda-role"

$commonEnv = @{
  Variables = @{
    BUCKET_NAME      = $BucketName
    AWS_ENDPOINT_URL = "http://localstack:4566"
    PREFIX           = "bronze/hackernews"
    HN_FIXTURE_DIR   = "/var/task/fixtures"
  }
}
$commonEnvFile = Join-Path $env:TEMP "localstack-hn-env-$([guid]::NewGuid().ToString()).json"
[System.IO.File]::WriteAllText($commonEnvFile, ($commonEnv | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

$hnCreate = Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 'lambda', 'create-function', '--function-name', 'bronze-hn-local', '--runtime', 'python3.12', '--handler', 'app.lambda_handler', '--zip-file', "fileb://$hnZip", '--role', $roleArn, '--timeout', '60', '--memory-size', '512', '--environment', "file://$commonEnvFile")
if ($hnCreate.ExitCode -ne 0) {
    Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 'lambda', 'update-function-code', '--function-name', 'bronze-hn-local', '--zip-file', "fileb://$hnZip") | Out-Null
  Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 'lambda', 'update-function-configuration', '--function-name', 'bronze-hn-local', '--role', $roleArn, '--timeout', '60', '--memory-size', '512', '--environment', "file://$commonEnvFile") | Out-Null
}

$xEnv = @{
  Variables = @{
    BUCKET_NAME      = $BucketName
    AWS_ENDPOINT_URL = "http://localstack:4566"
    PREFIX           = "bronze/x"
  }
}
$xEnvFile = Join-Path $env:TEMP "localstack-x-env-$([guid]::NewGuid().ToString()).json"
[System.IO.File]::WriteAllText($xEnvFile, ($xEnv | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

$xCreate = Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 'lambda', 'create-function', '--function-name', 'bronze-x-local', '--runtime', 'python3.12', '--handler', 'app.lambda_handler', '--zip-file', "fileb://$xZip", '--role', $roleArn, '--timeout', '60', '--memory-size', '512', '--environment', "file://$xEnvFile")
if ($xCreate.ExitCode -ne 0) {
    Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 'lambda', 'update-function-code', '--function-name', 'bronze-x-local', '--zip-file', "fileb://$xZip") | Out-Null
  Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 'lambda', 'update-function-configuration', '--function-name', 'bronze-x-local', '--role', $roleArn, '--timeout', '60', '--memory-size', '512', '--environment', "file://$xEnvFile") | Out-Null
}

$silverEnv = @{
  Variables = @{
    BRONZE_BUCKET           = $BucketName
    SILVER_BUCKET           = $silverBucketName
    AWS_ENDPOINT_URL        = "http://localstack:4566"
    BRONZE_HN_PREFIX        = "bronze/hackernews/raw"
    BRONZE_X_PREFIX         = "bronze/x"
    HN_USER_FIXTURE_DIR     = "/var/task/fixtures"
    SILVER_USERS_PREFIX     = "silver/users"
    SILVER_POSTS_PREFIX     = "silver/posts"
    SILVER_RELATIONS_PREFIX = "silver/post_relations"
  }
}
$silverEnvFile = Join-Path $env:TEMP "localstack-silver-env-$([guid]::NewGuid().ToString()).json"
[System.IO.File]::WriteAllText($silverEnvFile, ($silverEnv | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

$silverCreate = Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 'lambda', 'create-function', '--function-name', 'silver-normalizer-local', '--runtime', 'python3.12', '--handler', 'app.lambda_handler', '--zip-file', "fileb://$silverZip", '--role', $roleArn, '--timeout', '900', '--memory-size', '1024', '--environment', "file://$silverEnvFile")
if ($silverCreate.ExitCode -ne 0) {
    Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 'lambda', 'update-function-code', '--function-name', 'silver-normalizer-local', '--zip-file', "fileb://$silverZip") | Out-Null
    Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 'lambda', 'update-function-configuration', '--function-name', 'silver-normalizer-local', '--role', $roleArn, '--timeout', '900', '--memory-size', '1024', '--environment', "file://$silverEnvFile") | Out-Null
}

$goldMetricsEnv = @{
  Variables = @{
    SILVER_BUCKET           = $silverBucketName
    GOLD_BUCKET             = $goldBucketName
    AWS_ENDPOINT_URL        = "http://localstack:4566"
    SILVER_USERS_PREFIX     = "silver/users"
    SILVER_POSTS_PREFIX     = "silver/posts"
    SILVER_RELATIONS_PREFIX = "silver/post_relations"
    GOLD_PREFIX             = "gold"
    HN_USER_FIXTURE_DIR     = "/var/task/fixtures"
  }
}
$goldMetricsEnvFile = Join-Path $env:TEMP "localstack-gold-metrics-env-$([guid]::NewGuid().ToString()).json"
[System.IO.File]::WriteAllText($goldMetricsEnvFile, ($goldMetricsEnv | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

$goldMetricsCreate = Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 'lambda', 'create-function', '--function-name', 'gold-metrics-local', '--runtime', 'python3.12', '--handler', 'app.lambda_handler', '--zip-file', "fileb://$goldMetricsZip", '--role', $roleArn, '--timeout', '900', '--memory-size', '1024', '--environment', "file://$goldMetricsEnvFile")
if ($goldMetricsCreate.ExitCode -ne 0) {
    Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 'lambda', 'update-function-code', '--function-name', 'gold-metrics-local', '--zip-file', "fileb://$goldMetricsZip") | Out-Null
    Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 'lambda', 'update-function-configuration', '--function-name', 'gold-metrics-local', '--role', $roleArn, '--timeout', '900', '--memory-size', '1024', '--environment', "file://$goldMetricsEnvFile") | Out-Null
}

$goldSyncEnv = @{
  Variables = @{
    GOLD_BUCKET       = $goldBucketName
    AWS_ENDPOINT_URL  = "http://localstack:4566"
    POSTGRES_HOST     = "cloud-bronze-postgres"
    POSTGRES_PORT     = "5432"
    POSTGRES_DATABASE = "gold"
    POSTGRES_USER     = "gold_app"
    POSTGRES_PASSWORD = "gold_password"
  }
}
$goldSyncEnvFile = Join-Path $env:TEMP "localstack-gold-sync-env-$([guid]::NewGuid().ToString()).json"
[System.IO.File]::WriteAllText($goldSyncEnvFile, ($goldSyncEnv | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

$goldSyncCreate = Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 'lambda', 'create-function', '--function-name', 'gold-sync-local', '--runtime', 'python3.12', '--handler', 'app.lambda_handler', '--zip-file', "fileb://$goldSyncZip", '--role', $roleArn, '--timeout', '900', '--memory-size', '1024', '--environment', "file://$goldSyncEnvFile")
if ($goldSyncCreate.ExitCode -ne 0) {
    Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 'lambda', 'update-function-code', '--function-name', 'gold-sync-local', '--zip-file', "fileb://$goldSyncZip") | Out-Null
    Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 'lambda', 'update-function-configuration', '--function-name', 'gold-sync-local', '--role', $roleArn, '--timeout', '900', '--memory-size', '1024', '--environment', "file://$goldSyncEnvFile") | Out-Null
}

Write-Host "LocalStack deployment complete."
Write-Host "Invoke HN: aws --endpoint-url=$EndpointUrl lambda invoke --function-name bronze-hn-local out.json"
Write-Host "Invoke X : aws --endpoint-url=$EndpointUrl lambda invoke --function-name bronze-x-local out.json"
Write-Host "Invoke Silver: aws --endpoint-url=$EndpointUrl lambda invoke --function-name silver-normalizer-local out.json"
Write-Host "Invoke Gold metrics: aws --endpoint-url=$EndpointUrl lambda invoke --function-name gold-metrics-local out.json"
Write-Host "Invoke Gold sync: aws --endpoint-url=$EndpointUrl lambda invoke --function-name gold-sync-local out.json"
