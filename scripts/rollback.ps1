<#
.SYNOPSIS
    Rolls the given branch back to a known-good Git tag (default: last-stable).
    Used automatically by production-validation.yml on failure, and available
    as a manual workflow_dispatch (rollback.yml) for emergency use.
#>
param(
    [string]$StableTag = "last-stable",
    [string]$Branch = "main"
)
$ErrorActionPreference = "Stop"

git fetch --tags --force

$exists = git tag -l $StableTag
if (-not $exists) {
    throw "No stable tag '$StableTag' found in this repository. Cannot roll back automatically - a human needs to pick a commit manually."
}

$targetCommit = git rev-list -n 1 $StableTag
Write-Host "Rolling back branch '$Branch' to tag '$StableTag' ($targetCommit)"

git checkout $Branch
git reset --hard $StableTag
git push origin $Branch --force-with-lease

Write-Host "Rollback complete. '$Branch' now points at $targetCommit ('$StableTag')."
