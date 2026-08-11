<#
.SYNOPSIS
    Detects which collections/*.json files changed between a base ref and the current HEAD.

.OUTPUTS
    - Writes changed-collections.json to the repo root
    - Sets GitHub Actions output "changed_collections" (comma separated, no extension)
#>
param(
    [string]$BaseRef = "origin/develop",
    [string]$HeadRef = "HEAD"
)
$ErrorActionPreference = "Stop"

Write-Host "Comparing $BaseRef ... $HeadRef"

# Make sure we actually have the base ref locally (shallow clones on Actions runners)
git fetch origin --depth=100 2>$null | Out-Null

$changedFiles = git diff --diff-filter=ACM --name-only "$BaseRef" "$HeadRef" -- collections/

$changedFiles = $changedFiles | Where-Object {
    $_ -match '^collections/.*\.json$' -and
    ($_ -notmatch 'regression\.json$')
}
$changedCollections = @()
foreach ($file in $changedFiles) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $changedCollections += $name
}
$changedCollections = $changedCollections | Select-Object -Unique

if ($changedCollections.Count -eq 0) {
    Write-Host "No collection changes detected between $BaseRef and $HeadRef."
} else {
    Write-Host "Changed collections: $($changedCollections -join ', ')"
}

$changedCollections | ConvertTo-Json | Set-Content -Path "changed-collections.json"

$joined = $changedCollections -join ','
if ($env:GITHUB_OUTPUT) {
    "changed_collections=$joined" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
