#requires -Version 7.0
<#
.SYNOPSIS
    New-SyntheticFleet.ps1 — generate a fake-but-realistic endpoint fleet as CSVs.
    Lets anyone run the Zero-Access Pattern with NO tenant at all: generate → index → ask.

.DESCRIPTION
    Produces the same CSV shapes the real collection layer emits — device inventory,
    compliance, app install failures, Autopilot events, licensing, OEM warranty, and
    Windows 11 hardware readiness — plus a pre-aggregated `_Stats` file, exactly like a
    runbook would. The data is invented; no real device, user, or tenant appears.

    It deliberately bakes in the messy realities that trip up naive reporting, so the
    pattern's "count devices, not rows" and "honest gaps" principles have something real
    to demonstrate:
      - the same device on multiple rows (duplicate sync records)
      - missing / empty values
      - reimaged machines (one serial, a new device id)
      - in-flight deployments (state = "pending")
      - camelCase stat keys

.EXAMPLE
    ./New-SyntheticFleet.ps1 -DeviceCount 500 -OutputPath ./sample-data

.NOTES
    Everything here is synthetic. Safe to publish, safe to run offline. MIT licensed.
    Microsoft, Intune, Entra are trademarks of the Microsoft group of companies.
#>

[CmdletBinding()]
param(
    [int]    $DeviceCount = 250,
    [string] $OutputPath  = './sample-data',
    [int]    $Seed        = 42
)

Set-StrictMode -Version Latest
$rand = [System.Random]::new($Seed)   # seeded → reproducible fleets

function Pick { param([object[]]$Items) $Items[$rand.Next(0, $Items.Count)] }
function Chance { param([int]$Percent) ($rand.Next(0,100) -lt $Percent) }

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$manufacturers = @('Contoso','Fabrikam','Northwind','AdventureWorks')   # fictional OEMs
$models        = @('Model A5','Model B7','Model C3','Model X1','Model Z9')
$osVersions    = @('10.0.19045.4291','10.0.22621.3593','10.0.22631.3737','10.0.22000.2960')
$owners        = @('company','personal','')                             # '' = missing on purpose
$firstNames    = @('alex','sam','jordan','riley','casey','morgan','taylor','jamie')
$compStates    = @('compliant','compliant','compliant','noncompliant','error','notApplicable')

# ── Build the base devices ───────────────────────────────────────────────────
$devices = for ($i = 1; $i -le $DeviceCount; $i++) {
    $serial = 'SN' + $rand.Next(100000, 999999)
    [pscustomobject]@{
        id               = [guid]::NewGuid().ToString()
        deviceName       = 'DESKTOP-' + $rand.Next(1000, 9999)
        serialNumber     = $serial
        manufacturer     = Pick $manufacturers
        model            = Pick $models
        osVersion        = Pick $osVersions
        ownerType        = Pick $owners
        primaryUser      = if (Chance 90) { (Pick $firstNames) + '@lab.example' } else { '' }  # gaps
        lastSyncDateTime = (Get-Date).AddDays(-1 * $rand.Next(0, 45)).ToString('o')
        totalStorageGB   = Pick @(128,256,256,512,1024)
        freeStorageGB    = $rand.Next(5, 400)
        totalRamGB       = Pick @(8,8,16,16,32)
    }
}

# ── Inject pathologies ───────────────────────────────────────────────────────
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($d in $devices) { $rows.Add($d) }

# duplicate sync rows: same device appears 2-3 times (tests count-devices-not-rows)
foreach ($d in ($devices | Where-Object { Chance 12 })) {
    foreach ($n in 1..$rand.Next(1,3)) {
        $dupe = $d.PSObject.Copy()
        $dupe.lastSyncDateTime = (Get-Date).AddDays(-1 * $rand.Next(0,45)).ToString('o')
        $rows.Add($dupe)
    }
}
# reimaged machines: same serial, brand-new device id
foreach ($d in ($devices | Where-Object { Chance 5 })) {
    $reimaged = $d.PSObject.Copy()
    $reimaged.id         = [guid]::NewGuid().ToString()
    $reimaged.deviceName = 'DESKTOP-' + $rand.Next(1000, 9999)
    $rows.Add($reimaged)
}

$rows | Sort-Object deviceName | Export-Csv (Join-Path $OutputPath 'devices.csv') -NoTypeInformation -Encoding utf8

# ── Compliance (one row per device per policy) ───────────────────────────────
$policies = @('Baseline Security','Disk Encryption','Minimum OS','Defender On')
$compliance = foreach ($d in $devices) {
    foreach ($p in $policies) {
        [pscustomobject]@{
            deviceId   = $d.id
            deviceName = $d.deviceName
            policyName = $p
            state      = Pick $compStates
        }
    }
}
$compliance | Export-Csv (Join-Path $OutputPath 'compliance.csv') -NoTypeInformation -Encoding utf8

