#requires -Version 7.0
<#
.SYNOPSIS
    Collect-DeviceHygiene.ps1 — device-hygiene / offboarding collector for the Zero-Access
    Pattern. Read-only, Managed-Identity, opinionated output (recommended actions).

.DESCRIPTION
    Finds the devices that need attention and explains why:
      - devices whose primary user's Entra account is DISABLED (offboarding left-behinds)
      - ORPHANED corporate devices (company-owned, no primary user)
    then enriches each with user profile/manager/licences, the Entra device object
    (enabled?, risk level), the account-disabled date (from audit logs), and — for Lenovo —
    the warranty fields another runbook wrote to Notes. It computes a RecommendedAction and
    an ActionOwner per row and writes a single CSV to agent-data/.

    Read-only throughout — every call is a GET. Nothing is written to the tenant. The
    "recommended action" is a suggestion for a human to act on, never an automated change.

.NOTES
    GENERIC / PARAMETERIZED: no resource group, storage account, or container is hardcoded.
    Run against a personal lab tenant only.

    BETA ENDPOINT: managed devices and $batch use /beta; users, devices, audit logs use
    /v1.0. Re-verify after Graph updates.

    Read-only Graph app roles on the Managed Identity:
      DeviceManagementManagedDevices.Read.All   (managed devices + Notes)
      User.Read.All, Directory.Read.All         (users, manager, licences, devices)
      Device.Read.All                            (Entra device objects: enabled, risk)
      AuditLog.Read.All                          (directoryAudits + signInActivity)
    Plus "Storage Blob Data Contributor" on the storage account (to write the CSV).

    MIT licensed. Microsoft, Intune, Entra, Microsoft Graph and Azure are trademarks of the
    Microsoft group of companies; Lenovo is a trademark of Lenovo. Independent content; not
    endorsed by Microsoft or Lenovo. Verify every endpoint and permission in your own lab
    tenant before relying on it.
#>

# ===========================================================================
#  CONFIGURE ME  ->  set these to your own values, then run.
#  These three lines are the only thing you MUST change.
# ===========================================================================
$ResourceGroup  = "<your-resource-group-name>"     # resource group that holds your storage account
$StorageAccount = "<your-storage-account-name>"    # storage account name (lowercase, globally unique)
$Container      = "<your-container-name>"           # blob container, e.g. "intune-report"

# -- optional settings (safe to leave as they are) --------------------------
$InactiveDays     = 90                  # a device not synced in this many days counts as "inactive"
$ExcludedPrefixes = @('AVD-', 'WVD-')   # shared session hosts: primary user not meaningful
# ===========================================================================

# Safety net - stop if the placeholders above weren't replaced.
if ("$ResourceGroup $StorageAccount $Container" -match '<your-') {
    throw "Please set ResourceGroup, StorageAccount, and Container at the top of the script before running."
}

#region ---- STEP 1 : VARIABLES --------------------------------------------------

$ExportLocation = $env:TEMP
$OutputFileName = "IntuneDeviceHygiene.csv"
$OutputBlobName = "agent-data/$OutputFileName"
$BatchEndpoint  = "https://graph.microsoft.com/beta/`$batch"
$GraphBatchSize = 20
$BatchRetryMax  = 3

$ProgressPreference = 'SilentlyContinue'
$VerbosePreference  = 'Continue'

#endregion

#region ---- STEP 2 : HELPERS ----------------------------------------------------

