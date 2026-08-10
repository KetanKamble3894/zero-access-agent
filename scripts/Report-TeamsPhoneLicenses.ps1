<#
.SYNOPSIS
    Read-only Teams Phone (Voice) license-usage report — who holds a Teams Phone license,
    whether they have a number, and whether they actually use it — with a reclaim risk tier
    per user. Exports a CSV to Blob for Power BI.

.DESCRIPTION
    A Teams Phone license on a disabled account, a guest, a never-signed-in user, or someone
    with no calling activity in 90 days is spend with no return. This runbook joins license
    assignment, sign-in activity, Teams device/activity usage (D90), the directory phone number
    and the user's manager into one row per licensed user, and tags each with an observational
    risk tier so Voice Services / a Service Manager can decide what to reclaim.

    READ-ONLY against Microsoft Graph (GET users, subscribedSkus, usage reports; a $batch POST
    that only *reads* managers). It writes a CSV to Blob — the snapshot the Power BI report reads.
    It changes nothing in the tenant.

    Scopes: User.Read.All, Organization.Read.All, AuditLog.Read.All (for signInActivity),
            Reports.Read.All  +  Storage Blob Data Contributor (Blob write; scope to the container).

    NOTE: CONFIG values below are SYNTHETIC examples. Replace with your own. The Teams Phone
    SKU GUIDs are public Microsoft product identifiers — confirm your tenant's set with the
    subscribedSkus one-liner in the comment. Everything here is reproduced in a personal lab.
#>

# ---------- Step 1 - Initialize Variables ----------
$ResourceGroup  = "<your-resource-group>"          # <- your resource group
$StorageAccount = "<your-storage-account>"         # <- your storage account (lowercase, <=24 chars)
$Container      = "<your-container>"
$ExportLocation = "$env:TEMP"
$ProgressPreference = 'SilentlyContinue'
$VerbosePreference  = 'Continue'

$ReportFileName  = "TeamsVoiceLicenseReport.csv"
$TopWithSignIn   = 120   # Graph caps page size at 120 when signInActivity is in $select (400s above it)

# Teams Phone SKU IDs (public Microsoft product GUIDs — the same across tenants).
# Discover the exact set you own:
#   Invoke-RestMethod "https://graph.microsoft.com/v1.0/subscribedSkus" `
#       -Headers @{'Authorization'="Bearer $accessToken"} |
#       Select -Expand value | Where skuPartNumber -like "*MCOPSTN*" |
#       Select skuPartNumber, skuId
$PhoneSkus = @(
    [guid]"e43b5b99-8dfb-405f-9987-dc307f34bcbd"  # MCOEV        - Teams Phone Standard
    [guid]"5e277f11-3b64-4d34-b6d0-0a8a8e1d4e7c"  # MCOEV_TEAMS  - Teams Phone + Calling Plan bundle
    [guid]"b1511558-69ae-4e3a-89e4-a1e99a559cda"  # MCOEV_SHARED - Teams Shared Devices
    [guid]"f4d50207-d716-4d38-9d31-a632baa4e7db"  # M365_BUSINESS_VOICE
    [guid]"11dee6af-eca8-419f-8061-6864517c1875"  # MCOPSTN Domestic Calling Plan (example)
    # Add your tenant's remaining MCOPSTN* GUIDs, confirmed from subscribedSkus
)

# =====================================================================
# HELPER FUNCTIONS
# =====================================================================

