<#
    Report-MaaApprovals.ps1  —  READ-ONLY Intune Multi Admin Approval (MAA) reporter.

    Runs in Azure Automation as a system-assigned Managed Identity that holds ONLY
    DeviceManagementConfiguration.Read.All. It:
      1. Lists every MAA operationApprovalRequest over Microsoft Graph (beta) — GET only.
      2. Emails the service desk about NEW pending requests (SMTP relay; no tenant write).
      3. Merges live requests into a durable history CSV that outlives Intune's retention.
      4. Writes a summary-stats CSV for Power BI.

    It holds NO permission to approve, reject, or wipe anything. All names/addresses are
    synthetic (@contoso.com). Uses a Graph BETA endpoint — verify in your own tenant.
#>

# --- Config (all synthetic) --------------------------------------------------
$ResourceGroup         = "rg-intune-reporting"
$StorageAccount        = "stintunereports"
$Container             = "maa-reports"
$ExportLocation        = "$env:TEMP"
$ProgressPreference    = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
$script:GraphBase      = 'https://graph.microsoft.com/beta'
$script:RunStart       = Get-Date
$SnapshotDate          = (Get-Date).ToString('yyyy-MM-dd')
$HistoryBlobName       = "MAA_Requests_History.csv"
$WatermarkVariable     = 'MAA-LastCheck'            # a String Automation variable
# Alerting (relay only — not a Graph/tenant write)
$SmtpServer            = "smtp.contoso.com"
$SmtpPort              = 25
$MailFrom              = "intune-maa@contoso.com"
$MailTo                = @('servicedesk@contoso.com')

