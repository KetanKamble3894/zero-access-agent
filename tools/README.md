# tools/

**These are not collectors, and they are not read-only.**

The rest of this project is read-only by construction: the collectors in `scripts/` only ever
`GET`, and the agent holds no tenant access at all. The scripts in *this* folder are different —
they are optional, human-run utilities that may **write** to the tenant. They live here,
separately, precisely so the boundary is unmistakable.

The read-only guarantee that the pattern advertises covers the **collection → agent** path.
Anything in `tools/` sits **outside** that guarantee. Read each tool's header and its teardown
before running it, and prefer its report-only / dry-run mode first.

| Tool | Writes? | Purpose |
|---|---|---|
| `Enrich-LenovoWarrantyToNotes.ps1` | **Yes** (update mode only; report-only by default) | Looks up Lenovo warranty by serial and records it in device Notes, so the read-only collectors can read it later. See [docs/lenovo-warranty-enrichment.md](../docs/lenovo-warranty-enrichment.md). |

If you want the tenant left strictly untouched, run these in report-only mode and join their CSV
output instead of letting them write.
