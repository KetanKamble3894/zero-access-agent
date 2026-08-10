---
title: Non-Compliant Devices — collector teardown
description: How the read-only runbook finds every non-compliant Windows device and the exact settings that failed — the Graph calls behind the report.
tags:
  - Intune
  - Microsoft Graph
  - Defender / Security
  - Azure Automation
---

# Non-Compliant Devices — how it actually works

The portal shows you a device with a red **Non-compliant** badge. It rarely shows you, at a glance,
*which specific settings* failed across *which policies* — and it never hands you that as data you can
report on. This collector does: a scheduled, **read-only** Azure Automation runbook that walks
Microsoft Graph, flattens "device → failing policy → failing setting" into one row per failure, and
writes a sanitized CSV. No live tenant connection for the report; the agent and Power BI only ever see
the snapshot.

![The Graph calls behind the Non-Compliance report — read-only sequence](../../assets/img/noncompliant-graph-flow.png)

## The Graph calls behind it

Everything is a **GET**. Nothing is ever written back to the tenant.

1. **Get a token — no secrets.** The runbook authenticates with its **Managed Identity** via the
   `IDENTITY_ENDPOINT`, so there are no stored keys or app secrets anywhere in the script.

2. **Find the non-compliant Windows devices** (paged):
   ```
   GET /beta/deviceManagement/managedDevices
       ?$filter=operatingSystem eq 'Windows' and complianceState eq 'nonCompliant'
       &$select=id,deviceName,manufacturer,model,userPrincipalName,lastSyncDateTime,complianceState
   ```
   Paging follows `@odata.nextLink` until it's exhausted.

3. **Look up each unique user once** (v1.0), for city / country / department / account state:
   ```
   GET /v1.0/users?$filter=userPrincipalName eq '{upn}'
       &$select=displayName,userPrincipalName,city,country,department,accountEnabled
   ```
   This runs per **unique** UPN and is cached — not once per device row.

4. **For each device, ask which policies it fails** (beta):
   ```
   GET /beta/deviceManagement/managedDevices/{id}/deviceCompliancePolicyStates
   ```
   Only states where `state = nonCompliant` are kept.

5. **For each failing policy, ask which settings failed** (beta):
   ```
   GET /beta/deviceManagement/managedDevices/{id}/deviceCompliancePolicyStates/{policyId}/settingStates
   ```
   Each failing `settingState` becomes a row — `SettingName` (the policy prefix stripped off),
   `SettingState`, and `errorDescription`.

6. **Write the snapshots to Blob storage** — a root `NonCompliant_Windows_Devices.csv` for Power BI,
   and an `agent-data/` copy plus a `_Stats.csv` (kept under the 12 MB gate for the AI-search layer).

### The permissions (least-privilege, read-only)

`DeviceManagementManagedDevices.Read.All` · `User.Read.All`

## The bit that surprises people: the N+1 fan-out

This is the story worth telling. There isn't *one* magic "give me non-compliance detail" endpoint.
It's a fan-out:

- **1** call for the device list, then
- **1** `deviceCompliancePolicyStates` call **per device**, then
- **1** `settingStates` call **per failing policy** on that device.

On a large fleet that's **thousands** of calls, which is exactly why the setting-level detail lives on
a **beta** endpoint and almost nobody surfaces it. The payoff is what the portal won't give you as
data: "device X is non-compliant **specifically** on *Firewall* and *Real-time protection*."

!!! warning "Beta endpoint"
    `deviceCompliancePolicyStates/{id}/settingStates` is a **/beta** endpoint. Beta shapes can change
    without notice — reproduce it in your own lab before you depend on it, and expect the odd device
    that returns policy states but no setting states (the script handles that case explicitly).

## The one number people get wrong

A device that fails three settings across two policies produces **several rows**. Count rows and your
"non-compliant devices" number is inflated. The `_Stats` output is built to **count distinct
`DeviceName`**, never rows — for the total, per-setting, per-policy, per-country and per-manufacturer
cuts alike. It even flags the gap between *devices Intune reports as non-compliant* and *devices that
returned a concrete failing setting*, so you can see when the two disagree.

## Run it yourself — no tenant needed

The [synthetic dataset](../../scripts/noncompliant-devices.md) ships a fake-but-realistic
`NonCompliant_Windows_Devices.csv` (multiple failing settings per device, 10 countries). Point the
[Power BI report](../../powerbi/noncompliant-devices-report.md) at it and the whole thing lights up
with **no Graph access at all** — the fastest, safest way to see the shape of the data.

## Related

- :material-script-text: **The script** → [Collect-NonCompliantDevices.ps1](../../scripts/noncompliant-devices.md)
- :material-chart-box: **The report** → [Non-Compliant Windows Devices — Power BI](../../powerbi/noncompliant-devices-report.md)
- :material-shield-lock: **The pattern** → [Zero-Access Agent](../index.md)

---

*Sanitized: parameterised storage source, no real account, synthetic data only. Independent content —
not affiliated with, sponsored by, or endorsed by Microsoft. Microsoft, Intune, Entra, Microsoft
Graph, Azure and Power BI are trademarks of the Microsoft group of companies. Everything here comes
from a personal lab.*