# --- Auth: Managed Identity token (no stored secret) -------------------------
function Get-ManagedIdentityToken {
    param([string]$Resource = 'https://graph.microsoft.com/')
    $url = $env:IDENTITY_ENDPOINT
    if (-not $url) { throw "IDENTITY_ENDPOINT not set. Enable the system-assigned Managed Identity." }
    $headers  = @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; 'Metadata' = 'True' }
    $response = Invoke-RestMethod -Uri $url -Method POST -Headers $headers `
        -ContentType 'application/x-www-form-urlencoded' -Body @{ resource = $Resource }
    if (-not $response.access_token) { throw "Managed Identity returned an empty token." }
    return $response.access_token
}
function Initialize-GraphAuth {
    $script:Headers     = @{ Authorization = "Bearer $(Get-ManagedIdentityToken)"; 'Content-Type' = 'application/json' }
    $script:TokenExpiry = (Get-Date).AddMinutes(50)
}
function Get-GraphHeaders {
    if ((Get-Date) -ge $script:TokenExpiry) { Initialize-GraphAuth }
    return $script:Headers
}
Initialize-GraphAuth

# --- Graph GET with retry + pagination (READ-ONLY) ---------------------------
function Invoke-GraphGet {
    param([Parameter(Mandatory)][string]$Uri)
    $all = [System.Collections.Generic.List[object]]::new()
    $next = $Uri; $page = 0
    do {
        $retry = 0; $resp = $null
        while ($null -eq $resp) {
            try {
                if ($page -gt 0) { Start-Sleep -Milliseconds 200 }
                $resp = Invoke-RestMethod -Uri $next -Method GET -Headers (Get-GraphHeaders)
                if ($null -eq $resp) { $resp = @{} }
            }
            catch {
                $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
                if ($code -eq 401 -and $retry -lt 5) { $retry++; Initialize-GraphAuth; continue }
                if ($code -in 429,502,503,504 -and $retry -lt 5) {
                    $retry++; $wait = 30
                    try { $h = @($_.Exception.Response.Headers.GetValues('Retry-After'))[0]
                          $p = 0; if ($h -and [int]::TryParse($h,[ref]$p)) { $wait = [Math]::Min($p,300) } } catch { }
                    Write-Warning "HTTP $code - retry $retry/5 in ${wait}s."; Start-Sleep -Seconds $wait; continue
                }
                throw "Graph GET failed [$code] $next :: $($_.Exception.Message)"
            }
        }
        $page++
        if ($resp.PSObject.Properties['value']) { $resp.value | ForEach-Object { $all.Add($_) } } else { $all.Add($resp) }
        $next = if ($resp.PSObject.Properties['@odata.nextLink']) { $resp.'@odata.nextLink' } else { $null }
    } while ($next)
    return $all
}

# --- Helpers -----------------------------------------------------------------
function Get-ReqProp { param($R,[string[]]$Names)
    foreach ($n in $Names) { $p = $R.PSObject.Properties[$n]; if ($p -and "$($p.Value)" -ne "") { return $p.Value } }
    return $null
}
# NOTE: the user object exposes 'Upn' (capital U), not 'userPrincipalName'.
function Resolve-Identity { param($Set)
    if ($null -eq $Set) { return [pscustomobject]@{ Name=''; Upn='' } }
    if ($Set.PSObject.Properties['user'] -and $Set.user) {
        return [pscustomobject]@{ Name = "$($Set.user.displayName)"; Upn = "$(Get-ReqProp $Set.user @('Upn','userPrincipalName'))" }
    }
    if ($Set.PSObject.Properties['application'] -and $Set.application) {
        return [pscustomobject]@{ Name = "$($Set.application.displayName)"; Upn = "app:$($Set.application.id)" }
    }
    return [pscustomobject]@{ Name=''; Upn='' }
}
# Device details live in displayPayload (JSON) on device-action requests.
function Get-PayloadDevice { param($R)
    $out = [pscustomobject]@{ DeviceName=''; SerialNumber='' }
    $dp = Get-ReqProp $R @('displayPayload')
    if ($dp) { try { $f = @($dp | ConvertFrom-Json)[0]
        if ($f) { $out.DeviceName = "$($f.DeviceName)"; $out.SerialNumber = "$($f.SerialNumber)" } } catch { } }
    return $out
}

# --- Main --------------------------------------------------------------------
Connect-AzAccount -Identity | Out-Null
$Ctx = (Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $StorageAccount).Context

# Load prior history (merge base) so aged-out requests are preserved.
$historyPath = Join-Path $ExportLocation $HistoryBlobName
$history = @{}
try {
    Get-AzStorageBlobContent -Container $Container -Blob $HistoryBlobName -Destination $historyPath -Context $Ctx -Force | Out-Null
    foreach ($row in (Import-Csv $historyPath)) { $history[$row.RequestId] = $row }
} catch { Write-Warning "No existing history blob - starting fresh." }

# READ: every approval request, every status. Nothing here can approve or wipe.
$live = Invoke-GraphGet -Uri "$script:GraphBase/deviceManagement/operationApprovalRequests"

# ALERT: email the service desk about NEW pending requests (watermark dedupe).
try { $lastCheck = [datetime](Get-AutomationVariable -Name $WatermarkVariable) }
catch { $lastCheck = (Get-Date).ToUniversalTime().AddHours(-24) }
$runStartUtc = (Get-Date).ToUniversalTime()
$pendingNew = @($live | Where-Object {
    "$(Get-ReqProp $_ @('status'))" -eq 'needsApproval' -and
    [datetime]"$(Get-ReqProp $_ @('requestDateTime'))" -gt $lastCheck })

if ($pendingNew.Count -gt 0) {
    Add-Type -AssemblyName System.Web
    $rows = ""
    foreach ($req in $pendingNew) {
        $r = Resolve-Identity $req.requestor; $d = Get-PayloadDevice $req
        $op = "$(Get-ReqProp $req @('actionName'))"
        if (-not $op) { $op = "$((Get-ReqProp $req @('requiredOperationApprovalPolicyTypes')) -join ', ')" }
        $rows += "<tr><td>$([System.Web.HttpUtility]::HtmlEncode($op))</td>" +
                 "<td>$([System.Web.HttpUtility]::HtmlEncode($d.DeviceName))</td>" +
                 "<td>$([System.Web.HttpUtility]::HtmlEncode($r.Upn))</td>" +
                 "<td>$([System.Web.HttpUtility]::HtmlEncode("$(Get-ReqProp $req @('requestJustification'))"))</td>" +
                 "<td>$(Get-ReqProp $req @('requestDateTime'))</td><td>$($req.id)</td></tr>`n"
    }
    $body = @"
