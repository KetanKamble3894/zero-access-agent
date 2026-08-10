# Collector teardown — Inventory: All Devices

This is the first and largest collector in the pattern. It answers the deceptively simple
question *"what's in the fleet?"* — and the honest answer needs data from four places
stitched together, without ever writing to the tenant.

Script: [`scripts/Collect-InventoryAllDevices.ps1`](../../scripts/Collect-InventoryAllDevices.ps1).
Read-only, Managed-Identity, pre-aggregating. It writes two files to `agent-data/`:

- **`Inventory_AllDevices.csv`** — one enriched row per device.
- **`Summary_Stats.csv`** — pre-computed counts, so the agent answers "how many X" from a
  vetted number instead of counting rows itself.

> **Beta endpoint.** This collector uses `https://graph.microsoft.com/beta` — required for
> the Intune Reports export jobs and a couple of device properties. Beta endpoints can
> change without notice; pin to `/v1.0` where an equivalent exists and re-verify after
> Graph updates.

---

## What it collects, and from where

A single device row is assembled from four independent sources:

| Source | What it adds | How |
|---|---|---|
| `deviceManagement/managedDevices` | the base device record (name, serial, OS, compliance, owner, encryption, last sync) | paged `GET` |
| Intune Reports — `DefenderAgents` | Defender agent state, real-time protection, signature/ tamper status | server-side **export job** (async) |
| Device **Notes** field | OEM warranty start/end + friendly model | `$batch` reads, parsed as `key=value` |
| Entra `users` | user's org location (city / country / office) | `$batch` reads, de-duplicated |

The interesting part isn't any one call — it's that these have *different retrieval
shapes* (a paged list, an async job, two batched lookups) and get joined in memory into one
clean row. That's the collector's real job.

---

## Walkthrough

The runbook runs in six numbered stages so the logs read like a story.

**[1/6] Storage context.** `Connect-AzAccount -Identity` signs in as the Automation
Account's Managed Identity and gets a storage context. No key, no secret.

**[2/6] Defender status — via an export job.** Defender agent data isn't a plain endpoint;
it's an Intune *report*. `Invoke-IntuneExportJob` POSTs to `deviceManagement/reports/exportJobs`,
polls until the job is `completed`, downloads the ZIP, extracts the CSV, and imports it. The
results are indexed into a lookup keyed by both device id *and* uppercased device name (the
join later tries id first, name second).

**[3/6] All managed devices.** One paged `GET` with an explicit `$select` — only the columns
the inventory needs, which keeps the payload (and the later CSV) lean. All platforms, no OS
filter.

**[4/6] Warranty from the Notes field.** Some fleets stash OEM warranty data as `key=value`
lines in each device's **Notes** field. For devices from the configured manufacturer, the
collector reads `notes` in batches of 20 via `$batch` and parses out `Model`,
`WarrantyStartDate`, `WarrantyEndDate`. It's a pragmatic hack around the fact that warranty
isn't a first-class Intune property — and a good example of meeting the data where it
actually lives.

**[5/6] User location — batched and de-duplicated.** Many devices share a user, so the
collector first reduces to *unique* user ids, then `$batch`-reads `city`, `country`,
`officeLocation` from Entra. Note the honest comment in the code: this is **organisational
assignment, not whereabouts** — where the user is *filed*, not where they physically are.

**[6/6] Join and export.** Each device row is built by joining the three lookups (Defender,
warranty, location), deriving a `WarrantyState` (Active/Expired/Unknown) from the parsed
end date, and writing `Inventory_AllDevices.csv`. Then the summary stats are computed and
written.

---

## Techniques worth stealing

These are the parts that make it production-grade rather than a demo:

**Raw Managed-Identity token with refresh.** Instead of `Connect-MgGraph`, it calls the
`IDENTITY_ENDPOINT` directly for a token and tracks a 50-minute expiry, refreshing before
long runs age out. `Get-GraphHeaders` transparently re-mints the token mid-run. For a
runbook that may execute for many minutes across thousands of devices, controlling the token
lifecycle yourself avoids mid-run 401s.

**Retry that honors the server.** `Invoke-GraphRequest` refreshes-and-retries on `401`, and
backs off on `429/502/503/504` — reading the `Retry-After` header when present and capping
the wait at 300s. This is the difference between a runbook that survives Graph throttling and
one that dies at 3 a.m.

**`$batch` for enrichment.** Warranty and location would each be one call per device/user —
thousands of round-trips. Batching 20 requests per call cuts that by ~20× and keeps the run
inside its window. (20 is the Graph `$batch` limit.)

**A column resolver for schema drift.** `Get-DefValue` looks up a value across a list of
candidate column names (`DeviceState_loc`, `DeviceState`, …) because export schemas differ by
tenant and version. Rather than assume one name and silently produce blanks, it tries several
and falls back to `N/A`. Honest gaps over confident wrong answers.

**A size gate tied to the consumer.** `Export-AgentDataCsv` refuses to upload any
`agent-data/` file over ~12 MB, because the downstream Azure AI Search extraction has a ~16 MB
ceiling. The gate lives at the producer so a bloated snapshot fails loudly here instead of
silently truncating in the index.

**Pre-aggregation as a trust boundary.** `Summary_Stats.csv` is the pattern's core principle
in code: the collector groups the inventory into ~16 pre-counted breakdowns (by OS,
manufacturer, model, compliance, country, warranty, and cross-cuts like country × compliance),
caps the long-tail dimensions to top-N, and stamps a `Total`. The agent then *reads* "how many
Windows devices in Germany are non-compliant" instead of computing it over raw rows — which
is exactly how you avoid the classic "counted rows, not devices" error.

---

## Permissions

Read-only, on the Managed Identity (assign once — see
[build-it-yourself](../build-it-yourself.md)):

- `DeviceManagementManagedDevices.Read.All` — devices, Notes, and the reports export
- `User.Read.All` — the city/country/office enrichment
- `Storage Blob Data Contributor` on the storage account — to write the CSVs (storage, not
  the tenant)

Every scope is read. Nothing here writes to Intune or Entra.

---

## What we still don't know (honest gaps)

- **The Defender join is fuzzy.** When there's no device-id match it falls back to matching on
  uppercased device name, which can misfire on renamed or duplicate-named machines. How often
  that fallback fires — and how often it's wrong — is worth measuring, not assuming.
- **Warranty coverage is partial.** It only exists for devices whose OEM warranty was written
  into Notes. Everything else is `Unknown` — stated honestly in the data rather than hidden.
- **Location is org data, not GPS.** `UserOfficeLocation` is where the user is assigned in
  Entra; treat "devices by location" as an administrative view, not a physical one.
- **Beta drift.** Because it rides `/beta`, a Graph change can alter a property or an export
  schema. The column resolver softens this, but the real defense is re-running in a lab after
  Graph updates.

---

*The Azure Automation → Blob CSV → Power BI reporting approach is well-established in the
community (see SMSAgent / Trevor Jones, whose MEM-reporting templates predate this repo). What
this collector adds is the read-only-by-construction discipline and the pre-aggregated
`agent-data/` snapshots an AI agent can read without any live access.*

*Microsoft, Intune, Entra, Microsoft Graph, Defender, and Azure are trademarks of the
Microsoft group of companies. Independent content; not endorsed by Microsoft.*
