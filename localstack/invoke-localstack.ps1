param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("hn", "x")]
    [string]$Function,
    [string]$EndpointUrl = "http://localhost:4566"
)

$functionName = if ($Function -eq "hn") { "bronze-hn-local" } else { "bronze-x-local" }
$outputFile = Join-Path $PSScriptRoot "$functionName-response.json"

aws --endpoint-url=$EndpointUrl lambda invoke --function-name $functionName $outputFile | Out-Null
Get-Content $outputFile