function Invoke-MyGraphGetRequest {
    param ([Parameter(Mandatory)][string]$URL)
    Write-Verbose "GET  $URL"
    $AllResults = [System.Collections.Generic.List[PSObject]]::new()
    try {
        do {
            $Response = Invoke-WebRequest -Uri $URL -Method GET `
                            -Headers $script:Headers -UseBasicParsing
            $Parsed   = $Response.Content | ConvertFrom-Json
            if ($Parsed.value) { $AllResults.AddRange([PSObject[]]$Parsed.value) }
            $URL      = $Parsed.'@odata.nextLink'
        } while ($URL)
        return $AllResults
    }
    catch {
        Write-Error "Graph GET failed [$URL]: $_"
        return $null
    }
}

function Invoke-GraphBatch {
    param (
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[hashtable]]$Requests
    )
    $BatchHeaders = $script:Headers + @{ "Content-Type" = "application/json" }
    $ResponseMap  = @{}
    $Total        = $Requests.Count

    for ($Offset = 0; $Offset -lt $Total; $Offset += $GraphBatchSize) {
        $End   = [math]::Min($Offset + $GraphBatchSize - 1, $Total - 1)
        $Chunk = @($Requests[$Offset..$End])
        Write-Verbose "Batch POST: requests $($Offset+1)-$($End+1) of $Total"

        $Attempt = 0
        do {
            $Attempt++
            $Body = @{ requests = $Chunk } | ConvertTo-Json -Depth 10
            try {
                $Raw       = Invoke-WebRequest -Uri $BatchEndpoint -Method POST `
                                 -Headers $BatchHeaders -Body $Body -UseBasicParsing
                $Parsed    = $Raw.Content | ConvertFrom-Json
                $Responses = @($Parsed.responses)

                $Throttled = $Responses | Where-Object { $_.status -eq 429 }
                $Completed = $Responses | Where-Object { $_.status -ne 429 }

                foreach ($r in $Completed) {
                    $ResponseMap[$r.id] = $r
                    if ($r.status -ne 200) {
                        $ErrCode = if ($r.body.error.code)    { $r.body.error.code }    else { "UnknownError" }
                        $ErrMsg  = if ($r.body.error.message) { $r.body.error.message } else { "No message" }
                        Write-Warning "Batch child failed: id=$($r.id) status=$($r.status) code=$ErrCode message=$ErrMsg"
                    }
                }

                if ($Throttled) {
                    $RetryAfter = ($Throttled | ForEach-Object {
                        if ($_.headers.'Retry-After') { [int]$_.headers.'Retry-After' } else { 30 }
                    } | Measure-Object -Maximum).Maximum
                    if (-not $RetryAfter) { $RetryAfter = 30 }
                    Write-Verbose "Throttled ($($Throttled.Count) requests). Waiting ${RetryAfter}s (attempt $Attempt/$BatchRetryMax)..."
                    Start-Sleep -Seconds $RetryAfter
                    $ThrottledIds = $Throttled | ForEach-Object { $_.id }
                    $Chunk        = @($Chunk | Where-Object { $_.id -in $ThrottledIds })
                }
                else { break }
            }
            catch {
                Write-Warning "Batch POST failed (attempt $Attempt): $_"
                if ($Attempt -lt $BatchRetryMax) { Start-Sleep -Seconds (5 * $Attempt) }
            }
        } while ($Attempt -lt $BatchRetryMax -and $Chunk.Count -gt 0)
    }
    return $ResponseMap
}

function Get-SafeDateString {
    param($Value)
    if (-not $Value) { return "Unknown" }
    try   { return (Get-Date $Value).ToString("yyyy-MM-dd") }
    catch { return "Unknown" }
}

function Get-SafeDaysAgo {
    param($Value)
    if (-not $Value) { return "Unknown" }
    try   { return [math]::Round(((Get-Date) - (Get-Date $Value)).TotalDays, 0) }
    catch { return "Unknown" }
}

function Get-NoteValue {
    # Parses a single key=value line from structured device notes
    param([string]$Notes, [string]$Key)
    if ([string]::IsNullOrEmpty($Notes)) { return "" }
    foreach ($Line in ($Notes -split "`r`n|`r|`n")) {
        if ($Line -match "^$Key\s*=\s*(.+)$") { return $Matches[1].Trim() }
    }
    return ""
}

#endregion

#region ---- STEP 3 : AUTHENTICATE (MANAGED IDENTITY) ---------------------------

