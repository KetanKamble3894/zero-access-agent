#requires -Version 7.0
<#
.SYNOPSIS
    Enrich-LenovoWarrantyToNotes.ps1 — OPTIONAL source-enrichment utility.
    Looks up Lenovo warranty by serial number and (in update mode) writes it into each
    device's Intune Notes field as WarrantyStartDate= / WarrantyEndDate= lines.

.DESCRIPTION
    This is NOT a read-only collector, and it is NOT part of the zero-access collection
    layer. It is the one tool in this project that can WRITE to the tenant, and it is kept
    deliberately separate for that reason.

      - Default mode (-ReportOnly $true): read-only. Looks up warranty and writes a CSV
        report; touches nothing in Intune.
      - Update mode  (-ReportOnly $false): PATCHes managedDevices notes to append warranty
        fields. "Surgical" append — it only ADDS WarrantyStartDate/WarrantyEndDate if
        absent and never rewrites existing Notes content.

    Why it exists: persisting warranty into Notes once means the read-only inventory
    collector (and Power BI) can simply READ it later, instead of every consumer scraping
    Lenovo. The trade-off is honest — that persistence is a write, so this utility lives
    outside the "read-only by construction" guarantee that covers the collection→agent path.

.PARAMETER ReportOnly
    $true (default) = read-only report. $false = write warranty fields into device Notes.

.NOTES
    SCOPES:
      Report-only mode : DeviceManagementManagedDevices.Read.All  + Storage Blob Data Contributor
      Update mode      : DeviceManagementManagedDevices.ReadWrite.All  (the ONLY place this
                         project uses a write scope — grant it only if you run update mode)

    LENOVO LOOKUP CAVEAT: this calls an undocumented Lenovo support endpoint and parses the
    warranty HTML with regex. It is fragile — Lenovo can change or block it without notice,
    and you should check Lenovo's terms of use before running it at scale. Lenovo also offers
    an official Warranty API (requires a key) which is the robust long-term option.

    GENERIC / PARAMETERIZED: no resource group, storage account, or container is hardcoded.
    Run against a personal lab tenant only.

    MIT licensed. Microsoft/Intune/Entra/Graph/Azure and Lenovo are trademarks of their
    respective owners. Independent content; not endorsed by Microsoft or Lenovo. Verify in
    your own lab tenant before relying on it.
#>

# ===========================================================================
#  CONFIGURE ME  ->  set these to your own values, then run.
#  These three lines are the only thing you MUST change.
# ===========================================================================
$ResourceGroup  = "<your-resource-group-name>"     # resource group that holds your storage account
$StorageAccount = "<your-storage-account-name>"    # storage account name (lowercase, globally unique)
$Container      = "<your-container-name>"           # blob container, e.g. "intune-report"

# -- mode + optional settings ----------------------------------------------
$ReportOnly     = $true                                   # $true = READ-ONLY report. $false = WRITE warranty into device Notes (needs ReadWrite scope)
$BatchSize      = 25                                      # progress-log interval
$OutputFileName = "LenovoWarrantyReport_IntuneNotes.csv"  # CSV name written to the container
# ===========================================================================

# Safety net - stop if the placeholders above weren't replaced.
if ("$ResourceGroup $StorageAccount $Container" -match '<your-') {
    throw "Please set ResourceGroup, StorageAccount, and Container at the top of the script before running."
}

$ExportLocation = "$env:TEMP"

# Enhanced logging with mode awareness
$LogTime = { Get-Date -Format "yyyy-MM-dd HH:mm:ss" }
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = & $LogTime
    $mode = if ($ReportOnly) { "[REPORT-ONLY]" } else { "[UPDATE-MODE]" }
    $logMessage = "[$timestamp] $mode [$Level] $Message"

    switch ($Level) {
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
        "WARN"  { Write-Host $logMessage -ForegroundColor Yellow }
        "INFO"  { Write-Host $logMessage -ForegroundColor Green }
        "DEBUG" { Write-Host $logMessage -ForegroundColor Gray }
        default { Write-Host $logMessage }
    }
}

