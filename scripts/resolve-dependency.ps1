<#
.SYNOPSIS
    Given one or more changed collection names, produces the full, correctly
    ordered set of collections that must run:
      1. Downstream dependents of what changed (an API that CONSUMES a
         changed API's output must be re-verified - e.g. changing
         issuance-otp automatically pulls verify-otp into the run).
      2. Upstream dependencies of everything in that set (an API that
         PRODUCES state a target needs must run first - e.g. verify-otp
         needs issuance-otp to run first for the `otp` variable).
    The result is a single topologically-sorted execution order.

.EXAMPLE
    ./resolve-dependency.ps1 -ChangedCollections @("issuance-otp")
    # issuance-otp has a downstream dependent (verify-otp), which itself has
    # no further downstream dependents, and issuance-otp has no upstream deps.
    # -> execution-order.json = ["issuance-otp", "verify-otp"]

.EXAMPLE
    ./resolve-dependency.ps1 -ChangedCollections @("verify-otp")
    # verify-otp has no downstream dependents, but needs issuance-otp upstream.
    # -> execution-order.json = ["issuance-otp", "verify-otp"]
#>
param(
    [Parameter(Mandatory = $true)][string[]]$ChangedCollections,
    [string]$DependencyMapPath = "dependency/dependency-map.json"
)
$ErrorActionPreference = "Stop"

if (-not (Test-Path $DependencyMapPath)) {
    throw "Dependency map not found at $DependencyMapPath"
}

$mapRaw = Get-Content $DependencyMapPath -Raw | ConvertFrom-Json
$forward = @{}   # collection -> upstream deps that must run BEFORE it
$mapRaw.PSObject.Properties | ForEach-Object {
    if ($_.Name -ne "_comment") {
        $forward[$_.Name] = @($_.Value)
    }
}

# Build the reverse map: collection -> collections that depend ON it (downstream dependents)
$reverse = @{}
foreach ($name in $forward.Keys) { $reverse[$name] = New-Object System.Collections.Generic.List[string] }
foreach ($name in $forward.Keys) {
    foreach ($dep in $forward[$name]) {
        if (-not $reverse.ContainsKey($dep)) { $reverse[$dep] = New-Object System.Collections.Generic.List[string] }
        $reverse[$dep].Add($name)
    }
}

# --- Step 1: expand the changed set to include all downstream dependents (transitively) ---
$impacted = New-Object System.Collections.Generic.HashSet[string]

function Add-Downstream {
    param([string]$Name)
    if ($impacted.Contains($Name)) { return }
    $impacted.Add($Name) | Out-Null
    if ($reverse.ContainsKey($Name)) {
        foreach ($dependent in $reverse[$Name]) { Add-Downstream -Name $dependent }
    }
}

foreach ($c in $ChangedCollections) {
    if ([string]::IsNullOrWhiteSpace($c)) { continue }
    Add-Downstream -Name $c.Trim()
}

Write-Host "Impacted set (changed API(s) + their downstream dependents): $($impacted -join ', ')"

# --- Step 2: topologically order the impacted set, pulling in upstream deps as needed ---
$order = New-Object System.Collections.Generic.List[string]
$visiting = New-Object System.Collections.Generic.HashSet[string]

function Resolve-Deps {
    param([string]$Name)
    if ($order.Contains($Name)) { return }
    if ($visiting.Contains($Name)) {
        throw "Circular dependency detected involving '$Name'. Check dependency-map.json."
    }
    $visiting.Add($Name) | Out-Null

    if ($forward.ContainsKey($Name)) {
        foreach ($dep in $forward[$Name]) {
            Resolve-Deps -Name $dep
        }
    } else {
        Write-Warning "Collection '$Name' is not listed in dependency-map.json - treating it as having no dependencies. Run scripts/sync-dependency-map.ps1 to register it properly."
    }

    $visiting.Remove($Name) | Out-Null
    if (-not $order.Contains($Name)) {
        $order.Add($Name)
    }
}

foreach ($name in $impacted) {
    Resolve-Deps -Name $name
}

Write-Host "Execution order (upstream deps first, changed + downstream dependents included): $($order -join ' -> ')"
$order | ConvertTo-Json | Set-Content -Path "execution-order.json"

$joined = $order -join ','
if ($env:GITHUB_OUTPUT) {
    "execution_order=$joined" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
