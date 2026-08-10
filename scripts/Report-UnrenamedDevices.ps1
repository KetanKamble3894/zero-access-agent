<#
.SYNOPSIS
    Read-only detector for Windows devices still on the default 'DESKTOP-' name in Intune,
    with an emailed HTML summary and the team's handling rules.

.DESCRIPTION
    A device that enrols and keeps its out-of-the-box 'DESKTOP-XXXXX' name usually means the
    corporate naming step (Autopilot rename to a standard convention) never completed. This
    runbook finds those stragglers and emails a table to the support queue so they can be
    followed up.

    It is READ-ONLY against Microsoft Graph: it GETs managed devices and their details, then
    sends an email report. It does NOT rename or wipe anything — the rename / reprovision steps
    are a documented human process described in the email body, not actions this script takes.

    Scope required: DeviceManagementManagedDevices.Read.All

    NOTE: All names, addresses and the mail server below are SYNTHETIC examples (@contoso.com).
    Replace CONFIG with your own values. Everything here is reproduced in a personal lab.
#>

# =====================================================================================
#  CONFIGURE ME  ->  set these to your own values, then run.
# =====================================================================================
$NamePrefix   = "DESKTOP-"                       # the default-name prefix to hunt for
$RenamePrefix = "<your-prefix>"                  # e.g. corporate prefix used for renamed devices
$SmtpServer   = "smtp.contoso.com"
$SmtpPort     = 25
$MailFrom     = "servicealerts@contoso.com"
$MailTo       = @("itservicedesk@contoso.com")
$SupportQueue = "your EUC Support queue"         # where to route follow-up
# =====================================================================================

$ProgressPreference = 'SilentlyContinue'
$VerbosePreference  = 'Continue'
Write-Verbose "Script started at $(Get-Date)"

# ---- Paged Microsoft Graph GET ----
function Invoke-MyGraphGetRequest {
    param([string]$URL)
    $AllResults = @()
    try {
        do {
            $WebRequest   = Invoke-WebRequest -Uri $URL -Method GET -Headers $script:Headers -UseBasicParsing
            $ResponseData = ($WebRequest.Content | ConvertFrom-Json)
            $AllResults  += $ResponseData.value
            $URL          = $ResponseData.'@odata.nextLink'
        } while ($URL)
        return $AllResults
    }
    catch { Write-Error "Failed to fetch data from ${URL}: $_"; return $null }
}

# ---- Per-device detail via $select (accurate fields) ----
function Get-DeviceById {
    param([Parameter(Mandatory)][string]$DeviceId)
    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$DeviceId`?`$select=id,deviceName,serialNumber,enrollmentProfileName,userPrincipalName,manufacturer,model,operatingSystem,lastSyncDateTime"
    try { return Invoke-RestMethod -Uri $uri -Headers $script:Headers -Method Get }
    catch { Write-Warning "Failed to get device details for ID ${DeviceId}: $_"; return $null }
}

# ---- Authenticate with the Automation Account Managed Identity ----
$miUrl     = $env:IDENTITY_ENDPOINT
$miHeaders = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$miHeaders.Add("X-IDENTITY-HEADER", $env:IDENTITY_HEADER)
$miHeaders.Add("Metadata", "True")
$miBody    = @{ resource = 'https://graph.microsoft.com/' }
$accessToken   = (Invoke-RestMethod -Uri $miUrl -Method 'POST' -Headers $miHeaders -ContentType 'application/x-www-form-urlencoded' -Body $miBody).access_token
$script:Headers = @{ 'Authorization' = "Bearer $accessToken" }
Write-Verbose "Access token obtained."