# ---------- Helper: Write CSV bytes safely (PS 5.1 / 7.x / SMA) -----
# Untyped $Response param — the SMA runbook sandbox uses a different
# concrete type than the console; a strict type constraint throws
# "cannot convert" before the body runs. Also strips the UTF-8 BOM
# (EF BB BF) Graph report endpoints emit — without it, Import-Csv
# prefixes the first column header with "???".
Function Save-CsvBytes {
    Param([Parameter(Mandatory)]$Response,[Parameter(Mandatory)][string]$Path)
    if ($Response.RawContentStream -and $Response.RawContentStream.Length -gt 0) {
        $bytes = $Response.RawContentStream.ToArray()
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $bytes = $bytes[3..($bytes.Length - 1)]
        }
        [System.IO.File]::WriteAllBytes($Path, $bytes); return
    }
    if ($Response.Content -is [string] -and $Response.Content.Length -gt 0) {
        [System.IO.File]::WriteAllText($Path, $Response.Content.TrimStart([char]0xFEFF), [System.Text.Encoding]::UTF8); return
    }
    if ($Response.Content -is [byte[]]) {
        $bytes = $Response.Content
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $bytes = $bytes[3..($bytes.Length - 1)]
        }
        [System.IO.File]::WriteAllBytes($Path, $bytes); return
    }
    Write-Warning "Save-CsvBytes: could not extract content for: $Path"
}

# ---------- Helper: Graph GET with pagination + 429 retry ------------
Function Invoke-MyGraphGetRequest {
    Param([Parameter(Mandatory)][string]$URL,[switch]$AdvancedQuery,[int]$MaxRetries = 5)
    $ReqHeaders = $script:Headers.Clone()
    if ($AdvancedQuery) { $ReqHeaders['ConsistencyLevel'] = 'eventual' }
    $AllResults = @(); $RetryCount = 0
    try {
        do {
            $Success = $false
            while (-not $Success) {
                try { $Resp = Invoke-WebRequest -Uri $URL -Method GET -Headers $ReqHeaders -UseBasicParsing -ErrorAction Stop; $Success = $true }
                catch {
                    $Code = $null; try { $Code = $_.Exception.Response.StatusCode.value__ } catch {}
                    if ($Code -eq 429) {
                        $RetryCount++
                        if ($RetryCount -gt $MaxRetries) { Write-Error "Max retries on 429 for: $URL"; return $null }
                        $Wait = $null; try { $Wait = [int]$_.Exception.Response.Headers['Retry-After'] } catch {}
                        if (-not $Wait) { $Wait = [math]::Pow(2, $RetryCount) * 5 }
                        Write-Verbose "429 - waiting ${Wait}s (retry $RetryCount/$MaxRetries)"; Start-Sleep -Seconds $Wait
                    } else { throw }
                }
            }
            $Data = $Resp.Content | ConvertFrom-Json
            if ($Data.value) { $AllResults += $Data.value } else { return $Data }
            $URL = $Data.'@odata.nextLink'
        } while ($URL)
        return $AllResults
    } catch { Write-Error "Graph GET failed for ${URL}: $_"; return $null }
}

# ---------- Helper: Manager lookup via $batch (20 per call) ----------
# Avoids hundreds of individual /users/{id}/manager calls; Graph JSON batch
# accepts up to 20 requests per call. Returns userId(lower) -> managerName.
Function Get-ManagersBatch {
    Param([array]$Users)
    $ManagerMap = @{}; $BatchSize = 20; $Total = $Users.Count
    for ($i = 0; $i -lt $Total; $i += $BatchSize) {
        $Slice = $Users[$i..([math]::Min($i + $BatchSize - 1, $Total - 1))]
        $Requests = @()
        foreach ($u in $Slice) {
            if ([string]::IsNullOrEmpty($u.id)) { continue }
            $Requests += @{ id = $u.id; method = "GET"; url = "/users/$($u.id)/manager?`$select=displayName,userPrincipalName" }
        }
        if ($Requests.Count -eq 0) { continue }
        $BatchBody = @{ requests = $Requests } | ConvertTo-Json -Depth 5
        $RetryCount = 0; $Success = $false; $BatchResp = $null
        while (-not $Success -and $RetryCount -le 5) {
            try {
                $BatchResp = Invoke-WebRequest -Uri "https://graph.microsoft.com/v1.0/`$batch" -Method POST -Headers $script:Headers -Body $BatchBody -UseBasicParsing -ErrorAction Stop
                $Success = $true
            } catch {
                $Code = $null; try { $Code = $_.Exception.Response.StatusCode.value__ } catch {}
                if ($Code -eq 429) { $RetryCount++; $Wait = [math]::Pow(2, $RetryCount) * 5; Write-Verbose "Batch 429 - waiting ${Wait}s"; Start-Sleep -Seconds $Wait }
                else { Write-Warning "Batch manager request failed: $_"; $Success = $true }
            }
        }
        if (-not $BatchResp) { continue }
        $BatchData = $BatchResp.Content | ConvertFrom-Json
        foreach ($r in $BatchData.responses) {
            if ($r.status -eq 200 -and $r.body.displayName) { $ManagerMap[$r.id.ToLower()] = $r.body.displayName }
        }
        Start-Sleep -Milliseconds 300   # stay under per-app rate limits
    }
    return $ManagerMap
}

