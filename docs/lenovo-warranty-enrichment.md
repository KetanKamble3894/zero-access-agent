# Enrichment tool — Lenovo warranty into Notes (the one that writes)

> **Read this first.** Everything else in this project is read-only. **This tool is the one
> exception**: in update mode it *writes* to the tenant (it PATCHes device Notes). It is not
> a collector, it doesn't feed the agent directly, and it lives in `tools/` — separate from
> the read-only collection layer — on purpose. The pattern's "read-only by construction"
> guarantee covers the **collection → agent** path; this utility sits deliberately outside
> it and is run by a human, opt-in.

Script: [`tools/Enrich-LenovoWarrantyToNotes.ps1`](../../tools/Enrich-LenovoWarrantyToNotes.ps1).

## What it does

Lenovo warranty isn't a first-class Intune property. This tool looks it up per device by
serial number (from Lenovo's public support pages) and records `WarrantyStartDate=` /
`WarrantyEndDate=` lines in each device's **Notes** field. Once it's in Notes, the read-only
inventory collector — and Power BI — can simply *read* it, without every consumer having to
call Lenovo.

Two modes:

- **`-ReportOnly $true` (default): read-only.** Looks up warranty and writes a CSV report to
  Blob. Touches nothing in Intune. Safe to run any time.
- **`-ReportOnly $false`: update.** Additionally PATCHes device Notes to append the warranty
  fields. This is the write. It needs `DeviceManagementManagedDevices.ReadWrite.All` — the
  only place in the whole project a write scope appears.

## Why persist to Notes at all? (the honest trade-off)

There are two defensible designs, and it's worth being explicit about which this is:

1. **Write-back (this tool).** Enrich once into Notes; the read-only collector reads it
   cheaply thereafter. Cost: a write step, and Notes-as-a-datastore is a bit of a hack.
2. **Pure read-only lookup.** Call Lenovo *during* the read-only collection and emit warranty
   straight to the CSV — never writing to Intune. Cost: every collection run re-scrapes
   Lenovo, and the data isn't visible to admins in the Intune console.

This project uses design (1) because the warranty is then visible in the Intune console and
cheap for all downstream consumers. If you'd rather keep the tenant strictly untouched, design
(2) is the "purer" zero-access variant — run this tool in report-only mode and join the CSV in
instead.

## Safety design worth stealing

- **Report-only by default.** You have to *opt in* to writing. The destructive path is never
  the default.
- **Surgical append, never overwrite.** `Add-WarrantyFieldsSurgically` only *adds* a warranty
  line if it's absent, and never rewrites existing Notes content (e.g. an existing `Model=`
  line is preserved). The PATCH sends the whole Notes value, so "don't clobber" has to be
  enforced in code — and it is.
- **Individual `$select` query per device.** It fetches each device's Notes one at a time with
  `$select=id,deviceName,serialNumber,notes` rather than trusting the bulk list, because the
  list and per-device views can disagree on the Notes field. Accuracy over speed — important
  when the next step overwrites that field.
- **Rate limiting.** A 2-second pause between devices, to be a good citizen toward the warranty
  endpoint.

## Caveats (be honest about these)

- **The Lenovo lookup is unofficial and fragile.** It calls an undocumented endpoint and parses
  the warranty HTML with regex. Lenovo can change or block it without notice, and you should
  check Lenovo's terms of use before running it at any scale. The robust long-term route is
  Lenovo's **official Warranty API** (requires a key).
- **Lenovo-only.** Other OEMs need their own lookup; the Notes convention is generic, the
  lookup isn't.
- **It rides `/beta`** for the device list and PATCH — re-verify after Graph updates.

## Permissions

- Report-only mode: `DeviceManagementManagedDevices.Read.All` + `Storage Blob Data Contributor`
- Update mode: `DeviceManagementManagedDevices.ReadWrite.All` (grant only if you run update mode)

## What we still don't know

- How often the Lenovo scrape silently returns nothing as the pages change — worth tracking the
  success-rate metric the script already logs.
- Whether Notes is the right long-term home for warranty, or whether it belongs only in the
  snapshot CSVs (design 2 above).

---

*Microsoft, Intune, Entra, Microsoft Graph, and Azure are trademarks of the Microsoft group of
companies; Lenovo is a trademark of Lenovo. Independent content; not endorsed by Microsoft or
Lenovo. Verify in your own lab tenant, and review Lenovo's terms before using their support
endpoints.*
