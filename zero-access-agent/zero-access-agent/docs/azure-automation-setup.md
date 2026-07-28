# Setting up the collection layer — Azure Automation, read-only

This guide stands up the **COLLECT** stage of the Zero-Access Pattern: scheduled
Azure Automation runbooks that read from Microsoft Graph with a **Managed Identity**
(no secrets, no app registration), pre-aggregate the results, and write CSV snapshots to
Blob storage. The AI agent never appears here — it only reads the snapshots later.

> Everything below uses placeholders like `<resource-group>` and `<storage-account>`.
> Swap in your own **personal lab** values. Never commit real tenant names, subscription
> IDs, or account names — see the repo's identity rules.

Prerequisites: an Azure subscription (a personal lab), permission to create resources and
to assign Graph app roles in the tenant, and PowerShell 7+ locally for the one-time
role-assignment step.

---

## 1. Create the resources

```powershell
# Variables — lab values only
$rg       = "<resource-group>"
$location = "<region>"                     # e.g. westeurope
$aa       = "<automation-account>"
$sa       = "<storage-account>"            # lowercase, globally unique
$container= "agent-data"

az group create -n $rg -l $location

# Automation Account (system-assigned Managed Identity enabled in the next step)
az automation account create -g $rg -n $aa -l $location

# Storage for the CSV snapshots
az storage account create -g $rg -n $sa -l $location --sku Standard_LRS --kind StorageV2
az storage container create --account-name $sa -n $container --auth-mode login
az storage container create --account-name $sa -n "root" --auth-mode login
```

`root/` holds the full CSVs (these feed Power BI). `agent-data/` holds the slim,
pre-aggregated snapshots the agent will read.

## 2. Turn on the Managed Identity

The runbook authenticates *as the Automation Account*, not as you and not with a stored
secret. Enable the **system-assigned** identity:

```powershell
az automation account identity assign -g $rg -n $aa
# Note the printed principalId — you need it in step 3.
```

This is the heart of "zero secrets": there is no client secret or certificate to leak,
commit, or rotate.

## 3. Grant read-only Graph permissions to the identity

App-only Graph permissions are **application permissions** (app roles) assigned to the
managed identity's service principal. The portal doesn't expose this for managed
identities, so assign the roles with Graph PowerShell — **once**, from your workstation.

Grant only read scopes. These are the collectors' permissions; keep the list minimal.

```powershell
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All","Application.Read.All"

$miPrincipalId = "<managed-identity-principal-id>"   # from step 2
$graphSpId = (Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'").Id

# Read-only application permissions to grant (add/remove to taste):
$readRoles = @(
    "DeviceManagementManagedDevices.Read.All",
    "DeviceManagementConfiguration.Read.All",
    "DeviceManagementApps.Read.All",
    "Device.Read.All"
)

foreach ($role in $readRoles) {
    $appRole = (Get-MgServicePrincipal -ServicePrincipalId $graphSpId).AppRoles |
               Where-Object { $_.Value -eq $role -and $_.AllowedMemberTypes -contains "Application" }
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miPrincipalId `
        -PrincipalId $miPrincipalId -ResourceId $graphSpId -AppRoleId $appRole.Id
}
```

> Every scope here ends in `.Read.All`. If you ever find yourself adding a `ReadWrite`
> role to make something work, stop — that breaks the pattern. The collection layer reads;
> it never writes to the tenant.

Also give the identity write access to **its own** storage (so it can drop CSVs) — this is
storage, not the tenant:

```powershell
az role assignment create --assignee $miPrincipalId `
  --role "Storage Blob Data Contributor" `
  --scope "/subscriptions/<sub-id>/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$sa"