# =====================================================================
# MAIN
# =====================================================================

# ---------- Step 2 - Authenticate via Managed Identity ----------
$miUrl  = $env:IDENTITY_ENDPOINT
$miHdrs = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$miHdrs.Add("X-IDENTITY-HEADER", $env:IDENTITY_HEADER); $miHdrs.Add("Metadata", "True")
$accessToken = (Invoke-RestMethod $miUrl -Method POST -Headers $miHdrs -ContentType 'application/x-www-form-urlencoded' -Body @{ resource = 'https://graph.microsoft.com/' }).access_token
if ([string]::IsNullOrEmpty($accessToken)) { throw "Failed to acquire access token." }
$script:Headers = @{ 'Authorization' = "Bearer $accessToken"; 'Content-Type' = 'application/json' }

# ---------- Step 3 - SKU metadata (GUID -> skuPartNumber) ----------
$AllSkus = Invoke-MyGraphGetRequest -URL "https://graph.microsoft.com/v1.0/subscribedSkus"
if (-not $AllSkus) { throw "Unable to retrieve subscribedSkus." }
$SkuHash = @{}
foreach ($s in $AllSkus) { if ($s.skuId -and $s.skuPartNumber) { $SkuHash[[guid]$s.skuId] = $s.skuPartNumber } }

# ---------- Step 4 - Licensed users (single-pass, all properties) ----------
# assignedLicenses/any() filter — no ConsistencyLevel needed. NOTE: businessPhones[0] is the
# DIRECTORY phone attribute, NOT the authoritative Teams line assignment (that lives in Teams —
# Get-CsPhoneNumberAssignment). Treat it as a hint, not proof of provisioning. signInActivity needs P1/P2.
$AllLicensedUsers = @()
foreach ($SkuId in $PhoneSkus) {
    $Uri = "https://graph.microsoft.com/v1.0/users?`$filter=assignedLicenses/any(x:x/skuId eq $SkuId)" +
        "&`$select=id,userPrincipalName,displayName,jobTitle,department,city,country,officeLocation,usageLocation," +
        "businessPhones,mobilePhone,accountEnabled,employeeType,userType,createdDateTime,signInActivity,assignedLicenses&`$top=$TopWithSignIn"
    $UsersForSku = Invoke-MyGraphGetRequest -URL $Uri
    if ($UsersForSku) { $AllLicensedUsers += $UsersForSku }
}

# Deduplicate (a user may hold multiple Phone SKUs); guard null UPN (service accounts)
$SeenUPNs = @{}; $UserDetails = @()
foreach ($u in $AllLicensedUsers) {
    if ([string]::IsNullOrEmpty($u.userPrincipalName)) { continue }
    $key = $u.userPrincipalName.ToLower()
    if (-not $SeenUPNs.ContainsKey($key)) { $SeenUPNs[$key] = $true; $UserDetails += $u }
}
$UserCount = $UserDetails.Count
if ($UserCount -eq 0) { Write-Warning "No users found. Verify SKU GUIDs and permissions."; return }
Write-Verbose "Unique licensed users: $UserCount"

