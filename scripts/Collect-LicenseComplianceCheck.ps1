#requires -Version 7.0
<#
.SYNOPSIS
    Collect-LicenseComplianceCheck.ps1 — finds corporate Windows devices whose primary user
    is missing an Intune and/or Windows Enterprise license. Read-only, Managed-Identity.

.DESCRIPTION
    Pulls Windows corporate managed devices with a primary user, checks each distinct user
    once (cached) for the required license SKUs, and reports the devices whose user is
    missing either. Resolves friendly product names from a Microsoft SKU->name mapping CSV
    you keep in the container. Writes the report to root/ (Power BI) and a size-gated copy to
    agent-data/. Read-only throughout — nothing is written to the tenant.

.NOTES
    GENERIC / PARAMETERIZED: no resource group, storage account, or container is hardcoded.
    Run against a personal lab tenant only.

    The License_Details.csv mapping is Microsoft's public "Product names and service plan
    identifiers for licensing" reference (String_Id -> Product_Display_Name). Upload it to
    your container; a missing mapping degrades to raw SKU names, never breaks the report.

    BETA ENDPOINT: managed devices use /beta; users/licenses use /v1.0. Re-verify after
    Graph updates.

    Read-only Graph app roles on the Managed Identity:
      DeviceManagementManagedDevices.Read.All   (managed devices)
      User.Read.All, Directory.Read.All         (user detail, manager, licenseDetails)
    Plus "Storage Blob Data Contributor" on the storage account.

    MIT licensed. Microsoft, Intune, Entra, Microsoft Graph and Azure are trademarks of the
    Microsoft group of companies. Independent content; not endorsed by Microsoft.
#>

# ===========================================================================
#  CONFIGURE ME  ->  set these to your own values, then run.
#  These three lines are the only thing you MUST change.
# ===========================================================================
$ResourceGroup  = "<your-resource-group-name>"     # resource group that holds your storage account
$StorageAccount = "<your-storage-account-name>"    # storage account name (lowercase, globally unique)
$Container      = "<your-container-name>"           # blob container, e.g. "intune-report"

# -- optional settings (safe to leave as they are) --------------------------
# Device-name prefixes to exclude (shared / non-user devices).
$ExcludedDevices = @("AP-", "CPC-", "AVD-", "WVD-", "MTR-VC")
# SKU part numbers that count as an Intune / Windows Enterprise entitlement.
$IntuneSKUs             = @("EMSPREMIUM", "SPE_F1", "SPE_E3", "SPE_E5", "SPE_F3", "INTUNE_O365")
$WindowsEnterpriseSKUs  = @("SPE_E3", "SPE_E5", "SPE_F1", "SPE_F3", "WIN10_VDA_E3", "WIN10_VDA_E5", "ENTERPRISEPACK", "ENTERPRISEPREMIUM")
# ===========================================================================

# Safety net - stop if the placeholders above weren't replaced.
if ("$ResourceGroup $StorageAccount $Container" -match '<your-') {
    throw "Please set ResourceGroup, StorageAccount, and Container at the top of the script before running."
}

# --- Step 1: Initialize Variables
$ExportLocation  = "$env:TEMP"
$BlobFileName    = "License_Details.csv"   # the Microsoft SKU->name mapping, kept in the container
$BlobPath        = "License_Details.csv"
$OutputFileName  = "License_Compliance.csv"
$MaxAgentFileMB  = 12
$ProgressPreference = 'SilentlyContinue'
$VerbosePreference  = 'Continue'

# --- Step 2: Graph GET helper with pagination
Function Invoke-MyGraphGetRequest {
    Param ($URL)
    Write-Verbose "GET $URL"
    $AllResults = @()
    try {
        Do {
            $WebRequest = Invoke-WebRequest -Uri $URL -Method GET -Headers $script:Headers -UseBasicParsing
            $ResponseData = ($WebRequest.Content | ConvertFrom-Json)
            if ($null -ne $ResponseData.value) { $AllResults += $ResponseData.value }
            elseif ($null -ne $ResponseData)   { $AllResults += $ResponseData }
            $URL = $ResponseData.'@odata.nextLink'
        } While ($URL)
        Return $AllResults
    } catch {
        Write-Warning "Failed to fetch data from ${URL}: $_"
        return $null
    }
}

# --- Step 3: Authenticate with Azure Managed Identity (Graph token)
$url = $env:IDENTITY_ENDPOINT
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("X-IDENTITY-HEADER", $env:IDENTITY_HEADER)
$headers.Add("Metadata", "True")
$body = @{ resource = 'https://graph.microsoft.com/' }

Write-Verbose "Obtaining access token"
$accessToken = (Invoke-RestMethod $url -Method 'POST' -Headers $headers -ContentType 'application/x-www-form-urlencoded' -Body $body).access_token
if (-not $accessToken) { Write-Error "Token acquisition returned null."; return }
$script:Headers = @{ 'Authorization' = "Bearer $accessToken" }
Write-Verbose "Access token obtained successfully"

