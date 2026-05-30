param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("hn", "x")]
    [string]$Function,
    [string]$EndpointUrl = "http://localhost:4566",
    [string]$Region = "us-east-1"
)

$awsCommand = Get-Command aws -ErrorAction SilentlyContinue
if (-not $awsCommand) {
    $awsCommand = Get-Command aws.exe -ErrorAction SilentlyContinue
}

if (-not $awsCommand) {
    throw "AWS CLI not found. Install the AWS CLI and make sure 'aws' is available on PATH before running this script."
}

$functionName = if ($Function -eq "hn") { "bronze-hn-local" } else { "bronze-x-local" }
$outputFile = Join-Path $PSScriptRoot "$functionName-response.json"

# Ensure a region is set for the AWS CLI to avoid NoRegion errors
$env:AWS_DEFAULT_REGION = $Region

# Set LocalStack test credentials so the AWS CLI won't complain
$env:AWS_ACCESS_KEY_ID = "test"
$env:AWS_SECRET_ACCESS_KEY = "test"

& $awsCommand.Source --endpoint-url=$EndpointUrl --region $Region lambda invoke --function-name $functionName $outputFile | Out-Null
Get-Content $outputFile