# ---- Find devices still on the default name ----
$DeviceQuery = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=startswith(deviceName,'$NamePrefix')&`$select=id"
$devicesBasicList = Invoke-MyGraphGetRequest -URL $DeviceQuery
if (-not $devicesBasicList -or $devicesBasicList.Count -eq 0) {
    Write-Output "No devices with name starting '$NamePrefix' found."; return
}
Write-Verbose "Found $($devicesBasicList.Count) devices matching filter."

# ---- Enrich each with detail ----
$devicesDetailed = @()
foreach ($deviceBasic in $devicesBasicList) {
    $deviceDetail = Get-DeviceById -DeviceId $deviceBasic.id
    if ($deviceDetail) { $devicesDetailed += $deviceDetail }
    else { Write-Warning "Skipping device id $($deviceBasic.id) due to retrieval failure." }
}
if ($devicesDetailed.Count -eq 0) { Write-Output "No detailed device information retrieved."; return }

# ---- Log the table to output too, so a read-only run can be inspected before wiring the mailer ----
$devicesDetailed |
    Format-Table deviceName, serialNumber, enrollmentProfileName, userPrincipalName, model, lastSyncDateTime -AutoSize |
    Out-String | Write-Output

# ---- Compose HTML rows ----
$deviceRows = ""
foreach ($dev in $devicesDetailed) {
    $enc = { param($v) [System.Net.WebUtility]::HtmlEncode($v) }   # works on PS 5.1 and 7 (System.Web isn't loaded on PS7)
    $deviceRows += "<tr>" +
        "<td>$(& $enc $dev.deviceName)</td>" +
        "<td>$(& $enc $dev.serialNumber)</td>" +
        "<td>$(& $enc $dev.enrollmentProfileName)</td>" +
        "<td>$(& $enc $dev.userPrincipalName)</td>" +
        "<td>$(& $enc $dev.manufacturer)</td>" +
        "<td>$(& $enc $dev.model)</td>" +
        "<td>$(& $enc $dev.operatingSystem)</td>" +
        "<td>$($dev.lastSyncDateTime)</td>" +
        "</tr>`n"
}

# ---- Email body (handling rules are a human process, not an action here) ----
$body = @"
<html><body>
<p>Hi Team,</p>
<p>The following devices with names starting '$NamePrefix' were detected in Intune:</p>
<table border='1' cellspacing='0' cellpadding='4' style='border-collapse:collapse;'>
  <tr style='background-color:#f2f2f2;'>
    <th>Device Name</th><th>Serial</th><th>Enrollment Profile</th><th>User</th>
    <th>Manufacturer</th><th>Model</th><th>Operating System</th><th>Last Sync</th>
  </tr>
$deviceRows
</table>
<p><b>Device handling rules:</b><br>
- If the name starts with '$NamePrefix' and the enrollment profile is present, rename to
  ${RenamePrefix}-&lt;SerialNo&gt; without a forced reboot (the rename applies on next reboot);
  follow up after a few days to confirm.<br>
- If the enrollment profile is missing, the device is not Autopilot-provisioned. That is
  normal for Hybrid Azure AD Join, GPO/bulk enrollment, or manual Entra join &mdash; investigate
  before any reprovision; do not assume a wipe.<br>
Please route this case to $SupportQueue.<br><br>
Best regards,<br>EUC Team</p>
</body></html>
"@

# ---- Send only if devices were found ----
$subject = "Intune '$NamePrefix' devices detected - $(Get-Date -Format yyyy-MM-dd)"

# NOTE: Send-MailMessage over port 25 does NOT work from the Azure Automation sandbox
# (no outbound 25, and Exchange Online requires authenticated submission). For production,
# send via Microsoft Graph instead — grant the Mail.Send app role to this same Managed
# Identity and POST to sendMail (the $script:Headers bearer token already works):
#
#   $mail = @{ message = @{
#       subject      = $subject
#       body         = @{ contentType = 'HTML'; content = $body }
#       toRecipients = @($MailTo | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
#   } }
#   Invoke-RestMethod -Method POST -Headers $script:Headers -ContentType 'application/json' `
#       -Uri "https://graph.microsoft.com/v1.0/users/$MailFrom/sendMail" `
#       -Body ($mail | ConvertTo-Json -Depth 6)
#
# Application Mail.Send lets the identity send as ANY mailbox — constrain it to one sender with an
# Exchange ApplicationAccessPolicy (New-ApplicationAccessPolicy) so it can't send tenant-wide.
# The Send-MailMessage call below is kept only for on-prem / authenticated-relay setups.
try {
    Send-MailMessage -SmtpServer $SmtpServer -Port $SmtpPort -From $MailFrom -To $MailTo -Subject $subject -Body $body -BodyAsHtml
    Write-Verbose "Email sent."
}
catch { Write-Warning "Failed to send email: $_" }

Write-Verbose "Script completed at $(Get-Date)"
