# scripts/

The collection layer, in the open. These are **commodity scripts** — the shareable artifact
is the design, not the code. None of them carry a real tenant, storage account, or identity —
you fill those in yourself.

## Before you run — the CONFIG block

Every script opens with a clearly marked **CONFIGURE ME** block. Set your own resource group,
storage account, and container there (that's the only edit you need), then run:

```powershell
# ===========================================================================
#  CONFIGURE ME  ->  set these to your own values, then run.
# ===========================================================================
$ResourceGroup  = "<your-resource-group-name>"     # resource group that holds your storage account
$StorageAccount = "<your-storage-account-name>"    # storage account name (lowercase, globally unique)
$Container      = "<your-container-name>"           # blob container, e.g. "intune-report"
```

Each script also has a built-in safety net: if you leave the `<your-...>` placeholders in
place, it stops immediately with a friendly message instead of failing halfway through. Any
optional settings below the three lines have sensible defaults you can leave alone.

Two kinds of file live here:

## Reference collectors

Read-only, Managed-Identity runbooks that GET data from Microsoft Graph, pre-aggregate it,
and write CSV snapshots to Blob — `root/` for the full CSVs (Power BI) and `agent-data/`
for the slim, pre-aggregated snapshots the AI agent reads. They all follow the same shape:

1. `Connect-MgGraph -Identity` — sign in as the Automation Account's Managed Identity. No secrets.
2. Read-only `GET` (with paging) — never a write scope.
3. Pre-aggregate — count **distinct devices, not rows**; that logic lives here, in a
   reviewed job, so the agent reads a vetted number instead of improvising math.
4. Write full CSV → `root/`, stats CSV → `agent-data/`. Size-gated.

| Script | Collects |
|---|---|
| `Collect-DeviceInventory.ps1` | managed device inventory + hygiene |
| *(compliance, app-failures, autopilot, licensing, warranty, win11-readiness…)* | one per concern — same shape |

The full fleet is ten daily runbooks across four concerns: compliance & policy, deployment
& lifecycle, inventory & hygiene, licensing & catalog. Each is a copy of the shape above
pointed at a different read-only endpoint.

> **The rule that keeps the pattern honest:** every Graph scope ends in `.Read.All`. If a
> collector ever needs a `ReadWrite` role to work, stop and rethink — the collection layer
> reads; it never writes to the tenant.

## Synthetic fleet generator

`New-SyntheticFleet.ps1` makes fake-but-realistic CSVs so you can run the whole pattern with
**no tenant at all**:

```powershell
./New-SyntheticFleet.ps1 -DeviceCount 500 -OutputPath ./sample-data
```

It produces the same shapes the collectors emit (devices, compliance, app failures,
autopilot, licenses, warranty, Windows 11 readiness, and a pre-aggregated `_stats.csv`) —
and deliberately includes the messy realities that break naive reporting: the same device
on multiple rows, missing values, reimaged serials (one serial, new device id), in-flight
deployments, and camelCase stat keys. The output is seeded, so the same seed gives the same
fleet.

Point Power BI or the search index at `./sample-data` and you have a working demo with
nothing real anywhere. See `docs/build-it-yourself.md` for the full walkthrough.
