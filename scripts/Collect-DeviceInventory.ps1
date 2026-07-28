#requires -Version 7.0
<#
.SYNOPSIS
    Collect-DeviceInventory.ps1 — a reference collector for the Zero-Access Pattern.
    Read-only, Managed-Identity, pre-aggregating. Generic example; adapt to your fleet.

.DESCRIPTION
    One of the "10 daily runbooks". It signs in as the Automation Account's Managed
    Identity, GETs managed devices read-only from Microsoft Graph, writes the full CSV to
    root/ (for Power BI) and a pre-aggregated stats CSV to agent-data/ (for the agent's
    index). It never writes to the tenant.

    This is a COMMODITY script — the shareable artifact is the design, not the code. It
    carries no tenant, storage, or identity values; everything real is a parameter.

.NOTES
    Runs inside Azure Automation (PowerShell 7.2 runtime) with:
      Microsoft.Graph.Authentication, Az.Accounts, Az.Storage
    and a system-assigned Managed Identity holding read-only Graph app roles
    (see docs/build-it-yourself.md).

    MIT licensed. Microsoft/Intune/Entra/Graph are trademarks of the Microsoft group of
    companies. Verify every endpoint in your own lab tenant before relying on it.
#>

# ===========================================================================
#  CONFIGURE ME  ->  set these to your own values, then run.
# ===========================================================================
$StorageAccount = "<your-storage-account-name>"   # storage account name (lowercase, globally unique)
$FullContainer  = "root"                          # container for full CSVs (Power BI)
$AgentContainer = "agent-data"                     # container for slim, pre-aggregated snapshots

# -- optional settings (safe to leave as they are) --------------------------
$MaxRows        = 200000                          # size-gate: refuse to write an unbounded snapshot
# ===========================================================================

# Safety net - stop if the placeholder above wasn't replaced.
if ("$StorageAccount" -match '<your-') {
    throw "Please set StorageAccount at the top of the script before running."
}

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ── Auth: Managed Identity only. No secrets. ─────────────────────────────────
Connect-MgGraph -Identity -NoWelcome
Connect-AzAccount -Identity | Out-Null
$ctx = New-AzStorageContext -StorageAccountName $StorageAccount -UseConnectedAccount

# ── Read-only GET with paging ────────────────────────────────────────────────
function Get-GraphCollection {
    param([Parameter(Mandatory)][string] $Uri)
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        # -OutputType PSObject so items are PSCustomObjects with real properties —
        # a hashtable's keys don't survive Select-Object / Export-Csv as columns.
        $page  = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        $props = $page.PSObject.Properties.Name
        if ($props -contains 'value' -and $page.value) { $page.value | ForEach-Object { $items.Add($_) } }
        $next = if ($props -contains '@odata.nextLink') { $page.'@odata.nextLink' } else { $null }
        if ($items.Count -gt $MaxRows) { throw "Size gate: collection exceeded $MaxRows rows." }
    }
    return $items
}

$devices = Get-GraphCollection -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices'
$stamp   = (Get-Date).ToString('yyyy-MM-dd')

# ── Full CSV → root/ (Power BI reads this) ───────────────────────────────────
$fullFile = "device_inventory_$stamp.csv"
$devices |
    Select-Object id, deviceName, serialNumber, manufacturer, model, operatingSystem,
                  osVersion, complianceState, managedDeviceOwnerType, userPrincipalName,
                  lastSyncDateTime, totalStorageSpaceInBytes, freeStorageSpaceInBytes |
    Export-Csv $fullFile -NoTypeInformation -Encoding utf8
Set-AzStorageBlobContent -File $fullFile -Container $FullContainer -Blob $fullFile -Context $ctx -Force

# ── Pre-aggregate → agent-data/ : the trust boundary. Count DEVICES, not rows. ─
$distinctIds = $devices | Select-Object -ExpandProperty id -Unique
$stats = [pscustomobject]@{
    generatedUtc        = (Get-Date).ToUniversalTime().ToString('o')
    distinctDevices     = $distinctIds.Count
    deviceRows          = $devices.Count
    nonCompliantDevices = ($devices | Where-Object { $_.complianceState -ne 'compliant' } |
                           Select-Object -ExpandProperty id -Unique).Count
    staleOver30Days     = ($devices | Where-Object {
                              $_.lastSyncDateTime -and
                              ([datetime]$_.lastSyncDateTime) -lt (Get-Date).AddDays(-30)
                          } | Select-Object -ExpandProperty id -Unique).Count
}
$statsFile = "device_inventory_stats_$stamp.csv"
$stats | Export-Csv $statsFile -NoTypeInformation -Encoding utf8
Set-AzStorageBlobContent -File $statsFile -Container $AgentContainer -Blob $statsFile -Context $ctx -Force

Write-Output "Collected $($stats.distinctDevices) devices ($($stats.deviceRows) rows). Snapshots written for $stamp."