# --- Step 4: Authenticate with Azure Blob Storage
Write-Verbose "Authenticating with Azure Blob Storage..."
try {
    $null = Connect-AzAccount -Identity -ErrorAction Stop
    $StorageAccountContext = (Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $StorageAccount).Context
    Write-Verbose "Authenticated with Azure Blob Storage successfully."
} catch {
    Write-Error "Failed to authenticate with Azure Blob Storage: $_"
    return
}

# --- Step 5: Download license mapping file
Write-Verbose "Downloading blob '$BlobPath'..."
try {
    if (!(Test-Path $ExportLocation)) { New-Item $ExportLocation -ItemType Directory | Out-Null }
    $LocalFilePath = Join-Path -Path $ExportLocation -ChildPath $BlobFileName
    Get-AzStorageBlobContent -Container $Container -Blob $BlobPath -Destination $LocalFilePath -Context $StorageAccountContext -Force
    Write-Verbose "Blob downloaded to '$LocalFilePath'."
} catch {
    Write-Error "Failed to download blob '$BlobPath': $_"
    return
}

# --- Step 6: Parse license mapping into hash table
Write-Verbose "Parsing license mapping CSV..."
try {
    $LicenseMapping = @{}
    Import-Csv -Path $LocalFilePath | ForEach-Object {
        $stringIdValue = $null; $displayNameValue = $null
        foreach ($prop in $_.PSObject.Properties) {
            if ($prop.Name -match 'String_Id')            { $stringIdValue    = $prop.Value.Trim() }
            if ($prop.Name -match 'Product_Display_Name') { $displayNameValue = $prop.Value.Trim() }
        }
        if ($stringIdValue -and $displayNameValue -and -not $LicenseMapping.ContainsKey($stringIdValue)) {
            $LicenseMapping[$stringIdValue] = $displayNameValue
        }
    }
    Write-Verbose "License mappings loaded: $(($LicenseMapping.Keys).Count)"
} catch {
    Write-Error "Failed to parse license mapping CSV: $_"
    return
}

# --- Step 7: Fetch all Windows corporate devices with a primary user
Write-Verbose "Querying managed devices..."
$DevicesURI = "https://graph.microsoft.com/beta/deviceManagement/managedDevices" +
    "?`$filter=operatingSystem eq 'Windows' and managedDeviceOwnerType eq 'company'" +
    "&`$select=id,deviceName,userPrincipalName,userId,lastSyncDateTime&`$top=1000"
$Devices = Invoke-MyGraphGetRequest -URL $DevicesURI

if (-not $Devices) { Write-Error "Failed to fetch devices."; return }

$Devices = @($Devices | Where-Object { -not [string]::IsNullOrEmpty($_.userPrincipalName) })
Write-Verbose "Devices with primary user: $($Devices.Count)"

# --- Step 8: Per-user caches (each user checked once, regardless of device count)
$script:UserDetailCache  = @{}   # userId -> user object (or $null)
$script:UserLicenseCache = @{}   # userId -> array of SkuPartNumbers

Function Get-UserDetailCached {
    Param ([string]$UserId)
    if ($script:UserDetailCache.ContainsKey($UserId)) { return $script:UserDetailCache[$UserId] }

    $URI = "https://graph.microsoft.com/v1.0/users/$UserId" +
        "?`$select=id,userPrincipalName,employeeType,city,country&`$expand=manager(`$select=mail,department,officeLocation)"
    $Result = Invoke-MyGraphGetRequest -URL $URI
    $User = if ($Result -and $Result.Count -gt 0) { $Result[0] } else { $null }
    $script:UserDetailCache[$UserId] = $User
    return $User
}

Function Get-UserLicensesCached {
    Param ([string]$UserId)
    if ($script:UserLicenseCache.ContainsKey($UserId)) { return $script:UserLicenseCache[$UserId] }

    $URI = "https://graph.microsoft.com/v1.0/users/$UserId/licenseDetails?`$select=skuPartNumber"
    $Result = Invoke-MyGraphGetRequest -URL $URI
    $Skus = if ($Result) { @($Result | Select-Object -ExpandProperty skuPartNumber) } else { @() }
    $script:UserLicenseCache[$UserId] = $Skus
    return $Skus
}

# --- Step 9: Process each device
$FinalReport = @()
$deviceCounter = 0

