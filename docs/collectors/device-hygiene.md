# Collector teardown — Device Hygiene (the offboarding / ghost-device finder)

Every fleet accumulates ghosts: laptops still enrolled under people who left, corporate
devices with no owner, machines that haven't checked in for months. This collector finds
them, explains *why* each one is flagged, and — uniquely among the collectors — **recommends
an action** for a human to take.

Script: [`scripts/Collect-DeviceHygiene.ps1`](../../scripts/Collect-DeviceHygiene.ps1).
Read-only, Managed-Identity. It writes one enriched CSV to `agent-data/`.

> **Beta endpoint.** Managed devices and `$batch` use `/beta`; users, devices, and audit logs
> use `/v1.0`. Re-verify after Graph updates.

## The two buckets (and what's deliberately left out)

- **Disabled-user devices** — the device's primary user has a *disabled* Entra account
  (`accountEnabled eq false`, `userType eq 'Member'`). Classic offboarding residue.
- **Orphaned corporate devices** — company-owned, no primary user at all.

And the honest exclusions, so the report isn't noisy:

- **Personal BYOD without a user** is *expected*, not a problem — excluded.
- **AVD/WVD session hosts** (name prefixes) are shared, so "primary user" is meaningless for
  them — excluded after fetch.

Naming what you *don't* flag is as important as what you do; it's the difference between a
report people act on and one they learn to ignore.

## Enrichment: four joins, mostly batched

A flagged device is only useful with context, so each row is enriched from four places:

- **User profile + manager + licences** — three Graph calls per user, sent via `$batch`.
- **The account-disabled date** — from the Entra audit log.
- **The Entra device object** — is it still enabled? what's its risk level?
- **Lenovo warranty** — read from Notes (written by the warranty enrichment tool).

Two hard-won details in how it batches:

**It addresses users by object ID, not UPN.** Building `$batch` child URLs with a `%40`-encoded
UPN as the final path segment trips Graph's URL parsing, so the collector resolves each UPN to
its object id first and uses `/users/{id}`. A small thing that saves a baffling debugging
session.

**The batch helper retries only the throttled children.** When a `$batch` POST comes back with
some children at `429`, it doesn't resend the whole chunk — it filters to just the throttled
ids, waits the `Retry-After`, and resubmits only those. Efficient, and gentle on the service.

## The audit-log honesty

Getting the *date an account was disabled* means querying `directoryAudits` for the last
"Update user" event that set `AccountEnabled` to `false`. Two honest realities are baked in:

- **Retention is finite** (30 days on P1, 90 on P2 Entra). If the disable happened before the
  window, the row says **"Before audit log retention"** — not a guess, not a blank.
- **That endpoint throttles hard.** The collector enforces a 1-second minimum between calls on
  top of `Retry-After` backoff. It's the slowest step, on purpose.

## It recommends, but never acts

`Get-RecommendedAction` is a small priority-ordered rules engine: device risk high/medium →
*urgent investigate*; Entra object already disabled → *confirm wipe*; orphaned + inactive →
*retire*; co-managed → *coordinate retire in Intune and SCCM*; stale hybrid → *check the
on-prem AD object*; and so on. Each row also gets an **ActionOwner** — the user's manager if
known, otherwise the service desk.

This is the pattern's philosophy at the sharp end: the triage logic lives *once*, in the
reviewed read-only job, so the output is decision-ready. But it only ever **recommends** — the
wipe, the retire, the disable are a human's call. The collector reads and reasons; it never
acts on the tenant.

## Permissions

Read-only, on the Managed Identity:

- `DeviceManagementManagedDevices.Read.All` — managed devices + Notes
- `User.Read.All`, `Directory.Read.All` — users, manager, licences, device objects
- `Device.Read.All` — Entra device object (enabled, risk)
- `AuditLog.Read.All` — `directoryAudits` + `signInActivity`
- `Storage Blob Data Contributor` — to write the CSV

Every call is a GET. Nothing is written to the tenant.

## What we still don't know (honest gaps)

- **The recommended action is a heuristic, not a verdict.** It's a well-reasoned default to
  speed a human decision — it is not authorization to wipe anything. Treat it as the first line
  of a review, not the last.
- **Disabled dates fall off a cliff.** Anything older than audit retention is honestly labelled
  rather than fabricated.
- **This file is identity-rich.** Unlike the pre-aggregated stats, the hygiene report carries
  UPNs, names, and managers by necessity — it's an offboarding worklist. In a real tenant that
  makes it sensitive; in this repo it's synthetic. Mind who can read the index it feeds.
- **No size gate here.** Because the two buckets are usually small, this collector writes a
  single file straight to `agent-data/` without the ~12 MB gate the others apply — worth adding
  if your disabled/orphaned population is unusually large.

---

*Microsoft, Intune, Entra, Microsoft Graph, and Azure are trademarks of the Microsoft group of
companies; Lenovo is a trademark of Lenovo. Independent content; not endorsed by Microsoft or
Lenovo.*