# ---------- Step 5 - Manager lookup (batch) ----------
$ManagerMap = Get-ManagersBatch -Users $UserDetails

# ---------- Step 6 - Teams device usage (D90) ----------
$DeviceUsagePath = Join-Path $ExportLocation "TeamsDeviceUsageTemp.csv"; $DeviceUsageHash = @{}
try {
    $DevResp = Invoke-WebRequest -Uri "https://graph.microsoft.com/v1.0/reports/getTeamsDeviceUsageUserDetail(period='D90')" -Method GET -Headers $script:Headers -UseBasicParsing -ErrorAction Stop
    Save-CsvBytes -Response $DevResp -Path $DeviceUsagePath
    if (Test-Path $DeviceUsagePath) {
        Import-Csv $DeviceUsagePath | ForEach-Object {
            $upn = ($_.'User Principal Name').Trim()   # .Trim() critical: Graph CSVs embed trailing spaces
            if (-not [string]::IsNullOrEmpty($upn)) { $DeviceUsageHash[$upn.ToLower()] = $_ }
        }
        Remove-Item $DeviceUsagePath -Force -ErrorAction SilentlyContinue
    }
} catch { Write-Warning "Teams device usage report unavailable: $_" }

# ---------- Step 7 - Teams activity / call count (D90) ----------
$ActivityPath = Join-Path $ExportLocation "TeamsActivityTemp.csv"; $TeamsCallHash = @{}
try {
    $ActResp = Invoke-WebRequest -Uri "https://graph.microsoft.com/v1.0/reports/getTeamsUserActivityUserDetail(period='D90')" -Method GET -Headers $script:Headers -UseBasicParsing -ErrorAction Stop
    Save-CsvBytes -Response $ActResp -Path $ActivityPath
    if (Test-Path $ActivityPath) {
        Import-Csv $ActivityPath | ForEach-Object {
            $upn = ($_.'User Principal Name').Trim()
            if (-not [string]::IsNullOrEmpty($upn)) {
                $callCount = 0; [int]::TryParse($_.'Call Count', [ref]$callCount) | Out-Null
                $TeamsCallHash[$upn.ToLower()] = $callCount
            }
        }
        Remove-Item $ActivityPath -Force -ErrorAction SilentlyContinue
    }
} catch { Write-Warning "Teams user activity report unavailable: $_" }

