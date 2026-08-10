# Collector teardown — Autopilot Operations (the honest one)

Autopilot / ESP reporting is genuinely hard to do truthfully, and this collector is the one that
shows the most working-out. It produces one row per recently-enrolled Windows device describing
how its deployment went — status, ESP phase, scenario, duration, and a *potential* failure cause
— by stitching together five different sources. Its real lesson isn't any single technique; it's
how carefully it refuses to state more than the data supports.

Script: [`scripts/Collect-AutopilotOperations.ps1`](../../scripts/Collect-AutopilotOperations.ps1).
Read-only, Managed-Identity. Writes `Autopilot_Operations_Detailed.csv` + a grouped
`Autopilot_Operations_Summary.csv` to `root/`, with size-gated copies to `agent-data/`.

> **Beta endpoint.** Managed devices, autopilotEvents, enrollment configs, mobileApps and reports
> use `/beta`; devices/users/audit use `/v1.0`.

## Five sources, one row

Each device row is assembled from: managed devices (recent Windows enrolments), Autopilot device
identities (group tag, profile assignment), Autopilot deployment events, the ESP-tracked app set
and its per-app install reports, and — gated to suspicious devices only — the Entra device object
and user location. The stitching is the work; no single endpoint tells you "how did this
deployment go."

## The honesty, which is the point

**"Current app state" is not "the app that failed the ESP."** The install report tells you what's
failing *now*, not what failed *during* setup — an app that failed ESP and later healed reads
clean. Rather than pretend otherwise, the fields are named `Current*`, and a failed device with no
currently-failing app is honestly labelled "possible transient/self-healed" with a note that
exact ESP-time attribution is device-side only on Autopilot v1. It states the limit instead of
inventing a cause.

**An evidence-based classifier, not a remembered enum.** `Get-AppRowClassification` only treats a
row as a failure for install-state/detail tuples it has actually *seen* mean failure; everything
else is logged to a tuple inventory and treated as non-evidence, never guessed into a bucket. The
run prints that inventory so you extend the whitelist from observed data — because the detail
field has non-failure nonzero values (pending-reboot class) that must not read as failures.

**A join it proves rather than assumes.** The app report joins to devices by id, falling back to
name — but a name that maps to more than one device id (reimaged machines reuse names) is marked
*Ambiguous* and produces **no** attribution, because a wrong attribution is worse than none. The
run prints join telemetry (`byManagedDeviceId` / `byDeviceName` / `ambiguous` / `notInReport`) so
each run is its own evidence for whether the id-join is holding.

**A mapping it flags as unofficial.** `Get-DeploymentScenario` maps the event's `enrollmentType`
to a friendly scenario, but the comment is explicit that Microsoft publishes no formal
scenario-to-enum crosswalk, so the raw value is published alongside the label and unrecognised
values pass through as `Unrecognised: <raw>`.

## Cheap by default, expensive only when it matters

The costly enrichment (Entra device object, group membership, user location) runs only for
devices that look *suspicious* — failed, in-progress, reimaged, slow, or non-compliant. A clean
fast deployment is written from the data already in hand. Same principle as the app-failures
collector: spend the expensive calls only where they change the answer.

## Permissions

Read-only, on the Managed Identity: `DeviceManagementManagedDevices.Read.All`,
`DeviceManagementServiceConfig.Read.All`, `DeviceManagementConfiguration.Read.All`,
`DeviceManagementApps.Read.All`, `Device.Read.All`, `Directory.Read.All`, `User.Read.All`, and
optionally `AuditLog.Read.All`; plus `Storage Blob Data Contributor`. Every call is a GET or a
reports export job — nothing is written to the tenant. Set `$AppAssignmentGroupNames` to your own
group naming patterns.

## What we still don't know (honest gaps)

- **ESP-time attribution.** Autopilot v1 keeps the exact "what failed during setup" only on the
  device; the report can only show current state. This collector says so rather than guessing.
- **The audit-correlation apparatus is a deletion candidate.** It's marked as such in the code: if
  the audit query keeps returning zero rows in your tenant, those steps are dead weight and should
  be removed.
- **The scenario mapping is community-validated, not official** — trust the raw `enrollmentType`
  over the label where they disagree.

---

*Microsoft, Intune, Entra, Windows, Microsoft Graph, and Azure are trademarks of the Microsoft
group of companies. Independent content; not endorsed by Microsoft.*
