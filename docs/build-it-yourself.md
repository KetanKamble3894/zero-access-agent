# Build it yourself — the read-only collection layer, end to end

This is the hands-on guide. By the end you'll have Azure Automation runbooks pulling
read-only data from Microsoft Graph with a Managed Identity, writing daily CSV snapshots
to Blob storage, and a Power BI report reading those snapshots — the same pipeline the
rest of this repo builds on. No secrets, no app registration, read-only throughout.

Work in a **personal lab tenant**. Everything below uses placeholder names — swap in your
own. If you just want to see the shape of the data first, skip to [Try it with no tenant](#appendix--try-it-with-no-tenant).

> 📷 *Screenshots in this guide are placeholders marked like this. Drop your own
> personal-lab screenshots in, and check each one for identifiers before you commit it —
> the sanitize gate can't read text baked into an image.*

**What you'll build**

```
Intune / Entra ──(read-only, Managed Identity)──▶ Automation runbook ──▶ Blob CSV ──▶ Power BI
```

**Prerequisites**

- An Azure subscription (a personal lab is fine — the free tiers cover most of this).
- Rights to create resources and to assign Microsoft Graph app roles in the tenant.
- PowerShell 7+ on your machine for the one-time permission step.
- Power BI Desktop (free) to open the template.

---

## Part 1 · Create the Automation Account and storage

You can do this in the portal (Create a resource → Automation) or with the CLI. The CLI is
faster to copy:

```powershell
$rg        = "rg-zeroaccess-lab"
$location  = "westeurope"
$aa        = "aa-zeroaccess-lab"
$sa        = "stzeroaccesslab$(Get-Random -Max 9999)"   # storage names must be globally unique + lowercase
$location  = "westeurope"

az group create -n $rg -l $location
az automation account create -g $rg -n $aa -l $location
az storage account create -g $rg -n $sa -l $location --sku Standard_LRS --kind StorageV2
az storage container create --account-name $sa -n "root"       --auth-mode login
az storage container create --account-name $sa -n "agent-data" --auth-mode login
```

`root/` will hold the full CSVs (Power BI reads these). `agent-data/` holds the slim,
pre-aggregated snapshots the AI agent reads later.

> 📷 *Screenshot: the Automation Account overview blade.*

---

## Part 2 · Turn on the Managed Identity

This is what makes the whole thing secret-free. The runbook will sign in **as the
Automation Account itself** — no stored password, no certificate, nothing to leak.

Portal: Automation Account → **Identity** → **System assigned** → **On** → Save. Copy the
**Object (principal) ID** it shows — you need it next.

```powershell
az automation account identity assign -g $rg -n $aa   # prints the principalId
```

> 📷 *Screenshot: the Identity blade with System assigned = On and the principal ID.*

---

## Part 3 · Grant read-only Graph access to the identity

The runbook needs to *read* Intune/Entra data. Those are **application permissions**
(app roles) assigned to the managed identity. The portal doesn't offer this for managed
identities, so you assign them once with PowerShell.

**Grant only `.Read.All` scopes.** This is the line that keeps the pattern honest — if you
ever add a `ReadWrite` role to make something work, you've left the pattern.

```powershell
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All","Application.Read.All"

$miPrincipalId = "<paste-principal-id-from-part-2>"
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

$readRoles = @(
    "DeviceManagementManagedDevices.Read.All",
    "DeviceManagementConfiguration.Read.All",
    "DeviceManagementApps.Read.All",
    "Device.Read.All"
)

foreach ($role in $readRoles) {
    $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $role -and $_.AllowedMemberTypes -contains "Application" }
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miPrincipalId `
        -PrincipalId $miPrincipalId -ResourceId $graphSp.Id -AppRoleId $appRole.Id
    Write-Host "Granted $role"
}
```

Then let the identity write to **its own** storage (this is storage, not the tenant):

```powershell
$subId = (az account show --query id -o tsv)
az role assignment create --assignee $miPrincipalId `
  --role "Storage Blob Data Contributor" `
  --scope "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$sa"
```

> 📷 *Screenshot: Enterprise applications → your managed identity → Permissions, showing the read-only roles.*

---

## Part 4 · Import the modules

Automation Account → **Modules** → **Add a module** → **Browse from gallery**, into the
**PowerShell 7.2** runtime:

- `Microsoft.Graph.Authentication`
- `Az.Accounts`
- `Az.Storage`

Give them a few minutes to show **Available**.

> 📷 *Screenshot: the Modules list with all three Available.*

---

## Part 5 · Add and run a runbook

Automation Account → **Runbooks** → **Create a runbook** → PowerShell 7.2. Paste one of the
collectors from this repo's `scripts/` folder (or the skeleton below), **Publish**, then
**Start** it once to confirm it works.

```powershell
param(
    [string]$StorageAccount = "<your-storage-account>",
    [string]$FullContainer  = "root",
    [string]$AgentContainer = "agent-data"
)

# Sign in as the Managed Identity — no secrets anywhere.
Connect-MgGraph -Identity -NoWelcome
Connect-AzAccount -Identity | Out-Null
$ctx = New-AzStorageContext -StorageAccountName $StorageAccount -UseConnectedAccount

# Read-only GET, following paging so we get the whole collection.
# -OutputType PSObject so the rows export as real columns (not hashtable keys).
$devices = @(); $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices"
do {
    $page  = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
    $props = $page.PSObject.Properties.Name
    $devices += $page.value
    $uri = if ($props -contains '@odata.nextLink') { $page.'@odata.nextLink' } else { $null }
} while ($uri)

