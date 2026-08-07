<#
    New-ZeroAccessLab.ps1  —  stand up the Zero-Access COLLECT layer in one run.

    Creates, in your lab tenant's Azure subscription:
      • a resource group
      • an Automation Account with a system-assigned Managed Identity (no secrets)
      • a Storage Account + two containers: root/ (full CSVs for Power BI) and agent-data/ (slim)
    Then grants the Managed Identity:
      • read-only Microsoft Graph app roles (.Read.All only — it can never write to the tenant)
      • Storage Blob Data Contributor on ITS OWN storage (so runbooks can drop CSVs)

    PREREQS (install once):
      winget install Microsoft.AzureCLI          # or https://aka.ms/installazurecli
      Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications -Scope CurrentUser

    RUN:
      az login          # sign in as an admin of the LAB tenant
      Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All","Application.Read.All"
      ./New-ZeroAccessLab.ps1 -SubscriptionId "<sub-guid>"

    Everything below uses lab placeholders — change them to taste. Read-only by
    construction: if you ever add a ReadWrite Graph role here, you've broken the pattern.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [string]$ResourceGroup   = "rg-zeroaccess-lab",
    [string]$Location        = "westeurope",
    [string]$AutomationName  = "aa-zeroaccess",
    [string]$StorageName     = "zastorage$((Get-Random -Maximum 99999))",  # must be globally unique, lowercase
    [string[]]$GraphReadRoles = @(
        "DeviceManagementManagedDevices.Read.All",
        "DeviceManagementConfiguration.Read.All",
        "DeviceManagementApps.Read.All",
        "Directory.Read.All",
        "Group.Read.All",
        "User.Read.All"
    )
)

$ErrorActionPreference = "Stop"
$GraphAppId = "00000003-0000-0000-c000-000000000000"

function Say($m){ Write-Host "==> $m" -ForegroundColor Cyan }

# ---- 1. Azure resources -----------------------------------------------------
Say "Selecting subscription $SubscriptionId"
az account set --subscription $SubscriptionId | Out-Null

Say "Resource group $ResourceGroup ($Location)"
az group create -n $ResourceGroup -l $Location | Out-Null

Say "Automation Account $AutomationName (+ system-assigned Managed Identity)"
az automation account create -g $ResourceGroup -n $AutomationName -l $Location | Out-Null
az automation account identity assign -g $ResourceGroup -n $AutomationName | Out-Null
$miPrincipalId = az automation account show -g $ResourceGroup -n $AutomationName --query "identity.principalId" -o tsv
Say "Managed Identity principalId = $miPrincipalId"

Say "Storage Account $StorageName + containers root/ and agent-data/"
az storage account create -g $ResourceGroup -n $StorageName -l $Location --sku Standard_LRS --kind StorageV2 | Out-Null
az storage container create --account-name $StorageName -n "root"       --auth-mode login | Out-Null
az storage container create --account-name $StorageName -n "agent-data" --auth-mode login | Out-Null

Say "Granting the identity Storage Blob Data Contributor on its own storage"
$storageId = az storage account show -g $ResourceGroup -n $StorageName --query id -o tsv
az role assignment create --assignee $miPrincipalId --role "Storage Blob Data Contributor" --scope $storageId | Out-Null

# ---- 2. Read-only Microsoft Graph app roles ---------------------------------
Say "Granting read-only Graph app roles to the identity"
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$GraphAppId'"
foreach ($role in $GraphReadRoles) {
    if ($role -notmatch '\.Read(\.All)?$') {
        Write-Warning "SKIPPED '$role' — not a read-only scope. The collect layer only reads."
        continue
    }
    $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $role -and $_.AllowedMemberTypes -contains "Application" }
    if (-not $appRole) { Write-Warning "Role '$role' not found on Graph SP — skipping."; continue }
    $already = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miPrincipalId |
               Where-Object { $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphSp.Id }
    if ($already) { Write-Host "    already granted: $role"; continue }
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miPrincipalId `
        -PrincipalId $miPrincipalId -ResourceId $graphSp.Id -AppRoleId $appRole.Id | Out-Null
    Write-Host "    granted: $role"
}

# ---- 3. Modules for the runbooks (import in the portal, PowerShell 7.2) ------
Say "DONE. Next: in the Automation Account -> Modules, import (PowerShell 7.2 runtime):"
Write-Host "    Microsoft.Graph.Authentication   (Connect-MgGraph -Identity, Invoke-MgGraphRequest)"
Write-Host "    Az.Accounts, Az.Storage          (Connect-AzAccount -Identity, blob upload)"
Write-Host ""
Say "Then import your collectors as runbooks, dot-source read-only-gate.ps1 at the top of each,"
Say "publish, and attach a daily schedule. CSVs land in root/ -> point Power BI there."
Write-Host ""
Write-Host "Summary:" -ForegroundColor Green
Write-Host "  Resource group : $ResourceGroup"
Write-Host "  Automation     : $AutomationName  (MI principalId $miPrincipalId)"
Write-Host "  Storage        : $StorageName  (containers: root, agent-data)"
Write-Host "  Graph roles    : $($GraphReadRoles -join ', ')"