Write-Verbose "Obtaining Managed Identity access token..."
try {
    $TknHeaders     = @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER; "Metadata" = "True" }
    $TknBody        = @{ resource = 'https://graph.microsoft.com/' }
    $AccessToken    = (Invoke-RestMethod $env:IDENTITY_ENDPOINT -Method POST `
                           -Headers $TknHeaders `
                           -ContentType 'application/x-www-form-urlencoded' `
                           -Body $TknBody).access_token
    $script:Headers = @{ 'Authorization' = "Bearer $AccessToken" }
    Write-Verbose "Access token obtained."
}
catch { Write-Error "Authentication failed: $_"; throw }

#endregion

#region ---- STEP 4 : FETCH ALL INTUNE MANAGED DEVICES --------------------------
#
#  AVD/WVD session hosts excluded after fetch.
#  These are shared session hosts — primary user assignment is not meaningful.

Write-Verbose "Fetching all Intune managed devices..."

$DeviceFields = @(
    "id", "deviceName", "userPrincipalName", "userDisplayName",
    "serialNumber", "manufacturer", "model",
    "operatingSystem", "osVersion",
    "complianceState", "isEncrypted",
    "lastSyncDateTime", "enrolledDateTime",
    "managedDeviceOwnerType", "deviceEnrollmentType",
    "azureADDeviceId", "managementState", "joinType",
    "managementAgent", "deviceCategoryDisplayName"
) -join ","

$AllDevicesRaw = Invoke-MyGraphGetRequest -URL `
    "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=$DeviceFields"

if (-not $AllDevicesRaw) { Write-Error "No device data returned. Exiting."; exit 1 }
Write-Verbose "Total managed devices (raw): $($AllDevicesRaw.Count)"

# Exclude AVD/WVD session hosts
$AllDevices = $AllDevicesRaw | Where-Object {
    $n = $_.deviceName
    -not ($ExcludedPrefixes | Where-Object { $n -like "$_*" })
}

Write-Verbose "Total managed devices after AVD/WVD exclusion: $($AllDevices.Count)  (excluded: $($AllDevicesRaw.Count - $AllDevices.Count))"

#endregion

#region ---- STEP 5 : FETCH DISABLED ENTRA ID MEMBERS ---------------------------

Write-Verbose "Fetching disabled Entra ID member accounts..."

$DisabledUsersRaw = Invoke-MyGraphGetRequest -URL (
    "https://graph.microsoft.com/v1.0/users" +
    "?`$select=id,userPrincipalName,accountEnabled,userType" +
    "&`$filter=accountEnabled eq false and userType eq 'Member'"
)

$DisabledUPNSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

# UPN to Entra object ID map — used for batch URLs (Step 9) and audit log queries (Step 8)
$UserIdMap = @{}

foreach ($u in $DisabledUsersRaw) {
    if ($u.userPrincipalName) {
        [void]$DisabledUPNSet.Add($u.userPrincipalName)
        if ($u.id) { $UserIdMap[$u.userPrincipalName] = $u.id }
    }
}

Write-Verbose "Disabled member accounts: $($DisabledUPNSet.Count)"

#endregion

#region ---- STEP 6 : SPLIT DEVICES INTO BUCKETS --------------------------------

$TargetDevices = $AllDevices | Where-Object {
    $_.userPrincipalName -and $DisabledUPNSet.Contains($_.userPrincipalName)
}

# Corporate-owned only — personal BYOD without a primary user is expected
$OrphanedDevices = $AllDevices | Where-Object {
    (-not $_.userPrincipalName) -and ($_.managedDeviceOwnerType -eq 'company')
}

Write-Verbose "Devices - disabled user        : $($TargetDevices.Count)"
Write-Verbose "Devices - orphaned (corporate) : $($OrphanedDevices.Count)"

#endregion

#region ---- STEP 7 : FETCH NOTES FOR LENOVO DEVICES (BATCH) --------------------
#
#  Only Lenovo devices need notes lookup.
#  Non-Lenovo manufacturers have human-readable names in the model field already.
#
#  Lenovo stores a 4-char MTM code in model (e.g. 20XW). A separate runbook
#  resolves MTM -> friendly name and writes Model=, WarrantyStartDate=,
#  WarrantyEndDate= to device notes. We read those values here.
#
#  Graph bulk fetch has known inconsistencies with the notes field.
#  Individual queries per device via $batch ensure accuracy.

$AllReportDevicesForNotes = @($TargetDevices) + @($OrphanedDevices)
$LenovoDevices            = $AllReportDevicesForNotes | Where-Object {
    $_.manufacturer -and $_.manufacturer -like '*lenovo*'
}

Write-Verbose "Lenovo devices requiring notes fetch: $($LenovoDevices.Count)"

$NotesBatchReqs = [System.Collections.Generic.List[hashtable]]::new()
$NotesIdIndex   = @{}   # request id -> device id

$Index = 0
foreach ($Device in $LenovoDevices) {
    $ReqId = "n$Index"
    $NotesBatchReqs.Add(@{
        id     = $ReqId
        method = "GET"
        url    = "/deviceManagement/managedDevices/$($Device.id)`?`$select=id,notes"
    })
    $NotesIdIndex[$ReqId] = $Device.id
    $Index++
}

$NotesMap = @{}

if ($NotesBatchReqs.Count -gt 0) {
    Write-Verbose "Notes batch requests: $($NotesBatchReqs.Count)"
    Write-Verbose "Batch POSTs required: $([math]::Ceiling($NotesBatchReqs.Count / $GraphBatchSize))"

    $NotesBatchResponses = Invoke-GraphBatch -Requests $NotesBatchReqs

    foreach ($ReqId in $NotesIdIndex.Keys) {
        $Resp = $NotesBatchResponses[$ReqId]
        if ($Resp -and $Resp.status -eq 200) {
            $NotesMap[$NotesIdIndex[$ReqId]] = $Resp.body.notes
        }
    }
    Write-Verbose "Notes fetched for $($NotesMap.Count) Lenovo devices."
}

#endregion

#region ---- STEP 8 : ACCOUNT DISABLED DATE (AUDIT LOGS) ------------------------
#
#  Queries Entra audit logs for the last Update user event where
#  AccountEnabled was set to false. Only for unique disabled user UPNs
#  from TargetDevices — no calls for orphaned device rows.
#
#  Retention: 30 days (P1) / 90 days (P2).
#  Returns "Before audit log retention" if event predates the window.

function Get-AccountDisabledDate {
    param([string]$UserId, [string]$UPN)
    if (-not $UserId) { return "Unknown" }

    $Uri = "https://graph.microsoft.com/v1.0/auditLogs/directoryAudits" +
           "?`$filter=targetResources/any(t: t/id eq '$UserId')" +
           " and activityDisplayName eq 'Update user'" +
           "&`$orderby=activityDateTime desc&`$top=100"

    $MaxRetries = 4
    $Attempt    = 0

    do {
        $Attempt++
        try {
            $Response = Invoke-RestMethod -Uri $Uri -Headers $script:Headers -Method GET -TimeoutSec 30
            foreach ($Entry in $Response.value) {
                foreach ($Target in $Entry.targetResources) {
                    foreach ($Prop in $Target.modifiedProperties) {
                        if ($Prop.displayName -eq 'AccountEnabled' -and $Prop.newValue -eq '"false"') {
                            return (Get-Date $Entry.activityDateTime).ToString("yyyy-MM-dd")
                        }
                    }
                }
            }
            return "Before audit log retention"
        }
        catch {
            $ErrBody = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            $IsThrottle = ($_.Exception.Response.StatusCode -eq 429) -or
                          ($ErrBody.error.message -like "*Too Many Requests*")

            if ($IsThrottle -and $Attempt -lt $MaxRetries) {
                # Try to read Retry-After header; default to exponential backoff
                $RetryAfter = 30
                try {
                    $HeaderVal = $_.Exception.Response.Headers.GetValues("Retry-After")[0]
                    if ($HeaderVal) { $RetryAfter = [int]$HeaderVal }
                } catch {}
                $Wait = [math]::Max($RetryAfter, (5 * $Attempt))
                Write-Warning "Audit log throttled [$UPN] - waiting ${Wait}s (attempt $Attempt/$MaxRetries)..."
                Start-Sleep -Seconds $Wait
            }
            else {
                Write-Warning "Audit log fetch failed [$UPN]: $_"
                return "Unknown"
            }
        }
    } while ($Attempt -lt $MaxRetries)

    Write-Warning "Audit log max retries reached [$UPN]"
    return "Unknown"
}

$DisabledDateMap = @{}
$UniqueDisabledUPNs = $TargetDevices |
    Select-Object -ExpandProperty userPrincipalName -Unique |
    Where-Object { $_ }

Write-Verbose "Fetching account disabled dates for $($UniqueDisabledUPNs.Count) unique disabled users..."

foreach ($UPN in $UniqueDisabledUPNs) {
    $ObjId = if ($UserIdMap.ContainsKey($UPN)) { $UserIdMap[$UPN] } else { $null }
    $DisabledDateMap[$UPN] = Get-AccountDisabledDate -UserId $ObjId -UPN $UPN
    Write-Verbose "DisabledDate [$UPN]: $($DisabledDateMap[$UPN])"
    Start-Sleep -Seconds 1   # Audit log endpoint throttles aggressively — 1s minimum between calls
}

#endregion

#region ---- STEP 9 : ENRICH UNIQUE DISABLED USERS (BATCH) ----------------------
#
#  2 calls per unique UPN via object ID (not UPN) to avoid Graph batch
#  URL parsing issue with %40-encoded UPN as final path segment.

Write-Verbose "Building user enrichment batch requests..."

$UniqueUPNs    = $TargetDevices |
                     Select-Object -ExpandProperty userPrincipalName -Unique |
                     Where-Object { $_ }

$UserBatchReqs = [System.Collections.Generic.List[hashtable]]::new()

$ProfileFields = (
    "id,displayName,userPrincipalName,mail," +
    "city,country,officeLocation,department," +
    "jobTitle,onPremisesSyncEnabled," +
    "signInActivity"
)

$Index = 0
foreach ($UPN in $UniqueUPNs) {

    $ObjId = if ($UserIdMap.ContainsKey($UPN)) { $UserIdMap[$UPN] } else { $null }

    if (-not $ObjId) {
        Write-Warning "No object ID found for UPN [$UPN] - skipping enrichment"
        $Index++
        continue
    }

    $UserBatchReqs.Add(@{
        id     = "u$Index-profile"
        method = "GET"
        url    = "/users/$ObjId`?`$select=$ProfileFields"
    })
    $UserBatchReqs.Add(@{
        id     = "u$Index-manager"
        method = "GET"
        url    = "/users/$ObjId/manager?`$select=displayName,userPrincipalName"
    })
    $UserBatchReqs.Add(@{
        id     = "u$Index-licence"
        method = "GET"
        url    = "/users/$ObjId/licenseDetails?`$select=skuPartNumber"
    })

    $Index++
}

Write-Verbose "User batch requests: $($UserBatchReqs.Count) across $($UniqueUPNs.Count) users"
Write-Verbose "Batch POSTs required: $([math]::Ceiling($UserBatchReqs.Count / $GraphBatchSize))"

$UserBatchResponses = Invoke-GraphBatch -Requests $UserBatchReqs

$UserDetailMap = @{}
$Index = 0

foreach ($UPN in $UniqueUPNs) {

    $PR = $UserBatchResponses["u$Index-profile"]
    $MR = $UserBatchResponses["u$Index-manager"]
    $LR = $UserBatchResponses["u$Index-licence"]

    $P  = if ($PR -and $PR.status -eq 200) { $PR.body } else { $null }
    $M  = if ($MR -and $MR.status -eq 200) { $MR.body } else { $null }
    $L  = if ($LR -and $LR.status -eq 200 -and $LR.body.value) { $LR.body.value } else { @() }

    $HasLicences   = ($L.Count -gt 0)
    $LicenceList   = if ($HasLicences) { ($L.skuPartNumber | Sort-Object) -join "; " } else { "None" }

    $UserDetailMap[$UPN] = [PSCustomObject]@{
        UserDisplayName    = if ($P.displayName)       { $P.displayName }       else { "Unknown" }
        Mail               = if ($P.mail)               { $P.mail }               else { "Unknown" }
        Department         = if ($P.department)         { $P.department }         else { "Unknown" }
        JobTitle           = if ($P.jobTitle)           { $P.jobTitle }           else { "Unknown" }
        City               = if ($P.city)               { $P.city }               else { "Unknown" }
        Country            = if ($P.country)            { $P.country }            else { "Unknown" }
        OfficeLocation     = if ($P.officeLocation)     { $P.officeLocation }     else { "Unknown" }
        OnPremisesSynced   = if ($null -ne $P.onPremisesSyncEnabled) { $P.onPremisesSyncEnabled } else { $false }
        LastSignInDate     = Get-SafeDateString $P.signInActivity.lastSignInDateTime
        LastSignInDaysAgo  = Get-SafeDaysAgo    $P.signInActivity.lastSignInDateTime
        ManagerDisplayName = if ($M.displayName)       { $M.displayName }       else { "No Manager" }
        ManagerUPN         = if ($M.userPrincipalName) { $M.userPrincipalName } else { "Unknown" }
        # ManagerMail omitted — commonly identical to ManagerUPN; excluded to keep rows lean
        HasActiveLicences  = $HasLicences
        AssignedLicences   = $LicenceList
    }

    $Index++
}

Write-Verbose "User enrichment complete. Users processed: $($UserDetailMap.Count)"

#endregion

#region ---- STEP 10 : ENRICH ALL REPORT DEVICES - ENTRA OBJECT (BATCH) ---------
#
#  Covers both TargetDevices and OrphanedDevices.
#  Skips null GUIDs (00000000-0000-0000-0000-000000000000 = never registered).

Write-Verbose "Building Entra device object batch requests..."

$AllReportDevices = @($TargetDevices) + @($OrphanedDevices)
$DeviceBatchReqs  = [System.Collections.Generic.List[hashtable]]::new()
$DeviceIdIndex    = @{}

$Index = 0
foreach ($Device in $AllReportDevices) {
    if (-not $Device.azureADDeviceId -or
        $Device.azureADDeviceId -eq '00000000-0000-0000-0000-000000000000') {
        $Index++
        continue
    }
    $ReqId = "d$Index"
    $DeviceBatchReqs.Add(@{
        id     = $ReqId
        method = "GET"
        url    = "/devices?`$filter=deviceId eq '$($Device.azureADDeviceId)'&`$select=deviceId,accountEnabled,riskLevel,riskLastUpdatedDateTime"
    })
    $DeviceIdIndex[$ReqId] = $Device.azureADDeviceId
    $Index++
}

Write-Verbose "Device batch requests: $($DeviceBatchReqs.Count)"
Write-Verbose "Batch POSTs required: $([math]::Ceiling($DeviceBatchReqs.Count / $GraphBatchSize))"

$DeviceBatchResponses = Invoke-GraphBatch -Requests $DeviceBatchReqs

$EntraDeviceMap = @{}
foreach ($ReqId in $DeviceIdIndex.Keys) {
    $Resp = $DeviceBatchResponses[$ReqId]
    if ($Resp -and $Resp.status -eq 200 -and $Resp.body.value -and $Resp.body.value.Count -gt 0) {
        $EntraDeviceMap[$DeviceIdIndex[$ReqId]] = $Resp.body.value[0]
    }
    elseif ($Resp -and $Resp.status -eq 200) {
        Write-Verbose "No Entra device object matched azureADDeviceId [$($DeviceIdIndex[$ReqId])]"
    }
}

Write-Verbose "Entra device objects resolved: $($EntraDeviceMap.Count)"

#endregion

#region ---- STEP 11 : COMPUTE HELPERS ------------------------------------------

function Get-DeviceBaseRow {
    param ($Device)

    $LastSyncDaysAgo = if ($Device.lastSyncDateTime) {
        [math]::Round(((Get-Date) - (Get-Date $Device.lastSyncDateTime)).TotalDays, 0)
    } else { -1 }

    $IsInactive  = ($LastSyncDaysAgo -ne -1) -and ($LastSyncDaysAgo -gt $InactiveDays)
    $MgmtAgent   = if ($Device.managementAgent) { $Device.managementAgent.ToString() } else { "" }
    $IsCoManaged = $MgmtAgent -in @('configurationManagerClientMdm', 'configurationManagerClientMdmEas')

    $IsStaleHybrid      = ($Device.joinType -eq 'hybrid') -and $IsInactive
    $IdentityDependency = ($Device.joinType -eq 'hybrid')

    $EntraObj        = if ($Device.azureADDeviceId -and
                            $EntraDeviceMap.ContainsKey($Device.azureADDeviceId)) {
                           $EntraDeviceMap[$Device.azureADDeviceId] } else { $null }
    $EntraDevEnabled = if ($EntraObj -and $null -ne $EntraObj.accountEnabled) {
                           $EntraObj.accountEnabled } else { "Unknown" }
    $DeviceRisk      = if ($EntraObj -and $EntraObj.riskLevel) {
                           $EntraObj.riskLevel } else { "none" }
    $RiskUpdated     = Get-SafeDateString ($EntraObj.riskLastUpdatedDateTime)

    return @{
        DeviceName               = if ($Device.deviceName)               { $Device.deviceName }               else { "Unknown" }
        SerialNumber             = if ($Device.serialNumber)             { $Device.serialNumber }             else { "Unknown" }
        Manufacturer             = if ($Device.manufacturer)             { $Device.manufacturer }             else { "Unknown" }
        Model                    = if ($Device.model)                    { $Device.model }                    else { "Unknown" }
        OperatingSystem          = if ($Device.operatingSystem)          { $Device.operatingSystem }          else { "Unknown" }
        OSVersion                = if ($Device.osVersion)                { $Device.osVersion }                else { "Unknown" }
        DeviceCategory           = if ($Device.deviceCategoryDisplayName){ $Device.deviceCategoryDisplayName } else { "Not Set" }
        OwnerType                = if ($Device.managedDeviceOwnerType)   { $Device.managedDeviceOwnerType }   else { "Unknown" }
        EnrollmentType           = if ($Device.deviceEnrollmentType)     { $Device.deviceEnrollmentType }     else { "Unknown" }
        JoinType                 = if ($Device.joinType)                 { $Device.joinType }                 else { "Unknown" }
        ManagementState          = if ($Device.managementState)          { $Device.managementState }          else { "Unknown" }
        ManagementAgent          = if ($MgmtAgent)                       { $MgmtAgent }                       else { "Unknown" }
        IsCoManaged              = $IsCoManaged
        IsEncrypted              = $Device.isEncrypted
        ComplianceState          = if ($Device.complianceState)          { $Device.complianceState }          else { "Unknown" }
        EnrolledDate             = Get-SafeDateString $Device.enrolledDateTime
        LastSyncDate             = Get-SafeDateString $Device.lastSyncDateTime
        LastSyncDaysAgo          = if ($LastSyncDaysAgo -eq -1)          { "Unknown" }                        else { $LastSyncDaysAgo }
        IsInactive               = $IsInactive
        EntraDeviceObjectEnabled = $EntraDevEnabled
        DeviceRiskLevel          = $DeviceRisk
        DeviceRiskLastUpdated    = $RiskUpdated
        IdentityDependencyFlag   = $IdentityDependency
        IsStaleHybridObject      = $IsStaleHybrid
    }
}

function Get-RecommendedAction {
    param (
        [bool]  $IsInactive,
        [bool]  $IsCoManaged,
        [bool]  $IsStaleHybrid,
                $EntraDeviceEnabled,
        [string]$DeviceRiskLevel,
        [string]$ReportType
    )
    if ($DeviceRiskLevel -in @('high', 'medium')) {
        return "URGENT - Investigate: Entra device risk is $DeviceRiskLevel"
    }
    if ($EntraDeviceEnabled -eq $false) {
        return "Review: Entra device object already disabled - confirm wipe completed"
    }
    if ($ReportType -eq 'Orphaned') {
        if ($IsInactive) { return "Retire: Orphaned and inactive - safe to wipe and retire" }
        return "Review: Active orphaned device - assign primary user"
    }
    if ($IsCoManaged)   { return "Retire (Co-Managed): Coordinate retire in both Intune and SCCM" }
    if ($IsStaleHybrid) { return "Review AD Object: Stale hybrid device - check on-premises computer object" }
    if ($IsInactive)    { return "Retire: Inactive device on disabled account - safe to wipe and retire" }
    return "Wipe and Reassign"
}

#endregion

#region ---- STEP 12 : BUILD FINAL REPORT ---------------------------------------

Write-Verbose "Building IntuneDeviceHygiene report..."

$FinalReport = [System.Collections.Generic.List[PSObject]]::new()

function New-ReportRow {
    param ($Device, [string]$ReportType)

    $Base  = Get-DeviceBaseRow -Device $Device
    $UPN   = $Device.userPrincipalName
    $UD    = if ($UPN -and $UserDetailMap.ContainsKey($UPN)) { $UserDetailMap[$UPN] } else { $null }

    # Notes fields — Lenovo devices only
    $Notes              = if ($NotesMap.ContainsKey($Device.id)) { $NotesMap[$Device.id] } else { $null }
    $LenovoModel        = Get-NoteValue -Notes $Notes -Key "Model"
    $WarrantyStartDate  = Get-NoteValue -Notes $Notes -Key "WarrantyStartDate"
    $WarrantyEndDate    = Get-NoteValue -Notes $Notes -Key "WarrantyEndDate"

    # Account disabled date
    $DisabledDate = if ($UPN -and $DisabledDateMap.ContainsKey($UPN)) {
        $DisabledDateMap[$UPN] } else { "" }

    $ActionOwner = if ($UD -and $UD.ManagerUPN -ne "Unknown") {
        "$($UD.ManagerDisplayName) ($($UD.ManagerUPN))"
    } else { "IT Service Desk" }

    $Action = Get-RecommendedAction `
        -IsInactive         $Base.IsInactive `
        -IsCoManaged        $Base.IsCoManaged `
        -IsStaleHybrid      $Base.IsStaleHybridObject `
        -EntraDeviceEnabled $Base.EntraDeviceObjectEnabled `
        -DeviceRiskLevel    $Base.DeviceRiskLevel `
        -ReportType         $ReportType

    return [PSCustomObject][ordered]@{
        # ── CLASSIFICATION ───────────────────────────────────────────────────
        ReportType               = $ReportType
        RecommendedAction        = $Action
        ActionOwner              = $ActionOwner
        # ── DEVICE ───────────────────────────────────────────────────────────
        DeviceName               = $Base.DeviceName
        SerialNumber             = $Base.SerialNumber
        Manufacturer             = $Base.Manufacturer
        Model                    = $Base.Model        # Raw model field (MTM code for Lenovo)
        OperatingSystem          = $Base.OperatingSystem
        OSVersion                = $Base.OSVersion
        DeviceCategory           = $Base.DeviceCategory
        OwnerType                = $Base.OwnerType
        EnrollmentType           = $Base.EnrollmentType
        JoinType                 = $Base.JoinType
        ManagementState          = $Base.ManagementState
        ManagementAgent          = $Base.ManagementAgent
        IsCoManaged              = $Base.IsCoManaged
        IsEncrypted              = $Base.IsEncrypted
        ComplianceState          = $Base.ComplianceState
        EnrolledDate             = $Base.EnrolledDate
        LastSyncDate             = $Base.LastSyncDate
        LastSyncDaysAgo          = $Base.LastSyncDaysAgo
        IsInactive               = $Base.IsInactive
        # ── LENOVO NOTES (blank for non-Lenovo devices) ───────────────────────
        LenovoModelFriendlyName  = $LenovoModel
        WarrantyStartDate        = $WarrantyStartDate
        WarrantyEndDate          = $WarrantyEndDate
        # ── ENTRA DEVICE OBJECT ──────────────────────────────────────────────
        EntraDeviceObjectEnabled = $Base.EntraDeviceObjectEnabled
        DeviceRiskLevel          = $Base.DeviceRiskLevel
        DeviceRiskLastUpdated    = $Base.DeviceRiskLastUpdated
        # ── IDENTITY / ARCHITECTURE ──────────────────────────────────────────
        IdentityDependencyFlag   = $Base.IdentityDependencyFlag
        IsStaleHybridObject      = $Base.IsStaleHybridObject
        # ── ASSIGNED USER (empty for Orphaned rows) ───────────────────────────
        AssignedUserUPN          = if ($UD) { $UPN }                  else { "" }
        AssignedUserDisplayName  = if ($UD) { $UD.UserDisplayName }   else { "" }
        Mail                     = if ($UD) { $UD.Mail }               else { "" }
        Department               = if ($UD) { $UD.Department }         else { "" }
        JobTitle                 = if ($UD) { $UD.JobTitle }           else { "" }
        City                     = if ($UD) { $UD.City }               else { "" }
        Country                  = if ($UD) { $UD.Country }            else { "" }
        OfficeLocation           = if ($UD) { $UD.OfficeLocation }     else { "" }
        OnPremisesSynced         = if ($UD) { $UD.OnPremisesSynced }   else { "" }
        UserLastSignInDate       = if ($UD) { $UD.LastSignInDate }     else { "" }
        UserLastSignInDaysAgo    = if ($UD) { $UD.LastSignInDaysAgo }  else { "" }
        AccountDisabledDate      = $DisabledDate
        UserHasActiveLicences    = if ($UD) { $UD.HasActiveLicences }  else { "" }
        UserAssignedLicences     = if ($UD) { $UD.AssignedLicences }   else { "" }
        # ── MANAGER (UPN only — ManagerMail omitted, commonly identical to UPN) ─
        ManagerDisplayName       = if ($UD) { $UD.ManagerDisplayName } else { "" }
        ManagerUPN               = if ($UD) { $UD.ManagerUPN }         else { "" }
    }
}

foreach ($Device in $TargetDevices)   { $FinalReport.Add((New-ReportRow -Device $Device -ReportType "DisabledUser")) }
foreach ($Device in $OrphanedDevices) { $FinalReport.Add((New-ReportRow -Device $Device -ReportType "Orphaned")) }

Write-Verbose "Total report rows: $($FinalReport.Count)  (DisabledUser: $($TargetDevices.Count)  Orphaned: $($OrphanedDevices.Count))"

#endregion

#region ---- STEP 13 : EXPORT CSV -----------------------------------------------

Write-Verbose "Exporting CSV..."

if (-not (Test-Path $ExportLocation)) {
    New-Item -ItemType Directory -Path $ExportLocation | Out-Null
}

$OutputFilePath = Join-Path $ExportLocation $OutputFileName
$FinalReport | Export-Csv -Path $OutputFilePath -NoTypeInformation -Encoding UTF8 -Force

Write-Verbose "Exported: $OutputFileName  ($($FinalReport.Count) rows)"

#endregion

#region ---- STEP 14 : UPLOAD TO AZURE BLOB STORAGE ----------------------------

Write-Verbose "Uploading to Azure Blob Storage..."

try {
    $Ctx = (Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $StorageAccount).Context
    Set-AzStorageBlobContent -File $OutputFilePath `
                         -Container $Container `
                         -Blob $OutputBlobName `
                         -Context $Ctx `
                         -Force | Out-Null
    Write-Verbose "Uploaded: $OutputFileName"
}
catch { Write-Warning "Blob upload failed: $_" }

Write-Verbose "Script completed."

#endregion
