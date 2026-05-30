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

function Invoke-AwsCli {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $stdoutFile = Join-Path $env:TEMP "aws-stdout-$([guid]::NewGuid().ToString()).txt"
  $stderrFile = Join-Path $env:TEMP "aws-stderr-$([guid]::NewGuid().ToString()).txt"

  $process = Start-Process -FilePath "aws.exe" -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
  $output = if (Test-Path $stdoutFile) { Get-Content $stdoutFile -Raw } else { "" }
  $errorOutput = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw } else { "" }

  if (Test-Path $stdoutFile) { Remove-Item $stdoutFile -Force }
  if (Test-Path $stderrFile) { Remove-Item $stderrFile -Force }

  [pscustomobject]@{
    ExitCode = $process.ExitCode
    Output   = ($output + $errorOutput).Trim()
  }
}

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$hnZip = Join-Path $buildDir "hn_collector.zip"
$xZip = Join-Path $buildDir "x_collector.zip"

if (Test-Path $hnZip) { Remove-Item $hnZip -Force }
if (Test-Path $xZip) { Remove-Item $xZip -Force }

Compress-Archive -Path (Join-Path $hnDir "*") -DestinationPath $hnZip
Compress-Archive -Path (Join-Path $xDir "*") -DestinationPath $xZip

$env:AWS_ACCESS_KEY_ID = "test"
$env:AWS_SECRET_ACCESS_KEY = "test"
$env:AWS_DEFAULT_REGION = $Region

Invoke-AwsCli @('--endpoint-url', $EndpointUrl, 's3', 'mb', "s3://$BucketName") | Out-Null

$roleArn = "arn:aws:iam::000000000000:role/lambda-role"

$commonEnv = @{
  Variables = @{
    BUCKET_NAME      = $BucketName
    AWS_ENDPOINT_URL = "http://localstack:4566"
    PREFIX           = "bronze/hackernews"
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

Write-Host "LocalStack deployment complete."
Write-Host "Invoke HN: aws --endpoint-url=$EndpointUrl lambda invoke --function-name bronze-hn-local out.json"
Write-Host "Invoke X : aws --endpoint-url=$EndpointUrl lambda invoke --function-name bronze-x-local out.json"