if ($ReportOnly) {
    Write-Log "STARTING IN REPORT-ONLY MODE - NO DEVICE NOTES WILL BE MODIFIED" "INFO"
} else {
    Write-Log "STARTING IN UPDATE MODE - INDIVIDUAL DEVICE QUERIES WITH SURGICAL NOTES APPEND" "WARN"
}

Write-Log "Using individual device queries with `$select to avoid API inconsistencies" "INFO"

# Get individual device with accurate notes using $select
function Get-DeviceWithAccurateNotes {
    param([string]$DeviceId)

    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$DeviceId`?`$select=id,deviceName,serialNumber,notes"

    try {
        $device = Invoke-RestMethod -Uri $uri -Headers $script:Headers -Method GET -TimeoutSec 30
        Write-Log "INDIVIDUAL QUERY: Retrieved accurate notes for device $($device.deviceName)" "DEBUG"
        return $device
    } catch {
        Write-Log "FAILED to get individual device $DeviceId : $_" "ERROR"
        return $null
    }
}

# SURGICAL WARRANTY APPEND: only add warranty fields, never modify existing content
function Add-WarrantyFieldsSurgically {
    param([string]$ExistingNotes, [hashtable]$WarrantyInfo)

    Write-Log "SURGICAL APPEND: Adding warranty fields without touching existing content" "DEBUG"

    $updatedNotes = $ExistingNotes
    $changesMade = $false

    if ([string]::IsNullOrEmpty($updatedNotes)) {
        $notesLines = @()
    } else {
        $notesLines = @($updatedNotes -split "`r`n|`r|`n")
    }

    if ($WarrantyInfo.Start) {
        $hasStartDate = $false
        $targetStartLine = "WarrantyStartDate=$($WarrantyInfo.Start)"
        foreach ($line in $notesLines) {
            if ($line -match "^WarrantyStartDate\s*=") { $hasStartDate = $true; break }
        }
        if (-not $hasStartDate) {
            $notesLines += $targetStartLine
            $changesMade = $true
            Write-Log "SURGICAL: Added WarrantyStartDate=$($WarrantyInfo.Start)" "DEBUG"
        } else {
            Write-Log "SURGICAL: WarrantyStartDate already exists, skipping" "DEBUG"
        }
    }

    if ($WarrantyInfo.End) {
        $hasEndDate = $false
        $targetEndLine = "WarrantyEndDate=$($WarrantyInfo.End)"
        foreach ($line in $notesLines) {
            if ($line -match "^WarrantyEndDate\s*=") { $hasEndDate = $true; break }
        }
        if (-not $hasEndDate) {
            $notesLines += $targetEndLine
            $changesMade = $true
            Write-Log "SURGICAL: Added WarrantyEndDate=$($WarrantyInfo.End)" "DEBUG"
        } else {
            Write-Log "SURGICAL: WarrantyEndDate already exists, skipping" "DEBUG"
        }
    }

    $finalNotes = $notesLines -join "`n"
    return @{ Notes = $finalNotes; ChangesMade = $changesMade }
}

