<#
.SYNOPSIS
    Sends a pass/fail notification summarizing which collection(s) failed and
    why, using reports/summary.json when available. Supports Microsoft Teams
    (incoming webhook) and/or email (SMTP) - use whichever your org runs.
    Both are optional and independently configured via environment variables;
    if neither is configured, the notification is printed to the job log so
    the pipeline never fails just because notifications aren't set up yet.

.NOTES
    Teams:  set NOTIFY_WEBHOOK_URL to a Teams "Incoming Webhook" connector URL.
    Email:  set SMTP_SERVER, SMTP_FROM, SMTP_TO (comma separated for multiple
            recipients). Optional: SMTP_PORT (default 25), SMTP_USER,
            SMTP_PASSWORD, SMTP_USE_SSL ("true"/"false", default "false") -
            typical for an internal relay reachable from the self-hosted runner.
            When email is configured, the HTML/JUnit reports for this run are
            attached directly, which is the fastest path to root-causing a
            failure without leaving the inbox.
#>
param(
    [string]$WebhookUrl = $env:NOTIFY_WEBHOOK_URL,
    [ValidateSet("PASSED", "FAILED")][string]$Status = "FAILED",
    [string]$Message = "",
    [string]$SummaryPath = "reports/summary.json",
    [string]$ReportsDir = "reports",
    [string]$RunUrl = "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
)
$ErrorActionPreference = "Continue"

# ---------- Build shared details from reports/summary.json ----------
$resultRows = @()
if (Test-Path $SummaryPath) {
    $summary = Get-Content $SummaryPath -Raw | ConvertFrom-Json
    foreach ($r in $summary.results) {
        $resultRows += [PSCustomObject]@{
            collection = $r.collection
            status     = $r.status
            error      = $r.error
        }
    }
}

$plainDetails = ($resultRows | ForEach-Object {
    $line = "- $($_.collection): $($_.status)"
    if ($_.error) { $line += "`n    cause: $($_.error)" }
    $line
}) -join "`n"

$reportFiles = @()
if (Test-Path $ReportsDir) {
    $reportFiles = Get-ChildItem -Path $ReportsDir -Include "*.html", "*junit.xml" -Recurse |
        Select-Object -ExpandProperty FullName
}

$icon = if ($Status -eq "PASSED") { "PASSED" } else { "FAILED" }
$fullText = "$icon - $Message"
if ($plainDetails) { $fullText += "`n`nDetails:`n$plainDetails" }
if ($env:GITHUB_RUN_ID) { $fullText += "`n`nFull run & reports: $RunUrl" }

$sentAny = $false

# ---------- Microsoft Teams (incoming webhook) ----------
if ($WebhookUrl) {
    $themeColor = if ($Status -eq "PASSED") { "2EB886" } else { "E01E5A" }

    $facts = @()
    foreach ($r in $resultRows) {
        $factValue = $r.status
        if ($r.error) { $factValue += " - $($r.error)" }
        $facts += @{ name = $r.collection; value = $factValue }
    }

    $card = @{
        "@type"    = "MessageCard"
        "@context" = "http://schema.org/extensions"
        themeColor = $themeColor
        summary    = "API Validation $Status"
        title      = "API Validation $Status"
        text       = $Message
        sections   = @(
            @{
                facts = $facts
            }
        )
        potentialAction = @(
            @{
                "@type" = "OpenUri"
                name    = "View full run & reports"
                targets = @(@{ os = "default"; uri = $RunUrl })
            }
        )
    }

    # Fall back to a plain-text payload if this isn't a Teams-style connector
    # (e.g. Slack incoming webhooks only understand { "text": "..." }).
    if ($WebhookUrl -match "hooks\.slack\.com") {
        $payload = @{ text = $fullText } | ConvertTo-Json -Depth 6
    } else {
        $payload = $card | ConvertTo-Json -Depth 8
    }

    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $payload -ContentType "application/json" | Out-Null
        Write-Host "Teams/Slack notification sent."
        $sentAny = $true
    } catch {
        Write-Warning "Failed to send webhook notification: $($_.Exception.Message)"
    }
}

# ---------- Email (SMTP), with reports attached ----------
if ($env:SMTP_SERVER -and $env:SMTP_FROM -and $env:SMTP_TO) {
    try {
        $smtpPort = if ($env:SMTP_PORT) { [int]$env:SMTP_PORT } else { 25 }
        $useSsl   = $env:SMTP_USE_SSL -eq "true"

        $mail = New-Object System.Net.Mail.MailMessage
        $mail.From = $env:SMTP_FROM
        foreach ($addr in ($env:SMTP_TO -split ",")) {
            $mail.To.Add($addr.Trim())
        }
        $mail.Subject = "[API Validation $Status] $Message"
        $mail.Body = $fullText
        $mail.IsBodyHtml = $false

        foreach ($f in $reportFiles) {
            if (Test-Path $f) {
                $mail.Attachments.Add((New-Object System.Net.Mail.Attachment($f)))
            }
        }

        $smtp = New-Object System.Net.Mail.SmtpClient($env:SMTP_SERVER, $smtpPort)
        $smtp.EnableSsl = $useSsl
        if ($env:SMTP_USER -and $env:SMTP_PASSWORD) {
            $smtp.Credentials = New-Object System.Net.NetworkCredential($env:SMTP_USER, $env:SMTP_PASSWORD)
        }
        $smtp.Send($mail)
        $mail.Dispose()

        Write-Host "Email notification sent to $($env:SMTP_TO) with $($reportFiles.Count) report(s) attached."
        $sentAny = $true
    } catch {
        Write-Warning "Failed to send email notification: $($_.Exception.Message)"
    }
}

if (-not $sentAny) {
    Write-Host "No NOTIFY_WEBHOOK_URL or SMTP_* variables configured - printing notification instead:"
    Write-Host $fullText
    if ($reportFiles.Count -gt 0) {
        Write-Host "`nReport files for this run:"
        $reportFiles | ForEach-Object { Write-Host " - $_" }
    }
}
