# Zero-Access Agent

**Read-only endpoint intelligence for Microsoft Intune — by construction.**

A set of scheduled, read-only collectors that snapshot your Intune / Microsoft Graph / Entra data,
enrich it, and drop it into Blob storage for Power BI and a natural-language AI agent — with **no write
access to your tenant anywhere in the chain**. The read-only guarantee isn't a policy you trust; it's the
shape of the system: no collector holds a write scope, so none *can* change anything.

There is exactly **one** deliberate exception, fenced off in `tools/` and opt-in — see
[The one that writes](#the-one-that-writes) below.

> Everything here runs against a **personal lab tenant**. All sample data is synthetic (`@contoso.com`).
> Independent content — not affiliated with, sponsored by, or endorsed by Microsoft.

---

## How it works

```
 Intune / Graph / Entra ──(read-only GET)──▶  Collector runbook  ──▶  Blob (CSV)  ──▶  Power BI
     (your tenant)          Managed Identity   (Azure Automation)      + agent-data      + AI agent
```

- **Auth:** each script runs as an Azure Automation **system-assigned Managed Identity** — no secrets,
  no app registrations to rotate. The Graph token is requested from the Automation identity endpoint;
  Blob upload uses `Connect-AzAccount -Identity` + `New-AzStorageContext -UseConnectedAccount`.
- **Read-only by construction:** the identity is granted only `*.Read.All` Graph app roles, so the
  collectors physically cannot write. The only write is a CSV to *your own* Blob container.
- **Reproduce with no tenant:** `scripts/New-SyntheticFleet.ps1` generates a realistic fake fleet so you
  can build every report against synthetic data first.

## Repo layout

```
scripts/   read-only collectors, the reclaim/straggler reports, the AVD alert KQL, the synthetic fleet
tools/     the single opt-in utility that can WRITE (Lenovo warranty → device Notes)
```

## The collectors (`scripts/`)

| Script | What it produces | Story |
|---|---|---|
| `Collect-InventoryAllDevices.ps1` | One enriched row per device: device + Entra location + OEM warranty + Defender health | One row per device |
| `Collect-DeviceInventory.ps1` | The reference/base device-inventory collector (the pattern's starting point) | — |
| `Collect-NonCompliantDevices.ps1` | The **setting** that actually failed (not just "non-compliant") → Power BI | Which setting actually failed? |
| `Collect-PolicyAssignments.ps1` | Every policy mapped to every target group — dynamic rules + broken targets | Every policy, every target |
| `Collect-DeviceHygiene.ps1` | Stale / orphaned / inactive devices with a recommended action + owner team | The devices no one owns anymore |
| `Collect-AppDeploymentFailures.ps1` | App-install failures rolled up per app, with a failure rate + triage category | Which app is failing, and why |
| `Collect-AutopilotOperations.ps1` | Autopilot / ESP failures classified by phase + category, per deployment | Where Autopilot actually breaks |
| `Collect-LicenseComplianceCheck.ps1` | Corporate Windows devices whose user is missing the Intune / Win Enterprise licence, + manager & dept | Who's missing an Intune license |
| `Collect-Windows11Readiness.ps1` | The exact Windows 11 blocker per device — TPM, CPU, Secure Boot, RAM | Which devices can't take Windows 11 |
| `Collect-LocalAIAgentInventory.ps1` | A read-only inventory of local AI tools (Ollama, LM Studio, …); flags leavers who kept them | Who's running Ollama on your fleet? |
| `Collect-IntuneDocumentation.ps1` | A read-only snapshot of the whole Intune / Windows 365 config (community M365Documentation module) | Documentation that writes itself |
| `Report-TeamsPhoneLicenses.ps1` | A tiered Teams Phone licence reclaim report, joined to each user's manager | Teams Phone licenses, paid for and never used |
| `Report-UnrenamedDevices.ps1` | Windows devices still on the default `DESKTOP-` name, emailed to the team | The devices that never got renamed |
| `WVD-ConnectionFailure.kql` | A Log Analytics scheduled-alert query that catches AVD session failures before the tickets | When AVD won't connect |
| `New-SyntheticFleet.ps1` | Generates a fake-but-realistic endpoint fleet as CSVs — reproduce the reports with no real tenant | — |

## The one that writes (`tools/`)

`tools/Enrich-LenovoWarrantyToNotes.ps1` is the **only** script that can write to the tenant, and it's
built to be paranoid about it:

- **Report-only by default** (`-ReportOnly $true`): looks up Lenovo warranty by serial and writes a CSV
  **locally** — pure Microsoft Graph, **no Azure storage**, touches nothing in Intune.
- **Update mode** (`-ReportOnly $false`): additionally `PATCH`es warranty into each device's **Notes**
  with a **surgical append** that never overwrites existing content. This is the single place a
  `DeviceManagementManagedDevices.ReadWrite.All` scope appears — grant it **only** if you run update
  mode. Be aware that scope is broad (it also permits wipe/retire/delete), which is exactly why this tool
  is fenced off here and defaults to read-only.

## Permissions (Graph app roles on the Managed Identity)

Grant only what a given script needs; all are **read** roles except the one noted.

- Devices / Intune: `DeviceManagementManagedDevices.Read.All`, `DeviceManagementConfiguration.Read.All`
- Directory / users / licences: `User.Read.All`, `Directory.Read.All`, `Organization.Read.All`, `Device.Read.All`
- Sign-in & audit: `AuditLog.Read.All` (sign-in activity also requires **Entra ID P1/P2**)
- Reporting: `Reports.Read.All` (Teams usage)
- Storage (data plane): **Storage Blob Data Contributor** on the storage account (scoped to the container)
- **Write (Lenovo update mode only):** `DeviceManagementManagedDevices.ReadWrite.All`

App-role grants are made with `New-MgServicePrincipalAppRoleAssignment` (no portal blade). Import
`Az.Accounts` / `Az.Storage` into the Automation Account for Blob upload.

## Getting started

1. Create an Azure Automation Account and enable its **system-assigned Managed Identity**.
2. Grant the read-only Graph app roles above, and **Storage Blob Data Contributor** on your storage account.
3. Import `Az.Accounts` and `Az.Storage`.
4. Set the `CONFIG` block at the top of a script (resource group / storage account / container).
5. Run it read-only against a **lab tenant** — or against `New-SyntheticFleet.ps1` output — and open the
   CSV before wiring up Power BI.

## Notes & caveats

- Beta Graph endpoints (`/beta/deviceManagement/...`, `enrollmentProfileName`, `$batch`) can change —
  re-verify in your own tenant. Server-side `$filter` on `managedDevices` is inconsistent; several scripts
  filter client-side on purpose.
- `signInActivity` caps `$top` at 120 and needs Entra ID P1/P2. Teams usage reports return CSV with a
  UTF-8 BOM and (by default) **pseudonymised** user names — disable report name concealment or the joins
  fail. `businessPhones` is a directory attribute, not the authoritative Teams line.
- Mail from the Automation sandbox can't use port 25 — send via Graph `sendMail`, an authenticated relay,
  or Azure Communication Services.

## License

MIT — see [LICENSE](LICENSE).

*Microsoft, Intune, Entra, Microsoft Graph, Azure, Power BI, Windows Autopilot and Azure Virtual Desktop
are trademarks of the Microsoft group of companies; Lenovo is a trademark of Lenovo. Independent content;
verify every endpoint and permission in your own lab tenant before relying on it.*