# WARRANTY LOOKUP — undocumented Lenovo endpoint + HTML scrape (see caveat in header)
function Get-LenovoWarranty {
    param([string]$SerialNumber, [string]$DeviceName)

    if ([string]::IsNullOrEmpty($SerialNumber)) {
        Write-Log "No serial number for device: $DeviceName" "WARN"
        return @{ Status = "No Serial"; Start = ""; End = "" }
    }

    Write-Log "Getting warranty for $DeviceName (Serial: $SerialNumber)" "DEBUG"

    try {
        $Device_Info = Invoke-RestMethod "https://pcsupport.lenovo.com/us/en/api/v4/mse/getproducts?productId=$SerialNumber" -TimeoutSec 15
        $Device_ID = $Device_Info.id
        if ([string]::IsNullOrEmpty($Device_ID)) {
            Write-Log "Can not get device ID for serial number: $SerialNumber" "WARN"
            return @{ Status = "No Device ID"; Start = ""; End = "" }
        }
        Write-Log "Found device ID: $Device_ID" "DEBUG"
        $Warranty_url = "https://pcsupport.lenovo.com/us/en/products/$Device_ID/warranty"
    } catch {
        Write-Log "Can not get information for the serial number: $SerialNumber - $_" "ERROR"
        return @{ Status = "API Error"; Start = ""; End = "" }
    }

    try {
        $Web_Response = Invoke-WebRequest -Uri $Warranty_url -Method GET -TimeoutSec 20
    } catch {
        Write-Log "Can not get warranty info for the serial number: $SerialNumber - $_" "ERROR"
        return @{ Status = "Page Error"; Start = ""; End = "" }
    }

    if ($Web_Response.StatusCode -eq 200) {
        $HTML_Content = $Web_Response.Content

        $Pattern_Status    = '"warrantystatus":"(.*?)"'
        $Pattern_Status2   = '"StatusV2":"(.*?)"'
        $Pattern_StartDate = '"Start":"(.*?)"'
        $Pattern_EndDate   = '"End":"(.*?)"'

        $Status_Matches    = [regex]::Matches($HTML_Content, $Pattern_Status)
        $Statusv2_Matches  = [regex]::Matches($HTML_Content, $Pattern_Status2)
        $StartDate_Matches = [regex]::Matches($HTML_Content, $Pattern_StartDate)
        $EndDate_Matches   = [regex]::Matches($HTML_Content, $Pattern_EndDate)

        $Status_Result   = if ($Status_Matches.Count -gt 0)   { $Status_Matches[0].Groups[1].Value.Trim() }   else { "Can not get status info" }
        $Statusv2_Result = if ($Statusv2_Matches.Count -gt 0) { $Statusv2_Matches[0].Groups[1].Value.Trim() } else { "Can not get status info" }

        if ($StartDate_Matches.Count -gt 0) {
            $StartDate_Result = ($StartDate_Matches[0].Groups[1].Value.Trim() -split 'T')[0]
        } else { $StartDate_Result = "" }

        if ($EndDate_Matches.Count -gt 0) {
            $EndDate_Result = ($EndDate_Matches[0].Groups[1].Value.Trim() -split 'T')[0]
        } else { $EndDate_Result = "" }

        $FinalStatus = "Unknown"
        if ($EndDate_Result -and $EndDate_Result -match '^\d{4}-\d{2}-\d{2}') {
            try {
                $EndDate = [DateTime]::Parse($EndDate_Result)
                $FinalStatus = if ((Get-Date) -lt $EndDate) { "Active" } else { "Expired" }
            } catch { $FinalStatus = $Status_Result }
        }
        elseif ($Statusv2_Result -eq "true") { $FinalStatus = "Active" }
        elseif ($Status_Result -ne "Can not get status info") { $FinalStatus = $Status_Result }

        Write-Log "WARRANTY RESULT for '$DeviceName': Status=$FinalStatus, Start=$StartDate_Result, End=$EndDate_Result" "INFO"
        return @{ Status = $FinalStatus; Start = $StartDate_Result; End = $EndDate_Result }
    } else {
        Write-Log "Warranty page returned status $($Web_Response.StatusCode) for serial $SerialNumber" "ERROR"
        return @{ Status = "HTTP Error $($Web_Response.StatusCode)"; Start = ""; End = "" }
    }
}

# Authentication (Managed Identity)
Write-Log "Authenticating with Azure Managed Identity" "INFO"
try {
    $url = $env:IDENTITY_ENDPOINT
    $headers = @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER; "Metadata" = "True" }
    $body = @{ resource = 'https://graph.microsoft.com/' }
    $accessToken = (Invoke-RestMethod $url -Method 'POST' -Headers $headers -ContentType 'application/x-www-form-urlencoded' -Body $body).access_token
    $script:Headers = @{ 'Authorization' = "Bearer $accessToken" }
    Write-Log "Authentication successful" "INFO"
} catch {
    Write-Log "Authentication failed: $_" "ERROR"
    exit 1
}

