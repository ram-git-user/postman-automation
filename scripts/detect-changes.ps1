<#
.SYNOPSIS
    Detects which Postman collections changed.

.DESCRIPTION
    Automatically determines the correct Git comparison based on the
    GitHub Actions event.

    Supported Events:
      • Push
      • Pull Request
      • Merge into develop
      • Merge into main

.OUTPUTS
    • changed-collections.json
    • GitHub Actions output:
        changed_collections=api1,api2,...
#>

param(
    [string]$BaseRef,
    [string]$HeadRef = "HEAD"
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================="
Write-Host "Detect Changed Collections"
Write-Host "========================================="

###############################################################
# Mark repository as safe (required on self-hosted runners)
###############################################################

git config --global --add safe.directory (Get-Location).Path 2>$null

###############################################################
# Fetch latest refs
###############################################################

git fetch origin --prune --depth=100 2>$null

###############################################################
# Automatically determine comparison branch
###############################################################

if ([string]::IsNullOrWhiteSpace($BaseRef))
{
    switch ($env:GITHUB_EVENT_NAME)
    {
        "pull_request"
        {
            $BaseRef = "origin/$($env:GITHUB_BASE_REF)"

            Write-Host ""
            Write-Host "Event          : Pull Request"
            Write-Host "Base Branch    : $BaseRef"
            break
        }

        "push"
        {
            $BaseRef = "HEAD~1"

            Write-Host ""
            Write-Host "Event          : Push"
            Write-Host "Compare        : HEAD~1 -> HEAD"
            break
        }

        default
        {
            $BaseRef = "HEAD~1"

            Write-Host ""
            Write-Host "Event          : Unknown ($env:GITHUB_EVENT_NAME)"
            Write-Host "Using HEAD~1"
        }
    }
}

Write-Host ""
Write-Host "Comparing:"
Write-Host "    $BaseRef"
Write-Host "        ↓"
Write-Host "    $HeadRef"
Write-Host ""

###############################################################
# Find changed collections
###############################################################

$changedFiles = git diff `
    --diff-filter=ACM `
    --name-only `
    "$BaseRef" `
    "$HeadRef" `
    -- collections/

$changedFiles = $changedFiles | Where-Object {

    $_ -match '^collections/.*\.json$' -and
    ($_ -notmatch 'regression\.json$')
}

###############################################################
# Extract collection names
###############################################################

$changedCollections = @()

foreach ($file in $changedFiles)
{
    $name = [System.IO.Path]::GetFileNameWithoutExtension($file)

    if ($changedCollections -notcontains $name)
    {
        $changedCollections += $name
    }
}

###############################################################
# Display results
###############################################################

if ($changedCollections.Count -eq 0)
{
    Write-Host ""
    Write-Host "No collection changes detected."
}
else
{
    Write-Host ""
    Write-Host "Changed Collections"
    Write-Host "-------------------"

    foreach ($collection in $changedCollections)
    {
        Write-Host " • $collection"
    }
}

###############################################################
# Save JSON
###############################################################

$changedCollections |
    ConvertTo-Json |
    Set-Content "changed-collections.json"

###############################################################
# GitHub Output
###############################################################

if ($env:GITHUB_OUTPUT)
{
    $joined = $changedCollections -join ","

    "changed_collections=$joined" |
        Out-File `
            -FilePath $env:GITHUB_OUTPUT `
            -Encoding utf8 `
            -Append
}

Write-Host ""
Write-Host "Detection Complete."
Write-Host "========================================="
