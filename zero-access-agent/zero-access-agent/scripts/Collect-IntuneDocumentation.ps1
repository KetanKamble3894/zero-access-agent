#requires -Version 7.0
<#
.SYNOPSIS
    Collect-IntuneDocumentation.ps1 — generates human-readable Intune / Windows 365
    documentation as HTML and uploads it to Blob for the pattern's document index.

.DESCRIPTION
    An Azure Automation runbook that signs in as the system-assigned Managed Identity,
    injects that read-only Graph token into the community M365Documentation module, collects
    the Intune + Windows 365 configuration section by section (refreshing the token as it
    goes), renders one merged HTML document, and uploads it to the storage account's
    `reports/` container.

    In the Zero-Access Pattern this feeds the *documentation* index (the `euc-documents`
    side of Azure AI Search) — the prose the agent cites, separate from the structured CSV
    snapshots. It reads configuration only; it never writes to the tenant.

.NOTES
    GENERIC / PARAMETERIZED: no organisation name, storage account, or container is
    hardcoded — pass them in. Run against a personal lab tenant only.

    DEPENDENCIES (community — thank you!): this runbook is built around the excellent
    M365Documentation module by Thomas Kurth:
        https://github.com/ThomasKur/M365Documentation
    plus its dependencies MSAL.PS, PSWriteOffice, and PSHTML. Install these into the
    Automation Account from the PowerShell Gallery before running.

    LICENSE NOTE: M365Documentation is licensed GPL-3.0. This runbook only *calls* it at
    runtime (you install it yourself); it does not copy or redistribute the module's code,
    so this script remains MIT. Do NOT vendor the module's source into this repo — link to
    it and install from PSGallery instead.

    Read-only Graph app roles on the Managed Identity (the scopes M365Documentation's
    Intune/Windows365 collectors need — verify against the module's docs for your version):
      DeviceManagementConfiguration.Read.All
      DeviceManagementApps.Read.All
      DeviceManagementManagedDevices.Read.All
      Organization.Read.All          (the connectivity self-test hits GET /organization)
      Directory.Read.All
    Plus "Storage Blob Data Contributor" on the storage account (to upload the HTML).

    MIT licensed. Microsoft, Intune, Entra, Microsoft Graph, Azure and Windows 365 are
    trademarks of the Microsoft group of companies. Independent content; not endorsed by
    Microsoft. Verify permissions and section behavior in your own lab tenant before relying
    on it.
#>

# ===========================================================================
#  CONFIGURE ME  ->  set these to your own values, then run.
#  These two lines are the only thing you MUST change.
# ===========================================================================
$StorageAccount = "<your-storage-account-name>"    # storage account name (lowercase, globally unique)
$Container      = "<your-container-name>"           # blob container, e.g. "intune-report"

# -- optional settings (safe to leave as they are) --------------------------
$OrgName              = 'Contoso'                    # only used to name the output HTML file
$ComponentsToDoc      = @('Intune','Windows365')     # which M365Documentation components to collect
$ExcludeSectionTokens = @('MdmConfigurationPolicy')  # section tokens to skip (see teardown re: substring matching)
$TokenMinValidMinutes = 15                           # refresh the MI token when fewer minutes remain
# ===========================================================================

# Safety net - stop if the placeholders above weren't replaced.
if ("$StorageAccount $Container" -match '<your-') {
    throw "Please set StorageAccount and Container at the top of the script before running."
}

#-- Step 1 - Initialize Variables
$ExportLocation     = "$env:TEMP"
$GraphBaseUrl       = "https://graph.microsoft.com/"   # Commercial cloud
$ProgressPreference = 'SilentlyContinue'
$VerbosePreference  = 'Continue'

$OutputFileName  = "$($OrgName)_Intune_Documentation_$(Get-Date -Format 'ddMMyyyy').html"
$LocalOutputPath = Join-Path -Path $ExportLocation -ChildPath $OutputFileName
$OutputBlobName  = "reports/$OutputFileName"

#-- Helper functions -----------------------------------------------------------

function Get-MiGraphToken {
    param([Parameter(Mandatory)][string]$ResourceUrl)
    $resp = Get-AzAccessToken -ResourceUrl $ResourceUrl -ErrorAction Stop
    if ($resp.Token -is [System.Security.SecureString]) {          # Az.Accounts 5.x default
        $plain = [System.Net.NetworkCredential]::new('', $resp.Token).Password
    } else {
        $plain = $resp.Token
    }
    if ([string]::IsNullOrWhiteSpace($plain)) { throw "Received an empty Graph access token." }
    [pscustomobject]@{
        AccessToken  = $plain
        ExpiresOn    = [System.DateTimeOffset]$resp.ExpiresOn
        ForceRefresh = $false
    }
}

function Set-M365DocToken {
    param(
        [Parameter(Mandatory)]$Module,
        [Parameter(Mandatory)]$Token,
        [Parameter(Mandatory)][string]$BaseUrl
    )
    & $Module {
        param($t, $b)
        $script:token                    = $t
        $script:tokenRequest             = $null
        $script:M365Doc_GraphBase        = $b
        $script:M365Doc_CloudEnvironment = 'Commercial'
    } $Token $BaseUrl
}

function Update-M365DocTokenIfNeeded {
    param(
        [Parameter(Mandatory)]$Module,
        [Parameter(Mandatory)][ref]$TokenRef,
        [Parameter(Mandatory)][string]$ResourceUrl,
        [int]$MinValidMinutes = 15
    )
    $remaining = ($TokenRef.Value.ExpiresOn.LocalDateTime - (Get-Date)).TotalMinutes
    if ($remaining -lt $MinValidMinutes) {
        Write-Verbose ("Token has {0:N1} min left - refreshing via Managed Identity" -f $remaining)
        $new = Get-MiGraphToken -ResourceUrl $ResourceUrl
        Set-M365DocToken -Module $Module -Token $new -BaseUrl $ResourceUrl
        $TokenRef.Value = $new
    }
}

#-- Step 2 - Authenticate to Azure with the Managed Identity
Write-Verbose "Connecting to Azure with Managed Identity"
try {
    Connect-AzAccount -Identity | Out-Null
    Write-Verbose "Azure authentication successful"
}
catch { Write-Error "Failed to authenticate to Azure using Managed Identity: $_"; return }

#-- Step 3 - Acquire the initial Microsoft Graph token via the Managed Identity
Write-Verbose "Acquiring initial Microsoft Graph token via Managed Identity"
try {
    $CurrentToken = Get-MiGraphToken -ResourceUrl $GraphBaseUrl
    Write-Verbose "Graph token acquired. Expires: $($CurrentToken.ExpiresOn.LocalDateTime)"
}
catch { Write-Error "Failed to acquire Microsoft Graph token: $_"; return }

#-- Step 4 - Build Storage context (data-plane OAuth via the same identity)
Write-Verbose "Building storage context with connected account"
try {
    $StorageAccountContext = New-AzStorageContext -StorageAccountName $StorageAccount -UseConnectedAccount -ErrorAction Stop
    Write-Verbose "Storage context created successfully"
}
catch { Write-Error "Failed to create storage context: $_"; return }

#-- Step 5 - Import M365Documentation (also loads MSAL.PS + PSWriteOffice)
Write-Verbose "Importing M365Documentation module"
try {
    Import-Module M365Documentation -ErrorAction Stop
    Import-Module PSHTML -ErrorAction Stop
    $M365Module = Get-Module -Name M365Documentation | Select-Object -First 1
    if (-not $M365Module) { throw "M365Documentation module object not found after import." }
}
catch { Write-Error "Failed to import M365Documentation (need MSAL.PS + PSWriteOffice installed): $_"; return }

#-- Step 6 - Inject the initial token into the module session state
Write-Verbose "Injecting Graph token into M365Documentation session state"
try {
    Set-M365DocToken -Module $M365Module -Token $CurrentToken -BaseUrl $GraphBaseUrl
}
catch { Write-Error "Failed to inject Graph token into module: $_"; return }

#-- Step 6b - Read-only connectivity self-test (fail fast before collecting)
#   Test-M365DocConnection issues a single GET /organization using the injected
#   token. If the injection didn't take, this throws here with a clear message
#   instead of failing deep inside the collection loop.
Write-Verbose "Validating Graph connectivity (read-only GET /organization)"
try {
    $conn = Test-M365DocConnection
    Write-Verbose "Connected to tenant '$($conn.OrganizationName)' - token valid until $($conn.TokenExpires)"
}
catch {
    Write-Error "Connectivity self-test failed - token injection or Graph permissions issue: $_"
    return
}

#-- Step 7 - Choose components + optional per-token skips
# Skip specific collectors by exact token (leave empty to document everything).
# QUIRK: -IncludeSections is substring-matched, so you CANNOT drop 'MobileAppDetailed'
# while keeping the base 'MobileApp' - the base token pulls the whole MobileApp family.

#-- Step 8 - Resolve REAL section tokens straight from the module
Write-Verbose "Resolving section tokens for: $($ComponentsToDoc -join ', ')"
try {
    $ValidSections = Get-M365DocValidSection -Components $ComponentsToDoc
}
catch { Write-Error "Failed to retrieve valid sections: $_"; return }

$WorkItems = @($ValidSections | Where-Object { $_.SectionName -notin $ExcludeSectionTokens })

# Collapse substring-family collisions (e.g. MobileApp*) so nothing is collected twice:
# drop any token that CONTAINS another retained token as a substring.
$AllNames  = $WorkItems.SectionName
$WorkItems = @($WorkItems | Where-Object {
    $name = $_.SectionName
    -not ($AllNames | Where-Object { $_ -ne $name -and $name.Contains($_) })
})

if (-not $WorkItems) { Write-Error "No sections resolved for the chosen components."; return }
Write-Verbose "Will collect $($WorkItems.Count) section(s): $(($WorkItems.SectionName) -join ', ')"

#-- Step 9 - Collect one section per call, refreshing the token before each
#   Single component per call keeps each returned [Doc] flat (no per-component wrapper),
#   so merging is a simple SubSections concatenation.
$MasterDoc = $null
foreach ($item in $WorkItems) {

    try {
        Update-M365DocTokenIfNeeded -Module $M365Module -TokenRef ([ref]$CurrentToken) `
            -ResourceUrl $GraphBaseUrl -MinValidMinutes $TokenMinValidMinutes
    }
    catch { Write-Error "Token refresh failed before '$($item.SectionName)': $_"; return }

    Write-Verbose "Collecting [$($item.Component)] $($item.SectionName)"
    try {
        $BatchDoc = Get-M365Doc -Components $item.Component -IncludeSections $item.SectionName
    }
    catch { Write-Error "Failed collecting '$($item.SectionName)': $_"; return }

    if (-not $BatchDoc -or -not $BatchDoc.SubSections) {
        Write-Warning "No data for '$($item.SectionName)' - skipping."
        continue
    }

    if ($null -eq $MasterDoc) { $MasterDoc = $BatchDoc }
    else { $MasterDoc.SubSections += $BatchDoc.SubSections }
}

if (-not $MasterDoc -or -not $MasterDoc.SubSections) {
    Write-Error "No documentation data collected across all sections."
    return
}

# De-duplicate merged sections by Title (safety net) and fix the header component list
$MasterDoc.SubSections = @(
    $MasterDoc.SubSections | Where-Object { $_.Title } |
        Group-Object Title | ForEach-Object { $_.Group[0] }
)
$MasterDoc.Components = $ComponentsToDoc
Write-Verbose "Total sections in document: $($MasterDoc.SubSections.Count)"

#-- Step 10 - Remove existing local file if present
if (Test-Path -Path $LocalOutputPath) {
    Write-Verbose "Removing existing local output so the module uses its built-in template"
    Remove-Item -Path $LocalOutputPath -Force
}

#-- Step 11 - Generate HTML documentation from the merged Doc object
Write-Verbose "Generating HTML documentation '$LocalOutputPath'"
try {
    $MasterDoc | Write-M365DocHTML -FullDocumentationPath $LocalOutputPath
}
catch { Write-Error "Failed to generate HTML documentation: $_"; return }

if (-not (Test-Path $LocalOutputPath)) {
    Write-Error "Documentation file was not created: $LocalOutputPath"
    return
}

#-- Step 12 - Upload generated documentation to Azure Blob Storage
Write-Verbose "Uploading documentation to Azure Blob Storage"
try {
    Set-AzStorageBlobContent `
        -File $LocalOutputPath `
        -Container $Container `
        -Blob $OutputBlobName `
        -Context $StorageAccountContext `
        -Properties @{ ContentType = 'text/html' } `
        -Force | Out-Null
    Write-Verbose "Upload successful. Blob path: $OutputBlobName"
}
catch { Write-Error "Failed to upload documentation to Azure Blob Storage: $_"; return }

Write-Output "Documentation uploaded successfully to blob path: $OutputBlobName"
