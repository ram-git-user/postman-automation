<#
.SYNOPSIS
    Runs the entire collection set end-to-end in a safe order, resetting the
    shared environment first so no state leaks in from a previous run.
    Stops at the first failure (a later API may depend on an earlier one),
    and always writes reports/summary.json.

.NOTES
    The order here is derived by topologically sorting dependency-map.json,
    so adding a new independent API does not require editing this script.
    Only APIs that genuinely have no ordering constraint could theoretically
    run in parallel in a future version; kept sequential here for simplicity
    and because Verify OTP must trail Issuance OTP.
#>
param(
    [string]$DependencyMapPath = "dependency/dependency-map.json",
    [string]$EnvironmentTemplate = "environment/shared-environment.postman_environment.json",
    [string]$EnvironmentFile = "environment/shared-environment.postman_environment.json",
    [string]$ReportsDir = "reports"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $ReportsDir | Out-Null

# --- Auto-discover any collection on disk that isn't in the map yet, so a  ---
# --- brand-new collections/*.json is always included in the full run,     ---
# --- even if nobody remembered to edit dependency-map.json.               ---
& "$PSScriptRoot/sync-dependency-map.ps1" -DependencyMapPath $DependencyMapPath | Out-Null

# --- Build full run order via topological sort of dependency-map.json ---
$mapRaw = Get-Content $DependencyMapPath -Raw | ConvertFrom-Json
$allCollections = @()
$map = @{}
$mapRaw.PSObject.Properties | ForEach-Object {
    if ($_.Name -ne "_comment") {
        $allCollections += $_.Name
        $map[$_.Name] = @($_.Value)
    }
}

$order = New-Object System.Collections.Generic.List[string]
$visiting = New-Object System.Collections.Generic.HashSet[string]

function Resolve-All {
    param([string]$Name)
    if ($order.Contains($Name)) { return }
    if ($visiting.Contains($Name)) { throw "Circular dependency detected involving '$Name'." }
    $visiting.Add($Name) | Out-Null
    foreach ($dep in $map[$Name]) { Resolve-All -Name $dep }
    $visiting.Remove($Name) | Out-Null
    $order.Add($Name)
}

foreach ($c in $allCollections) { Resolve-All -Name $c }

Write-Host "Regression order: $($order -join ' -> ')"

# --- Reset environment to a clean template before the run ---
if (Test-Path "environment/shared-environment.postman_environment.json") {
    Copy-Item -Path "environment/shared-environment.postman_environment.json" -Destination $EnvironmentFile -Force
}

$results = @()
$overallPass = $true

foreach ($c in $order) {
    try {
        & "$PSScriptRoot/run-api.ps1" -CollectionName $c -EnvironmentFile $EnvironmentFile -ReportsDir $ReportsDir
        $results += [PSCustomObject]@{ collection = $c; status = "PASSED"; error = $null }
    } catch {
        $results += [PSCustomObject]@{ collection = $c; status = "FAILED"; error = $_.Exception.Message }
        $overallPass = $false
        Write-Host "Stopping regression at first failure: $c"
        break
    }
}

$summary = [PSCustomObject]@{
    timestamp      = (Get-Date).ToString("o")
    overallStatus  = if ($overallPass) { "PASSED" } else { "FAILED" }
    executionOrder = $order
    results        = $results
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $ReportsDir "summary.json")

Write-Host "==================================================="
Write-Host " Regression summary: $($summary.overallStatus)"
Write-Host "==================================================="
$results | ForEach-Object { Write-Host " - $($_.collection): $($_.status)" }

if (-not $overallPass) {
    exit 1
}
