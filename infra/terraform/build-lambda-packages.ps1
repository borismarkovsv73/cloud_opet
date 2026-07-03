param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
)

$ErrorActionPreference = "Stop"

$terraformDir = (Resolve-Path $PSScriptRoot).Path
$buildDir = Join-Path $terraformDir ".build"
$lambdaDir = Join-Path $Root "lambda"
$requirementsSilver = Join-Path $Root "requirements-silver-local.txt"
$requirementsGold = Join-Path $Root "requirements-gold-local.txt"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is required to build the Lambda packages. Install Docker Desktop and try again."
}

if (-not (Test-Path $requirementsSilver)) {
    throw "Missing requirements file: $requirementsSilver"
}

if (-not (Test-Path $requirementsGold)) {
    throw "Missing requirements file: $requirementsGold"
}

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

function New-LambdaZip {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDir,
        [Parameter(Mandatory = $true)]
        [string]$OutputZip,
        [string]$RequirementsFile = ""
    )

    $sourceMount = $SourceDir -replace '\\', '/'
    $buildMount = $buildDir -replace '\\', '/'
    $projectMount = $Root -replace '\\', '/'

    $script = @"
set -e
rm -rf /tmp/build
mkdir -p /tmp/build
if [ -n '$RequirementsFile' ]; then
  python -m pip install --no-cache-dir --disable-pip-version-check -t /tmp/build -r '$RequirementsFile'
fi
cp -r /src/. /tmp/build/
python - <<'PY'
import os
import zipfile

build_dir = '/tmp/build'
zip_path = '/out/$OutputZip'

with zipfile.ZipFile(zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for root, _, files in os.walk(build_dir):
        for file_name in files:
            file_path = os.path.join(root, file_name)
            archive.write(file_path, os.path.relpath(file_path, build_dir))
PY
"@

    $script = $script -replace "`r", ""

    docker run --rm `
        -v "${sourceMount}:/src:ro" `
        -v "${projectMount}:/project:ro" `
        -v "${buildMount}:/out" `
        python:3.12-slim `
        bash -lc $script
}

New-LambdaZip -SourceDir (Join-Path $lambdaDir "hn_collector") -OutputZip "hn_collector.zip"
New-LambdaZip -SourceDir (Join-Path $lambdaDir "x_collector") -OutputZip "x_collector.zip"
New-LambdaZip -SourceDir (Join-Path $lambdaDir "silver_normalizer") -OutputZip "silver_normalizer.zip" -RequirementsFile "/project/requirements-silver-local.txt"
New-LambdaZip -SourceDir (Join-Path $lambdaDir "gold_metrics") -OutputZip "gold_metrics.zip" -RequirementsFile "/project/requirements-gold-local.txt"
New-LambdaZip -SourceDir (Join-Path $lambdaDir "gold_sync") -OutputZip "gold_sync.zip" -RequirementsFile "/project/requirements-gold-local.txt"

Write-Host "Lambda packages written to $buildDir"