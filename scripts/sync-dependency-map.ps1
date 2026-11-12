<#
.SYNOPSIS
    Scans collections/*.json and makes sure every collection has an entry in
    dependency/dependency-map.json. Any collection found on disk that is NOT
    yet in the map is auto-registered with an empty dependency list ([]),
    i.e. "runs standalone, no known upstream dependency" until a human
    tightens it up. This means a brand-new collection file is picked up,
    tested, and (on develop/main) tagged automatically - zero required edits.

.OUTPUTS
    - Rewrites dependency/dependency-map.json in place (pretty-printed, keeps
      the _comment key) if anything was added.
    - Writes newly-added-collections.json
    - Sets GitHub Actions output "new_collections" (comma separated)
#>
param(
    [string]$CollectionsDir = "collections",
    [string]$DependencyMapPath = "dependency/dependency-map.json"
)
$ErrorActionPreference = "Stop"

$onDisk = Get-ChildItem -Path $CollectionsDir -Filter "*.json" |
    Where-Object { $_.BaseName -ne "regression" } |
    ForEach-Object { $_.BaseName }

$mapRaw = Get-Content $DependencyMapPath -Raw | ConvertFrom-Json

# Preserve as an ordered dictionary so we can round-trip cleanly
$ordered = [ordered]@{}
if ($mapRaw.PSObject.Properties.Name -contains "_comment") {
    $ordered["_comment"] = $mapRaw._comment
}
foreach ($prop in $mapRaw.PSObject.Properties) {
    if ($prop.Name -ne "_comment") {
        $ordered[$prop.Name] = @($prop.Value)
    }
}

$added = @()
foreach ($name in $onDisk) {
    if (-not $ordered.Contains($name)) {
        Write-Host "New collection detected and not yet in dependency-map.json: '$name' -> registering with no dependencies."
        $ordered[$name] = @()
        $added += $name
    }
}

if ($added.Count -gt 0) {
    $ordered | ConvertTo-Json -Depth 5 | Set-Content -Path $DependencyMapPath
    Write-Host "dependency-map.json updated with: $($added -join ', ')"
} else {
    Write-Host "No new collections to register - dependency-map.json already covers everything in $CollectionsDir/."
}

$added | ConvertTo-Json | Set-Content -Path "newly-added-collections.json"
$joined = $added -join ','
if ($env:GITHUB_OUTPUT) {
    "new_collections=$joined" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
