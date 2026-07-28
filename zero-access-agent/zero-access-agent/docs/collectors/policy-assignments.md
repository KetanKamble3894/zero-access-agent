# Collector teardown — Policy Assignments (the "who is this assigned to" collector)

"Which policies target which groups, and who's actually in those groups?" is one of the
hardest questions to answer honestly in Intune — the data is scattered across four policy
types, three targeting shapes, and two kinds of group. This collector gathers all of it
read-only and, crucially, shapes it so an AI agent can answer *without guessing from a
fragment*.

Script: [`scripts/Collect-PolicyAssignments.ps1`](../../scripts/Collect-PolicyAssignments.ps1).
Read-only, Managed-Identity. It emits a family of CSVs — full (with IDs) to `root/` for Power
BI, slim (no IDs, size-gated) to `agent-data/` for the index.

> **Beta endpoint.** Policy lists use `/beta`; group resolution uses `/v1.0`. Re-verify after
> Graph updates.

---

## The four sweeps, and why they differ

Policy assignments don't come from one place. The collector drives a small config table so
each policy type is retrieved the right way:

| Policy type | Endpoint | How assignments come back |
|---|---|---|
| Compliance | `deviceCompliancePolicies?$expand=assignments` | inline (expanded) |
| Configuration profiles | `deviceConfigurations?$expand=assignments` | inline (expanded) |
| Settings catalog | `configurationPolicies?$expand=assignments` | inline (expanded) |
| Endpoint security | `intents` + `intents/{id}/assignments` | a **separate call per policy** |

That last row is the gotcha: endpoint-security *intents* don't support `$expand=assignments`,
so their assignments need a per-policy follow-up call. Encoding the retrieval mode
(`ExpandedOnly` vs `PerPolicy`) in the table keeps the sweep loop uniform.

Each assignment's `@odata.type` is decoded into a target: **All Devices**, **All Users**, or a
specific **Group**, and into an **intent** — Include or Exclude (exclusion group types map to
Exclude). Every distinct group id is collected into a `HashSet` so it's resolved only once.

---

## Groups: static vs dynamic, and the ones that vanished

Resolving a group is where the honesty lives.

- **Static groups** get their `transitiveMembers` expanded (users and devices), so you can
  answer "who is actually targeted."
- **Dynamic groups** are *not* expanded — their membership is a **rule**, not a list. The
  collector captures the `membershipRule` and its processing state instead. This is the honest
  move: enumerating a snapshot of dynamic members would imply a certainty the rule doesn't
  give you. The rule *is* the truth; the members are derived.
- **Deleted / unresolvable groups** are detected and written to their own
  `DeletedGroupAssignments.csv`. An assignment pointing at a group that no longer exists is a
  real hygiene problem — policies quietly targeting nothing — and surfacing it is exactly the
  kind of finding this pattern exists to make visible.

---

## The key idea: one complete document per policy

This is the collector's most important output and the clearest RAG-design lesson in the repo.

A naive design indexes the flat `PolicyAssignments.csv` — one row per (policy, target). But an
AI agent retrieving over that data might pull *three of a policy's five assignment rows* and
confidently answer "this policy targets these three groups" — wrong, because it never saw the
other two. The fragment looked complete.

`PolicyAssignments_Summary.csv` fixes this by emitting **one row per policy** carrying the
*complete* include and exclude target lists (semicolon-joined, capped at a sane length). Now a
single retrieved document contains the whole answer for that policy. The agent can't assemble a
partial picture because the picture isn't split up.

The rule generalizes: **if a correct answer requires *all* of an entity's rows, give the agent
one document that already contains all of them.** Pre-joining for completeness is as important
as pre-aggregating for counts.

---

## Keeping index documents inside the limits

Two mechanisms keep the `agent-data/` files ingestible:

- **Slim copies, no IDs.** The agent-data versions drop GUIDs entirely and keep names — smaller
  files, and nothing the agent doesn't need to reason in plain language.
- **Chunking + a manifest.** Group membership can be huge. When it exceeds the row threshold,
  it's split into `_Part001`, `_Part002`, … files, each under the ~12 MB gate (the AI Search
  extraction ceiling is ~16 MB), and a `_Manifest.csv` records that it was chunked and how
  many rows total — so a consumer knows it's looking at parts of a whole, not the whole.

---

## Permissions

Read-only, on the Managed Identity:

- `DeviceManagementConfiguration.Read.All` — policies and endpoint-security intents
- `Group.Read.All`, `Directory.Read.All` — group metadata and `transitiveMembers`
- `Storage Blob Data Contributor` — to write the CSVs

Every call is a GET. Nothing is written to the tenant.

---

## What we still don't know (honest gaps)

- **Dynamic membership is a rule, not a roster.** "Who is in this dynamic group right now" isn't
  in the snapshot by design — answering it means evaluating the rule against current objects,
  which is a different (and heavier) operation.
- **The summary truncates.** Include/exclude target lists are capped (default 1,500 chars);
  a policy targeting an enormous number of groups will show `...(truncated)`. Rare, but stated
  in the data rather than hidden.
- **Beta drift.** The policy endpoints ride `/beta`; a schema change could alter a type or an
  assignment shape.

---

*Microsoft, Intune, Entra, Microsoft Graph, and Azure are trademarks of the Microsoft group of
companies. Independent content; not endorsed by Microsoft.*