foreach ($device in $Devices) {
    $deviceCounter++
    $DeviceName = $device.deviceName

    if ($ExcludedDevices | Where-Object { $DeviceName -like "$_*" }) {
        Write-Verbose "Skipping excluded device: $DeviceName"
        continue
    }

    # userId comes directly from the managedDevice - no separate primary-user call needed
    $UserId = $device.userId
    if ([string]::IsNullOrEmpty($UserId)) {
        Write-Warning "No primary user id for device: '$DeviceName'"
        continue
    }

    try {
        $UserDetails = Get-UserDetailCached -UserId $UserId
        if (-not $UserDetails) {
            Write-Warning "Could not resolve user for device '$DeviceName' (userId: $UserId)"
            continue
        }

        $EmpType = [string]$UserDetails.employeeType
        if ($EmpType -in @("Common", "System", "system", "Partner", "Employee", "")) {

            $Skus = Get-UserLicensesCached -UserId $UserId
            $hasIntune            = @($Skus | Where-Object { $IntuneSKUs -contains $_ }).Count -gt 0
            $hasWindowsEnterprise = @($Skus | Where-Object { $WindowsEnterpriseSKUs -contains $_ }).Count -gt 0

            if (-not $hasIntune -or -not $hasWindowsEnterprise) {
                $FriendlyLicenses = @()
                foreach ($sku in $Skus) {
                    if ($LicenseMapping.ContainsKey($sku)) { $FriendlyLicenses += $LicenseMapping[$sku] }
                    else { $FriendlyLicenses += $sku }
                }

                $LicenseStatus = @()
                if (-not $hasIntune)            { $LicenseStatus += "MISSING: Intune license" }
                if (-not $hasWindowsEnterprise) { $LicenseStatus += "MISSING: Windows 10/11 Enterprise license" }

                $AssignedLicensesFriendly = if ($FriendlyLicenses.Count -gt 0) {
                    ($FriendlyLicenses -join ", ") + " | " + ($LicenseStatus -join " | ")
                } else {
                    "No Licenses Assigned | " + ($LicenseStatus -join " | ")
                }

                $Mgr = $UserDetails.manager
                $FinalReport += [PSCustomObject]@{
                    DeviceName            = $DeviceName
                    PrimaryUserEmail      = $UserDetails.userPrincipalName
                    ManagerEmail          = if ($Mgr -and $Mgr.mail)           { $Mgr.mail }           else { "No Manager" }
                    ManagerDepartment     = if ($Mgr -and $Mgr.department)     { $Mgr.department }     else { "Unknown" }
                    ManagerOfficeLocation = if ($Mgr -and $Mgr.officeLocation) { $Mgr.officeLocation } else { "Unknown" }
                    City                  = if ($UserDetails.city)    { $UserDetails.city }    else { "Unknown" }
                    Country               = if ($UserDetails.country) { $UserDetails.country } else { "Unknown" }
                    AssignedLicenses      = $AssignedLicensesFriendly
                    LastIntuneSync        = $device.lastSyncDateTime
                }
            }
        }
    } catch {
        Write-Warning "Error processing device '$DeviceName': $_"
    }

    if ($deviceCounter % 1000 -eq 0) {
        Write-Verbose "Progress: $deviceCounter/$($Devices.Count) devices"
    }
}

# --- Step 10: Summary logging
if ($FinalReport.Count -eq 0) {
    Write-Verbose "All users have BOTH required licenses. No compliance issues found."
} else {
    Write-Verbose "Found $($FinalReport.Count) devices whose users are missing one or both licenses."
}

# --- Step 11: Export CSV (explicit all-clear row when report is empty)
$OutputFilePath = Join-Path -Path $ExportLocation -ChildPath $OutputFileName
if (!(Test-Path $ExportLocation)) { New-Item $ExportLocation -ItemType Directory | Out-Null }

if ($FinalReport.Count -eq 0) {
    $FinalReport = @([PSCustomObject]@{
        DeviceName            = 'NONE'
        PrimaryUserEmail      = 'N/A'
        ManagerEmail          = 'N/A'
        ManagerDepartment     = 'N/A'
        ManagerOfficeLocation = 'N/A'
        City                  = 'N/A'
        Country               = 'N/A'
        AssignedLicenses      = "ALL CLEAR - every checked user has both Intune and Windows Enterprise licenses as of $(Get-Date -Format 'yyyy-MM-dd')"
        LastIntuneSync        = 'N/A'
    })
}

$FinalReport | Export-Csv -Path $OutputFilePath -NoTypeInformation -Force
Write-Verbose "Report exported to '$OutputFilePath'."

# --- Step 12: Upload - root (Power BI) + agent-data (AI Search)
Write-Verbose "Uploading CSV to Azure Blob Storage..."
try {
    Set-AzStorageBlobContent -File $OutputFilePath -Container $Container `
        -Blob $OutputFileName -Context $StorageAccountContext -Force | Out-Null
    Write-Verbose "Root copy uploaded: $OutputFileName"

    $mb = [math]::Round((Get-Item $OutputFilePath).Length / 1MB, 2)
    if ($mb -le $MaxAgentFileMB) {
        Set-AzStorageBlobContent -File $OutputFilePath -Container $Container `
            -Blob "agent-data/$OutputFileName" -Context $StorageAccountContext -Force | Out-Null
        Write-Verbose "Agent copy uploaded: agent-data/$OutputFileName ($mb MB)"
    }
    else { Write-Warning "$OutputFileName is $mb MB - skipped agent copy." }
} catch {
    Write-Warning "Failed to upload CSV to Azure Blob Storage: $_"
}

Write-Verbose "Script completed successfully."