<html><body><p>Hi Team,</p>
<p>The following Intune <b>Multi Admin Approval</b> request(s) are <b>pending approval</b>.
Requests expire automatically if not actioned within the approval window.</p>
<table border='1' cellspacing='0' cellpadding='4' style='border-collapse:collapse;'>
<tr style='background:#f2f2f2;'><th>Operation</th><th>Device</th><th>Requestor</th>
<th>Justification</th><th>Submitted (UTC)</th><th>Request ID</th></tr>
$rows
</table>
<p>Approve/Reject in: Intune admin center &gt; Tenant administration &gt; Multi Admin Approval &gt; Received requests.
The requesting admin cannot approve their own request.<br><br>Best regards,<br>Endpoint Operations</p>
</body></html>
"@
    $subject = "ACTION REQUIRED: Intune wipe/retire approval pending ($($pendingNew.Count)) - $SnapshotDate"
    try {
        Send-MailMessage -SmtpServer $SmtpServer -Port $SmtpPort -From $MailFrom -To $MailTo `
            -Subject $subject -Body $body -BodyAsHtml
        Set-AutomationVariable -Name $WatermarkVariable -Value $runStartUtc.ToString('o')   # advance only on success
    } catch { Write-Warning "Alert send failed - watermark NOT advanced, will retry next run. $($_.Exception.Message)" }
} else {
    Set-AutomationVariable -Name $WatermarkVariable -Value $runStartUtc.ToString('o')
}

# MERGE: upsert live requests into history (aged-out rows preserved).
$nowUtc = $runStartUtc.ToString('o')
foreach ($req in $live) {
    $r = Resolve-Identity $req.requestor
    $a = Resolve-Identity (Get-ReqProp $req @('approver'))
    $d = Get-PayloadDevice $req
    $reqDt = "$(Get-ReqProp $req @('requestDateTime'))"
    $decDt = "$(Get-ReqProp $req @('lastModifiedDateTime'))"
    $status = "$(Get-ReqProp $req @('status'))"
    $ttd = ''
    if ($status -in 'approved','completed','rejected' -and $reqDt -and $decDt) {
        $x=[datetime]::MinValue; $y=[datetime]::MinValue
        if ([datetime]::TryParse($reqDt,[ref]$x) -and [datetime]::TryParse($decDt,[ref]$y) -and $y -gt $x) {
            $ttd = [math]::Round(($y-$x).TotalMinutes,0) }
    }
    $month=''; $m=[datetime]::MinValue; if ([datetime]::TryParse($reqDt,[ref]$m)) { $month = $m.ToString('yyyy-MM') }
    $firstSeen = if ($history.ContainsKey($req.id)) { $history[$req.id].FirstSeenUtc } else { $nowUtc }
    $history[$req.id] = [pscustomobject]@{
        RequestId=$req.id; Status=$status
        OperationType="$((Get-ReqProp $req @('requiredOperationApprovalPolicyTypes')) -join ', ')"
        DeviceName=$d.DeviceName; SerialNumber=$d.SerialNumber
        RequestorName=$r.Name; RequestorUPN=$r.Upn
        RequestJustification="$(Get-ReqProp $req @('requestJustification'))"
        ApproverName=$a.Name; ApproverUPN=$a.Upn
        ApprovalJustification="$(Get-ReqProp $req @('approvalJustification'))"
        RequestDateTime=$reqDt; RequestMonth=$month; DecisionDateTime=$decDt
        TimeToDecisionMinutes="$ttd"; ExpirationDateTime="$(Get-ReqProp $req @('expirationDateTime'))"
        FirstSeenUtc=$firstSeen; LastSeenUtc=$nowUtc; SnapshotDate=$SnapshotDate
    }
}
$allRows = @($history.Values | Sort-Object RequestDateTime -Descending)

# EXPORT: durable history CSV -> Blob (Power BI reads this).
$allRows | Export-Csv $historyPath -NoTypeInformation -Force -Encoding UTF8
Set-AzStorageBlobContent -File $historyPath -Container $Container -Blob $HistoryBlobName -Context $Ctx -Force | Out-Null

# SUMMARY STATS for Power BI: counts by status, approval rate, by approver/requestor/month, avg time-to-decision.
$stats = [System.Collections.Generic.List[object]]::new()
function Add-Stat { param($Cat,$Key,$Count) $stats.Add([pscustomobject]@{ Category=$Cat; Key=$Key; Count=$Count; SnapshotDate=$SnapshotDate }) }
$total = $allRows.Count
Add-Stat 'Total' 'AllRequests' $total
foreach ($g in ($allRows | Group-Object Status)) { Add-Stat 'RequestsByStatus' ($g.Name ?? 'Unknown') $g.Count }
$approved = @($allRows | Where-Object Status -in 'approved','completed')
if ($total -gt 0) { Add-Stat 'ApprovalRate' 'ApprovedPercent' ([math]::Round($approved.Count/$total*100,1)) }
foreach ($g in ($approved | Where-Object ApproverName | Group-Object ApproverName)) { Add-Stat 'RequestsByApprover' $g.Name $g.Count }
foreach ($g in ($allRows | Where-Object RequestMonth | Group-Object RequestMonth | Sort-Object Name)) { Add-Stat 'RequestsByMonth' $g.Name $g.Count }
$ttdVals = @($allRows | Where-Object { $_.TimeToDecisionMinutes -match '^\d+$' } | ForEach-Object { [int]$_.TimeToDecisionMinutes })
if ($ttdVals.Count) { Add-Stat 'TimeToDecision' 'AverageHours' ([math]::Round(($ttdVals | Measure-Object -Average).Average/60,1)) }

$statsPath = Join-Path $ExportLocation "MAA_Summary_Stats.csv"
$stats | Export-Csv $statsPath -NoTypeInformation -Force -Encoding UTF8
Set-AzStorageBlobContent -File $statsPath -Container $Container -Blob "MAA_Summary_Stats.csv" -Context $Ctx -Force | Out-Null

Write-Information ("MAA reporter done | live={0} newPending={1} historyTotal={2} stats={3}" -f `
    $live.Count, $pendingNew.Count, $allRows.Count, $stats.Count) -InformationAction Continue
