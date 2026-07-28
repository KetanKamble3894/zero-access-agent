# Collector teardown — Windows 11 Readiness

Answers the migration-planning question every Windows shop is living with: "how many devices
can take Windows 11, which can't and why, and — the one that actually matters — how many of the
*not-capable* machines are still **active**?" A dead device that can't upgrade isn't a problem;
an in-use one is a purchase order.

Script: [`scripts/Collect-Windows11Readiness.ps1`](../../scripts/Collect-Windows11Readiness.ps1).
Read-only, Managed-Identity, pre-aggregating. Writes:

- `root/Windows11Readiness.csv` — full, exact Power BI column contract
- `agent-data/Windows11Readiness_Agent.csv` — slim
- `agent-data/Windows11Readiness_Stats.csv` — pre-computed counts

> **Beta endpoint.** Readiness metrics use `/beta`; managed devices and users use `/v1.0`.

## Where the data comes from

The readiness verdict comes from Endpoint Analytics' **Work From Anywhere** metrics
(`userExperienceAnalyticsWorkFromAnywhereMetrics`), which already carry the per-check booleans:
TPM, Secure Boot, processor family, RAM, storage, and the rest. The collector enriches each
device with its primary user (bulk-fetched once into a hashtable, not one call per device) and an
optional OEM friendly-model lookup, then derives a single readiness reason from the failed checks.

## Two design decisions worth stealing

**The root CSV is a contract; the agent copy is additive.** The `root/` file keeps the exact
column set and order Power BI expects — nothing added, nothing reordered — so an existing
dashboard never breaks. The extra fields the agent finds useful (readiness *state*, OS,
active-in-14-days) live only in the `agent-data` copy. When a report feeds both a human dashboard
and an AI index, keeping the human contract stable while the agent copy evolves is the move.

**Pre-computed stats so the agent counts, never enumerates.** The stats file answers the real
questions directly: devices by readiness, *Windows-10-and-active-in-14-days* by readiness (the
exact service-manager question), and **which hardware check is blocking upgrades and on how many
devices** — so you can see it's TPM on 300 machines, not guess. The agent reads a number; it
doesn't tally rows.

One nice detail: Windows 10 and 11 both report `OSVersion` as `10.0.x`, so the split is done on
build number (≥ 22000 = Windows 11) rather than trusting the version string.

## Permissions

Read-only, on the Managed Identity: `DeviceManagementManagedDevices.Read.All` (readiness metrics +
managed devices), `User.Read.All` (location), plus `Storage Blob Data Contributor`. Every call is
a GET; nothing is written to the tenant.

## What we still don't know (honest gaps)

- Readiness is Microsoft's verdict from Endpoint Analytics, not an independent hardware probe;
  it's as current as the device's last upload.
- The friendly-model lookup is optional; without it the model column reads "Unknown Model" rather
  than failing.
- "Active in 14 days" is a sync-recency proxy for "in use" — a reasonable, stated approximation,
  not ground truth.

---

*Microsoft, Intune, Entra, Windows, Microsoft Graph, and Azure are trademarks of the Microsoft
group of companies; Lenovo is a trademark of Lenovo. Independent content; not endorsed by
Microsoft or Lenovo.*