$stamp = (Get-Date).ToString('yyyy-MM-dd')

# Full CSV → root/ (for Power BI)
$full = "devices_$stamp.csv"
$devices | Export-Csv $full -NoTypeInformation -Encoding utf8
Set-AzStorageBlobContent -File $full -Container $FullContainer -Blob $full -Context $ctx -Force

# Pre-aggregate → agent-data/ : count DEVICES, not rows.
$stats = [pscustomobject]@{
    generatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
    distinctDevices = ($devices | Select-Object -ExpandProperty id -Unique).Count
    nonCompliant    = ($devices | Where-Object { $_.complianceState -ne 'compliant' }).Count
}
$statsFile = "devices_stats_$stamp.csv"
$stats | Export-Csv $statsFile -NoTypeInformation -Encoding utf8
Set-AzStorageBlobContent -File $statsFile -Container $AgentContainer -Blob $statsFile -Context $ctx -Force
```

**How it runs:** on Start, the runbook authenticates as the Automation Account's Managed
Identity (Part 2), which already holds the read-only Graph roles (Part 3). It GETs the
data, shapes it, and drops two files in Blob. That's the entire collection step — no
interactive login, no secret.

> 📷 *Screenshot: a completed runbook job with the output pane showing the row count.*

Check the storage account → Containers → `root/` and `agent-data/` to see the CSVs land.

---

## Part 6 · Schedule it

Runbook → **Schedules** → **Add a schedule** → new daily schedule. Ten collectors on a
daily schedule become the ten daily snapshots the rest of the pattern reads.

```powershell
az automation schedule create -g $rg --automation-account-name $aa `
  -n "daily-0600" --frequency Day --interval 1 --start-time "<tomorrow>T06:00:00+00:00"
az automation runbook schedule create -g $rg --automation-account-name $aa `
  --runbook-name "<your-runbook>" --schedule-name "daily-0600"
```

> 📷 *Screenshot: the runbook's Schedules blade with the daily schedule linked.*

---

## Part 7 · Copy the Power BI template and connect it

Download `powerbi/<template>.pbit` from this repo and **open it in Power BI Desktop**. A
`.pbit` carries the report layout and queries but **no data** — on open it asks for the
connection parameters, then pulls fresh from your Blob.

You'll be prompted for the **storage account name** and **container** (`root`). Then choose
how Power BI authenticates to the Blob — and this choice matters:

- **Organizational account (recommended).** Sign in with your Entra account; Power BI uses
  Azure AD / RBAC to read the Blob. **No secret is stored in the file.** This keeps the
  whole pipeline true to "zero secrets," and it's the option this project uses.
- **Account key (not recommended).** Pasting a storage-account key works, but the key is a
  stored secret — it can end up saved in the file and is easy to leak. If you use it, never
  commit or share the `.pbit` with a key inside.

> Pick the organizational-account option so the "Managed Identity end-to-end · zero
> secrets" promise holds all the way to the dashboard, not just up to the storage account.

Click **Refresh** and the report fills in.

> 📷 *Screenshot: the parameters dialog, then the loaded report.*

---

## Part 8 · How the Power BI report is built

So you can change it, not just run it:

- **Source:** the CSVs in `root/`. Power Query loads each CSV as a table; the storage
  account + container come in as **parameters** (that's what the `.pbit` prompts for), so
  nothing about a specific tenant is baked into the file.
- **Shaping:** Power Query trims columns and sets types. The "count devices, not rows"
  problem is handled here — distinct-count measures over the device id, not raw row counts,
  so duplicate sync rows don't inflate the numbers.
- **Model:** tables relate on the device id / serial number.
- **Report pages:** typically an overview (device totals, compliance %, Windows 11
  readiness split) plus drill-through pages per area. Because the source is parameterized
  CSVs, anyone can point the same report at their own snapshots.

---

## Appendix · Try it with no tenant

Don't have a lab tenant yet? Generate a synthetic fleet and point Power BI at that instead:

```powershell
./scripts/New-SyntheticFleet.ps1 -DeviceCount 500 -OutputPath ./sample-data
```

You get the same CSV shapes — including the messy realities (duplicate device rows,
missing values, reimaged serials, in-flight installs) — with no real data anywhere. It's
the fastest way to see the pattern, and it's how the examples in this repo are demonstrated.

---

## What we still don't know

- The cleanest way to keep the collectors' scopes minimal as the question set grows — every
  new question tempts a new permission.
- Where per-runbook size-gating belongs (in each script vs. a shared helper).
- Whether organizational-account auth in Power BI covers every refresh scenario teams hit,
  or whether some setups still reach for a key — feedback welcome.

---

*Credit: the Azure Automation → Blob CSV → Power BI reporting approach is well-established
in the community — see SMSAgent (Trevor Jones) among others, whose MEM-reporting templates
long predate this repo. What's added here is the read-only-by-construction discipline and
the zero-access AI agent layer that reads the snapshots.*

*Microsoft, Microsoft 365, Intune, Entra, Microsoft Graph, Azure, and Power BI are
trademarks of the Microsoft group of companies. Independent content; not endorsed by
Microsoft. Verify every endpoint and permission in your own lab tenant before relying on it.*
