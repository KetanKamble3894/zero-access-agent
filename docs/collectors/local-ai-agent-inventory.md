# Collector teardown — Local AI Agent Inventory (shadow-AI governance)

The most *timely* collector in the set: it inventories **local AI tooling** across the fleet —
Ollama, local LLM runners, unsanctioned copilots and the like — so security and EUC can answer
"who's running shadow AI, where, and is any of it on a leaver's machine?" It's also the clearest
demonstration of the zero-access idea end to end: the detection runs *on the device* (a Proactive
Remediation), and this collector never touches a device — it only reads the reported result.

Script: [`scripts/Collect-LocalAIAgentInventory.ps1`](../../scripts/Collect-LocalAIAgentInventory.ps1).
Read-only, Managed-Identity. Writes:

- `root/AIAgentInventory.csv` — full, identifiable, for Power BI
- `agent-data/AIAgentInventory_Agent.csv` — slim (user identifiers optional)
- `agent-data/AIAgentInventory_Stats.csv` — pre-computed counts + coverage gaps

> **Dependency.** This reads a companion Intune **detection script** (a Proactive Remediation you
> deploy separately) that emits, per device, a line listing detected AI tooling. That script
> isn't in this repo — point `$DetectionScriptName` / `$DetectionScriptId` at yours. The parser's
> expected format is documented in `ConvertFrom-DetectionOutput`.
>
> **Beta endpoint.** `deviceHealthScripts` run states use `/beta`; devices/users use `/v1.0`.

## The shape of the thing

The detection script's output is a compact string; the collector parses it into structured agents
(name, category, signals, and — crucially — sanctioned vs unsanctioned), then joins each device to
its primary user's department, location, and **account status**. The result is one row per
device-per-agent, with pre-computed stats layered on top.

## Four ideas worth stealing

**Detection on the device, reading off the tenant.** The heavy lifting — actually scanning a
machine for AI tooling — happens in the Proactive Remediation, on the endpoint. This collector
just reads `deviceRunStates`. That's the pattern in miniature: put the work where the data is, and
keep the central job read-only.

**Plain-English stat labels, because the index tokenises PascalCase.** Azure AI Search's default
analyzer treats a category like `DevicesByAgent` as one opaque token, so a natural-language
question never matches it. Every stat therefore carries a `StatLabel` — "Number of distinct
devices with unsanctioned AI tooling in the Finance department" — which is what the agent actually
retrieves on. If your snapshots feed an index, write for the analyzer, not just for Power BI.

**A deterministic document key (`RowKey`).** A blob indexer keyed by row position is fragile: a
device gaining or losing an agent shifts every following row and orphans stale documents. The
collector emits a stable `DeviceName|AgentName` key so each finding is its own durable document.

**Counting guards on a tall table.** One row per device-per-agent means naive row counts overstate
device counts. `IsPrimaryDeviceRow` marks exactly one row per device, so "how many devices" is
answered correctly, and `AgentCountOnDevice` carries the per-device tally.

## Honesty built into the stats

Two coverage stats exist purely so the totals reconcile and nobody reads a gap as a clean bill of
health: **`DevicesNotSuccessfullyScanned`** (scan errored / not yet reported / skipped in OOBE) and
**`DevicesWithNoCountry` / `NoOfficeLocation`** (excluded from geographic breakdowns). *Absent is
not the same as clean* — the collector says so out loud. It also publishes total devices per
country/office so you can compute a *rate*, not just a raw count that a big country will always top.
And it flags the sharp one: **disabled accounts still carrying AI tooling** — a leaver-risk signal.

## Privacy dial

Because this report is inherently about people, the agent copy has a switch:
`$IncludeUserIdentifiersInAgentCopy`. Turn it off and the indexed copy keeps department, country,
and office (where the exposure sits) but drops the individual's name and UPN — governance questions
are usually about *where*, not *who to discipline*.

## Permissions

Read-only, on the Managed Identity: `DeviceManagementConfiguration.Read.All` (health scripts + run
states), `DeviceManagementManagedDevices.Read.All` (fallback device detail), `User.Read.All`,
`Directory.Read.All`; plus `Storage Blob Data Contributor`. Every call is a GET; nothing is written
to the tenant.

## What we still don't know (honest gaps)

- **It's only as good as the detection script.** This collector reports what the on-device script
  found; a tool the script doesn't recognise is invisible here. The sanctioned/unsanctioned split
  is defined by that script, not this one.
- **Absent ≠ clean.** Devices that couldn't be evaluated are surfaced as their own coverage number,
  never folded into "no AI detected."
- **Detection recency.** Results are as fresh as each device's last remediation run.

---

*Microsoft, Intune, Entra, Microsoft Graph, and Azure are trademarks of the Microsoft group of
companies; other product names (e.g. Ollama) are trademarks of their respective owners.
Independent content; not endorsed by Microsoft.*
