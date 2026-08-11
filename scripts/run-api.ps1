<#
.SYNOPSIS
    Runs one Postman collection via Newman, chaining the shared environment file
    so variables produced by one API (e.g. `otp` from Issuance OTP) are available
    to the next API in the same pipeline run (e.g. Verify OTP).

.NOTES
    Every run's resulting environment is written back over $EnvironmentFile,
    so call this script in dependency order for a given pipeline run.
#>
param(
    [Parameter(Mandatory = $true)][string]$CollectionName,
    [string]$EnvironmentFile = "environment/shared-environment.postman_environment.json",
    [string]$ReportsDir = "reports"
)
$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path $ReportsDir | Out-Null

$collectionPath = "collections/$CollectionName.json"
if (-not (Test-Path $collectionPath)) {
    throw "Collection not found: $collectionPath"
}

$exportedEnv = Join-Path $ReportsDir "env-after-$CollectionName.json"
$junitOut    = Join-Path $ReportsDir "$CollectionName-junit.xml"
$htmlOut     = Join-Path $ReportsDir "$CollectionName-report.html"

Write-Host "==================================================="
Write-Host " Running collection: $CollectionName"
Write-Host "==================================================="

newman run $collectionPath `
    -e $EnvironmentFile `
    --export-environment $exportedEnv `
    --reporters cli,junit,htmlextra `
    --reporter-junit-export $junitOut `
    --reporter-htmlextra-export $htmlOut `
    --reporter-htmlextra-title "$CollectionName Validation" `
    --color on

$exitCode = $LASTEXITCODE

# Chain the environment forward regardless of pass/fail, so partial state
# (and reports) reflect what actually happened.
if (Test-Path $exportedEnv) {
    Copy-Item -Path $exportedEnv -Destination $EnvironmentFile -Force
}

if ($exitCode -ne 0) {
    Write-Error "FAILED: $CollectionName (exit code $exitCode). See $htmlOut / $junitOut"
    exit $exitCode
}

Write-Host "PASSED: $CollectionName"
