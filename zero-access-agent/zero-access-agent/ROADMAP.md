# Roadmap — zero-access-agent

This repository documents a pattern, not a product: a reproducible way to let an AI agent
answer questions about an endpoint fleet from **read-only, pre-aggregated snapshots**,
holding no access to any live system. Managed Identity end-to-end, zero secrets,
read-only by construction.

Nothing here is a dated promise. Modules ship one at a time, each with a companion
write-up, as they're generalized from a working design and verified with synthetic data.

## Principles (fixed)

- **Reports, not systems.** The answering side has nothing to call — no scopes, no keys.
  The boundary is architectural, not behavioral.
- **Read-only by construction.** Collectors use read-only scopes; the agent holds none.
- **Managed Identity end-to-end.** No stored secrets to leak or rotate.
- **Pre-aggregate in a trusted job.** Shaping happens once, in a reviewed runbook — the
  agent reads vetted snapshots, it doesn't improvise math over raw rows.
- **Sanitize before it leaves the machine.** Every artifact, diagrams included, is
  genericized — no employer, customer, account, or production figure.
- **No invented numbers.** Every figure is sourced, ranged, or labelled an estimate.
- **Simplicity, and honesty.** Every module earns its place; each write-up ends with what
  we still don't know.

## Modules (publish order)

Legend: ✅ shipped · 🔨 current · ⬜ planned

1. ⬜ **Runbook patterns** — the read-only, pre-aggregating collector shapes (the "slim
   CSV + `_Stats`" convention), generic and tenant-free.
2. ⬜ **Snapshot layout** — the Blob `root/` (full CSVs / Power BI) vs `agent-data/` (slim,
   pre-aggregated) split, and the size-gating rule.
3. ⬜ **Index + agent config** — the two-index Azure AI Search setup (row-level data + doc
   chunks) and the Agent Rules (read-only, counting, GDPR, persona) that keep answers
   honest.
4. 🔨 **Synthetic fleet generator** — realistic-but-fake exports so anyone can run the
   whole pattern with no tenant at all: clone → generate → index → ask. The lowest-barrier
   first experience, and the safest thing to publish first.
5. ⬜ **Reporting templates** — turning the same snapshots into the Power BI dashboards
   teams actually read.

## Companion write-ups

Each module ships with a plain-language teardown. Three recurring shapes:

- **War-story teardowns** — a real endpoint problem, the boundary that contained it, and
  what the snapshot showed (e.g. count *devices*, not *rows*).
- **Troubleshooting guides** — specific error codes, permission names, and endpoint
  behaviors, reproduced first-hand.
- **"The Graph call behind the portal click"** — decoding what a portal action fires
  against Graph and which scope it needs. *(series name to be finalized)*

## Open questions

- Where the freshness/containment trade stops being worth it — at what fleet size or
  question cadence does snapshot-staleness force a different design?
- When pre-aggregated CSVs stop being enough and the answering side wants richer structure.
- Which fleet questions genuinely can't be answered from snapshots and need a live call.

Found a place this is wrong, or have an answer? Open an issue.

## Following along

Watch the repository for new modules. Longer teardowns and the reasoning behind each
release go out through the newsletter *(link to be added once the site is live)*.

---

*Microsoft, Intune, Entra, Microsoft Graph, Azure, and Power BI are trademarks of the
Microsoft group of companies. Independent content; not affiliated with or endorsed by
Microsoft.*