# ---------- Step 8 - Build report with observational risk tiers ----------
$FinalReport = foreach ($User in $UserDetails) {
    $UPNLower    = $User.userPrincipalName.ToLower()
    $LastSignIn  = $User.signInActivity.lastSignInDateTime
    $SignInEmpty = [string]::IsNullOrEmpty($LastSignIn)
    $DaysSince   = if ($SignInEmpty) { "Never" } else { [math]::Round((New-TimeSpan -Start ([datetime]$LastSignIn) -End (Get-Date)).TotalDays) }

    $UsageRecord    = $DeviceUsageHash[$UPNLower]
    $LastDeviceDate = if ($UsageRecord) { $UsageRecord.'Last Activity Date'.Trim() } else { "None" }
    $TeamsCallCount = if ($TeamsCallHash.ContainsKey($UPNLower)) { $TeamsCallHash[$UPNLower] } else { 0 }

    $PhoneNumber = ""
    if ($User.businessPhones -and $User.businessPhones.Count -gt 0) { $PhoneNumber = $User.businessPhones[0] }

    $UserPhoneLicenses = @()
    if ($User.assignedLicenses) { $UserPhoneLicenses = $User.assignedLicenses | Where-Object { [guid]$_.skuId -in $PhoneSkus } }
    $AllPhoneSkuNames = if ($UserPhoneLicenses) {
        ($UserPhoneLicenses | ForEach-Object { $id = [guid]$_.skuId; if ($SkuHash.ContainsKey($id)) { $SkuHash[$id] } else { $id.ToString() } }) -join ' + '
    } else { "Unknown" }
    $PrimarySkuName = "Unknown"
    if ($UserPhoneLicenses) { $firstId = [guid]$UserPhoneLicenses[0].skuId; if ($SkuHash.ContainsKey($firstId)) { $PrimarySkuName = $SkuHash[$firstId] } }

    # Risk tiers are OBSERVATIONAL — no action prescribed. Ordered by priority
    # so the most severe tier wins when several conditions are true at once.
    $UsageRisk = ""; $RiskReason = ""
    if     ($User.accountEnabled -eq $false) { $UsageRisk = "Tier 1 - Disabled Account"; $RiskReason = "Account disabled but a Teams Phone license is still assigned" }
    elseif ($SignInEmpty)                    { $UsageRisk = "Tier 2 - Never Signed In";  $RiskReason = "No sign-in activity on record" }
    elseif ([int]$DaysSince -gt 90)          { $UsageRisk = "Tier 3 - Inactive >90 Days"; $RiskReason = "Last sign-in was $DaysSince days ago" }
    elseif (-not $UsageRecord)               { $UsageRisk = "Tier 4 - No Teams Activity"; $RiskReason = "Signed in recently but no Teams device activity in 90 days" }
    else                                     { $UsageRisk = "Tier 5 - Active";            $RiskReason = "Active sign-in and Teams activity in 90 days" }

    $ManagerName = ""
    if ($User.id -and $ManagerMap.ContainsKey($User.id.ToLower())) { $ManagerName = $ManagerMap[$User.id.ToLower()] }
    $AcctEnabled = if ($User.accountEnabled -eq $false) { "Disabled" } else { "Enabled" }

    [PSCustomObject]@{
        UserPrincipalName      = $User.userPrincipalName
        DisplayName            = $User.displayName
        JobTitle               = if ($User.jobTitle){$User.jobTitle}else{"Not Set"}
        Department             = if ($User.department){$User.department}else{"Not Set"}
        Manager                = if ($ManagerName){$ManagerName}else{"Not Set"}
        City                   = if ($User.city){$User.city}else{"Not Set"}
        Country                = if ($User.country){$User.country}else{"Not Set"}
        OfficeLocation         = if ($User.officeLocation){$User.officeLocation}else{"Not Set"}
        UsageLocation          = if ($User.usageLocation){$User.usageLocation}else{"Not Set"}
        AccountStatus          = $AcctEnabled
        EmployeeType           = if ($User.employeeType){$User.employeeType}else{"Not Set"}
        AccountCreated         = $User.createdDateTime
        PrimaryLicenseSku      = $PrimarySkuName
        AllPhoneSkus           = $AllPhoneSkuNames
        DirectoryPhoneNumber   = $PhoneNumber
        LastSignInDateTime     = if ($SignInEmpty){"Never"}else{$LastSignIn}
        DaysSinceLastSignIn    = $DaysSince
        LastTeamsActivityDate  = $LastDeviceDate
        TeamsCallCount_D90     = $TeamsCallCount
        UsageRisk              = $UsageRisk
        RiskReason             = $RiskReason
    }
}

# ---------- Step 9 - Summary to verbose log ----------
$FinalReport | Group-Object UsageRisk | Sort-Object Name | ForEach-Object { Write-Verbose "$($_.Name) : $($_.Count) users" }
Write-Verbose "Total users in report: $($FinalReport.Count)"

# ---------- Step 10 - Export & upload to Blob ----------
if (-not (Test-Path $ExportLocation)) { New-Item -ItemType Directory -Path $ExportLocation -Force | Out-Null }
$OutputFilePath = Join-Path $ExportLocation $ReportFileName
$FinalReport | Export-Csv -Path $OutputFilePath -NoTypeInformation -Force -Encoding UTF8

$StorageContext = (Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $StorageAccount).Context
Set-AzStorageBlobContent -File $OutputFilePath -Container $Container -Blob $ReportFileName -Context $StorageContext -Force | Out-Null
Write-Verbose "Done. Report uploaded: $ReportFileName"