# Graph API paged GET
Function Invoke-MyGraphGetRequest {
    Param ($URL)
    Write-Log "Graph API request: $URL" "DEBUG"
    $AllResults = @()
    do {
        $ResponseData = Invoke-RestMethod -Uri $URL -Method GET -Headers $script:Headers -TimeoutSec 30
        $AllResults += $ResponseData.value
        $URL = $ResponseData.'@odata.nextLink'
        if ($URL) { Start-Sleep -Milliseconds 200 }
    } while ($URL)
    Write-Log "Graph API completed: $($AllResults.Count) total items" "INFO"
    return $AllResults
}

# Fetch Lenovo Windows device IDs only (avoids a known list-vs-detail notes inconsistency)
Write-Log "Fetching Lenovo Windows device IDs from Intune" "INFO"
$Devices_URL = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=contains(operatingSystem,'Windows') and manufacturer eq 'lenovo'&`$select=id"
$Lenovo_DeviceIds = Invoke-MyGraphGetRequest -URL $Devices_URL

if ($Lenovo_DeviceIds.Count -eq 0) {
    Write-Log "No Lenovo Windows devices found - exiting" "WARN"
    exit 0
}
Write-Log "Found $($Lenovo_DeviceIds.Count) Lenovo Windows devices to process" "INFO"

$Results = @()
$processed = 0
$successCount = 0
$failureCount = 0

foreach ($DeviceId in $Lenovo_DeviceIds) {
    $processed++
    $progress = [math]::Round(($processed / $Lenovo_DeviceIds.Count) * 100, 1)
    Write-Log "PROCESSING $processed/$($Lenovo_DeviceIds.Count) ($progress%): Getting device $($DeviceId.id)" "INFO"

    # Individual query with $select for accurate notes
    $Device = Get-DeviceWithAccurateNotes -DeviceId $DeviceId.id
    if (-not $Device) {
        Write-Log "SKIPPING device $($DeviceId.id) - could not retrieve details" "WARN"
        continue
    }

    Write-Log "DEVICE DETAILS: Name=$($Device.deviceName), Serial=$($Device.serialNumber)" "INFO"
    Write-Log "EXISTING NOTES: $($Device.notes)" "DEBUG"

    $WarrantyInfo = Get-LenovoWarranty -SerialNumber $Device.serialNumber -DeviceName $Device.deviceName

    if ($WarrantyInfo.Status -notin @("Unknown", "API Error", "Page Error", "No Device ID", "No Serial")) {
        $successCount++
    } else {
        $failureCount++
    }

    $hasExistingModel         = if ($Device.notes) { $Device.notes -match "Model\s*=" } else { $false }
    $hasExistingWarrantyStart = if ($Device.notes) { $Device.notes -match "WarrantyStartDate\s*=" } else { $false }
    $hasExistingWarrantyEnd   = if ($Device.notes) { $Device.notes -match "WarrantyEndDate\s*=" } else { $false }

    $currentModel         = if ($Device.notes -match "Model\s*=\s*(.+)") { $matches[1].Trim() } else { "Not Found" }
    $currentWarrantyStart = if ($Device.notes -match "WarrantyStartDate\s*=\s*(.+)") { $matches[1].Trim() } else { "Not Found" }
    $currentWarrantyEnd   = if ($Device.notes -match "WarrantyEndDate\s*=\s*(.+)") { $matches[1].Trim() } else { "Not Found" }

    $proposedAction = "No Change"
    if (!$hasExistingWarrantyStart -and $WarrantyInfo.Start) { $proposedAction = "Add WarrantyStartDate" }
    if (!$hasExistingWarrantyEnd -and $WarrantyInfo.End) {
        $proposedAction = if ($proposedAction -eq "No Change") { "Add WarrantyEndDate" } else { "$proposedAction + WarrantyEndDate" }
    }

    $Results += [PSCustomObject]@{
        DeviceName           = $Device.deviceName
        SerialNumber         = $Device.serialNumber
        RawExistingNotes     = $Device.notes
        CurrentModel         = $currentModel
        CurrentWarrantyStart = $currentWarrantyStart
        CurrentWarrantyEnd   = $currentWarrantyEnd
        NewWarrantyStatus    = $WarrantyInfo.Status
        NewWarrantyStartDate = $WarrantyInfo.Start
        NewWarrantyEndDate   = $WarrantyInfo.End
        HasModel             = $hasExistingModel
        HasWarrantyStart     = $hasExistingWarrantyStart
        HasWarrantyEnd       = $hasExistingWarrantyEnd
        ProposedAction       = $proposedAction
    }

    # WRITE step — only in update mode. This is the one place the project writes to Intune.
    if (-not $ReportOnly) {
        Write-Log "UPDATE: Surgically adding warranty fields for '$($Device.deviceName)'" "DEBUG"
        $updateResult = Add-WarrantyFieldsSurgically -ExistingNotes $Device.notes -WarrantyInfo $WarrantyInfo
        if ($updateResult.ChangesMade) {
            try {
                $patchUri  = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($Device.id)"
                $patchBody = @{ notes = $updateResult.Notes } | ConvertTo-Json
                Invoke-RestMethod -Uri $patchUri -Headers $script:Headers -Method PATCH -Body $patchBody -ContentType "application/json" -TimeoutSec 30
                Write-Log "UPDATE SUCCESS: appended warranty data to '$($Device.deviceName)' - existing content preserved" "INFO"
            } catch {
                Write-Log "FAILED to update notes for '$($Device.deviceName)': $_" "ERROR"
            }
        } else {
            Write-Log "NO UPDATE NEEDED: warranty fields already present for '$($Device.deviceName)'" "DEBUG"
        }
    } else {
        Write-Log "REPORT-ONLY MODE: Skipping notes update for '$($Device.deviceName)'" "DEBUG"
    }

    Start-Sleep -Seconds 2   # rate limiting (be a good citizen to the warranty endpoint)

    if ($processed % $BatchSize -eq 0) {
        $successRate = [math]::Round(($successCount / $processed) * 100, 1)
        Write-Log "Progress: $processed/$($Lenovo_DeviceIds.Count) processed, $successCount successful ($successRate%)" "INFO"
    }
}

$successRate = [math]::Round(($successCount / [math]::Max($processed,1)) * 100, 1)
$mode = if ($ReportOnly) { "REPORT-ONLY" } else { "UPDATE" }

Write-Log "=============== FINAL STATISTICS ===============" "INFO"
Write-Log "EXECUTION MODE: $mode" "INFO"
Write-Log "Total devices processed: $processed" "INFO"
Write-Log "Successful warranty lookups: $successCount ($successRate%)" "INFO"
Write-Log "Failed warranty lookups: $failureCount" "INFO"
if ($ReportOnly) {
    Write-Log "NO DEVICE NOTES WERE MODIFIED (Report-only mode)" "INFO"
} else {
    Write-Log "UPDATE COMPLETE - existing Notes content (including Model= fields) preserved" "INFO"
}
Write-Log "===============================================" "INFO"

# Export CSV
Write-Log "Exporting warranty data to CSV" "INFO"
$OutputFilePath = Join-Path -Path $ExportLocation -ChildPath $OutputFileName
if (!(Test-Path $ExportLocation)) { New-Item $ExportLocation -ItemType Directory | Out-Null }
$Results | Export-Csv -Path $OutputFilePath -NoTypeInformation
Write-Log "CSV exported: $OutputFilePath ($($Results.Count) records)" "INFO"

# Upload to Azure Blob
Write-Log "Uploading to Azure Blob Storage" "INFO"
try {
    $storageContext = (Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $StorageAccount).Context
    Set-AzStorageBlobContent -File $OutputFilePath -Container $Container -Blob (Split-Path -Leaf $OutputFilePath) -Context $storageContext -Force
    Write-Log "Azure Blob upload successful" "INFO"
    Remove-Item -Path $OutputFilePath -Force
} catch {
    Write-Log "Azure Blob upload failed: $_" "WARN"
    Write-Log "CSV file remains at: $OutputFilePath" "INFO"
}

Write-Log "Script execution completed in $mode MODE" "INFO"