```

## 4. Import the modules

In the Automation Account (portal → *Modules* → *Add a module*, "Browse from gallery"),
import into the **PowerShell 7.2** runtime:

- `Microsoft.Graph.Authentication` — for `Connect-MgGraph -Identity` and
  `Invoke-MgGraphRequest`
- `Az.Accounts` and `Az.Storage` — for `Connect-AzAccount -Identity` and the Blob upload

Keeping to `Microsoft.Graph.Authentication` + `Invoke-MgGraphRequest` (rather than the
full SDK) keeps imports light and makes the actual Graph calls visible in the script.

## 5. The runbook shape

Every collector follows the same shape: connect as the identity, GET a read-only endpoint,
**pre-aggregate**, write a full CSV to `root/` and a slim CSV (+ `_Stats`) to `agent-data/`.
A minimal skeleton (the repo's `scripts/` folder has fuller, generic examples):

```powershell
param(
    [string]$StorageAccount = "<storage-account>",
    [string]$FullContainer  = "root",
    [string]$AgentContainer = "agent-data"
)

# Auth: the Automation Account's Managed Identity. No secrets anywhere.
Connect-MgGraph -Identity -NoWelcome
Connect-AzAccount -Identity | Out-Null
$ctx = New-AzStorageContext -StorageAccountName $StorageAccount -UseConnectedAccount

# Read-only GET (paged)
$devices = @()
$uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices"
do {
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri
    $devices += $page.value
    $uri = $page.'@odata.nextLink'
} while ($uri)

$stamp = (Get-Date).ToString('yyyy-MM-dd')

# Full CSV → root/ (for Power BI)
$full = "devices_$stamp.csv"
$devices | Export-Csv $full -NoTypeInformation -Encoding utf8
Set-AzStorageBlobContent -File $full -Container $FullContainer -Blob $full -Context $ctx -Force

# Pre-aggregate → agent-data/ : count DEVICES, not rows
$stats = [pscustomobject]@{
    generatedUtc     = (Get-Date).ToUniversalTime().ToString('o')
    distinctDevices  = ($devices | Select-Object -ExpandProperty id -Unique).Count
    nonCompliant     = ($devices | Where-Object complianceState -ne 'compliant').Count
}
$statsFile = "devices_stats_$stamp.csv"
$stats | Export-Csv $statsFile -NoTypeInformation -Encoding utf8
Set-AzStorageBlobContent -File $statsFile -Container $AgentContainer -Blob $statsFile -Context $ctx -Force
```

The pre-aggregation is not just for speed — it's a **trust boundary**. The counting logic
(distinct devices, not raw rows) lives in a reviewed runbook, so the agent reads a vetted
number instead of improvising math over messy data.

## 6. Schedule it

Publish each runbook, then attach a daily schedule:

```powershell
az automation schedule create -g $rg --automation-account-name $aa `
  -n "daily-0600" --frequency Day --interval 1 --start-time "<next-06:00Z>"

az automation runbook schedule create -g $rg --automation-account-name $aa `
  --runbook-name "<runbook-name>" --schedule-name "daily-0600"
```

Ten collectors on a daily schedule become the ten daily snapshots the rest of the pattern
reads. Size-gate the outputs (skip/trim a snapshot that balloons past a sane cap) so a bad
day upstream can't produce an unbounded file.

---

## What you have now

A collection layer that is read-only by construction and holds no secrets: a Managed
Identity with only `.Read.All` Graph roles, writing daily CSV snapshots to Blob. Point
Power BI at `root/` and the agent's index at `agent-data/`. Next: the search index and the
agent (see the repo roadmap).

## What we still don't know

- The cleanest way to keep the ten collectors' scopes minimal as the question set grows —
  every new question tempts a new permission.
- Where per-runbook size-gating should live (in each script vs. a shared helper).

---

*Credit: the Azure Automation runbook-and-schedule approach is well-trodden in the
community — see SMSAgent (Trevor Jones) among others. This guide applies it to a
read-only, Managed-Identity Graph collection pattern.*

*Microsoft, Intune, Entra, Microsoft Graph, Azure, and Power BI are trademarks of the
Microsoft group of companies. Independent content; not endorsed by Microsoft. Verify every
endpoint and permission in your own lab tenant before relying on it.*