# ── App install failures (deployment & lifecycle) ────────────────────────────
$apps       = @('LOB CRM','PDF Reader','VPN Client','Chat App','Design Suite')
$intents    = @('required','available')
$installSt  = @('installed','failed','pending','pending','unknown')   # 'pending' = in-flight
$errorCodes = @('0x87D1041C','0x80070005','0x87D13B9F','')
$appFailures = foreach ($d in $devices) {
    foreach ($a in ($apps | Where-Object { Chance 40 })) {
        $state = Pick $installSt
        [pscustomobject]@{
            deviceId    = $d.id
            appName     = $a
            intent      = Pick $intents
            installState= $state
            errorCode   = if ($state -eq 'failed') { Pick $errorCodes } else { '' }
        }
    }
}
$appFailures | Export-Csv (Join-Path $OutputPath 'app_failures.csv') -NoTypeInformation -Encoding utf8

# ── Autopilot events ─────────────────────────────────────────────────────────
$enrollStates = @('enrolled','enrolled','inProgress','failed')
$autopilot = foreach ($d in ($devices | Where-Object { Chance 60 })) {
    [pscustomobject]@{
        serialNumber      = $d.serialNumber
        profileName       = Pick @('Standard Autopilot','Kiosk','Developer')
        enrollmentState   = Pick $enrollStates
        lastEventDateTime = (Get-Date).AddDays(-1 * $rand.Next(0,90)).ToString('o')
    }
}
$autopilot | Export-Csv (Join-Path $OutputPath 'autopilot.csv') -NoTypeInformation -Encoding utf8

# ── Licensing & catalog ──────────────────────────────────────────────────────
$skus = @('E3','E5','F3','BusinessPremium')
$licenses = foreach ($d in ($devices | Where-Object { $_.primaryUser })) {
    [pscustomobject]@{
        userPrincipalName = $d.primaryUser
        licenseSku        = Pick $skus
        assignedDateTime  = (Get-Date).AddDays(-1 * $rand.Next(30,900)).ToString('yyyy-MM-dd')
    }
}
$licenses | Sort-Object userPrincipalName -Unique |
    Export-Csv (Join-Path $OutputPath 'licenses.csv') -NoTypeInformation -Encoding utf8

# ── OEM warranty (external) ──────────────────────────────────────────────────
$warranty = foreach ($d in $devices) {
    [pscustomobject]@{
        serialNumber = $d.serialNumber
        provider     = 'OEM'
        warrantyEnd  = if (Chance 85) { (Get-Date).AddDays($rand.Next(-200, 1000)).ToString('yyyy-MM-dd') } else { '' }
    }
}
$warranty | Sort-Object serialNumber -Unique |
    Export-Csv (Join-Path $OutputPath 'warranty.csv') -NoTypeInformation -Encoding utf8

# ── Windows 11 hardware readiness ────────────────────────────────────────────
$win11 = foreach ($d in $devices) {
    $tpm       = Pick @('2.0','2.0','2.0','1.2','')
    $secure    = Chance 80
    $cpuOk     = Chance 75
    $ramOk     = $d.totalRamGB -ge 8
    $capable   = ($tpm -eq '2.0') -and $secure -and $cpuOk -and $ramOk
    [pscustomobject]@{
        deviceId        = $d.id
        deviceName      = $d.deviceName
        tpmVersion      = $tpm
        secureBoot      = $secure
        cpuCompatible   = $cpuOk
        ramGB           = $d.totalRamGB
        storageGB       = $d.totalStorageGB
        overallReadiness= if ($capable) { 'Capable' } elseif ($tpm -eq '') { 'Unknown' } else { 'NotCapable' }
    }
}
$win11 | Export-Csv (Join-Path $OutputPath 'win11_readiness.csv') -NoTypeInformation -Encoding utf8

# ── Pre-aggregated _Stats (what the agent-data/ snapshot would carry) ─────────
# Note the camelCase keys — matches how real stat blobs are shaped.
$distinctDevices = ($devices | Select-Object -ExpandProperty id -Unique).Count
$stats = [pscustomobject]@{
    generatedUtc          = (Get-Date).ToUniversalTime().ToString('o')
    distinctDevices       = $distinctDevices
    deviceRows            = $rows.Count                       # deliberately > distinctDevices
    nonCompliantDevices   = ($compliance | Where-Object state -eq 'noncompliant' |
                             Select-Object -ExpandProperty deviceId -Unique).Count
    appInstallFailures    = ($appFailures | Where-Object installState -eq 'failed').Count
    inFlightInstalls      = ($appFailures | Where-Object installState -eq 'pending').Count
    win11Capable          = ($win11 | Where-Object overallReadiness -eq 'Capable').Count
    win11NotCapable       = ($win11 | Where-Object overallReadiness -eq 'NotCapable').Count
    win11Unknown          = ($win11 | Where-Object overallReadiness -eq 'Unknown').Count
}
$stats | Export-Csv (Join-Path $OutputPath '_stats.csv') -NoTypeInformation -Encoding utf8

Write-Host ''
Write-Host "  Synthetic fleet written to: $OutputPath" -ForegroundColor Cyan
Write-Host ("  {0} distinct devices across {1} device rows (duplicates + reimages on purpose)." -f $distinctDevices, $rows.Count) -ForegroundColor DarkGray
Write-Host '  Files: devices, compliance, app_failures, autopilot, licenses, warranty, win11_readiness, _stats' -ForegroundColor DarkGray
Write-Host '  All invented. No real device, user, or tenant appears.' -ForegroundColor DarkGray
Write-Host ''
