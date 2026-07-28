# Collector teardown — App Deployment Failures (expertise as data)

This is the collector that best shows *why* the zero-access pattern is worth building: it
doesn't just list which app installs failed — it **triages** each one into a category, an owner
team, an escalation tier, concrete remediation steps, and a plain-English sentence to tell the
user. The agent then answers "why did Acme CRM fail on 40 machines and what do we do" with a
specific answer, because the expertise is sitting in the snapshot as data.

Script: [`scripts/Collect-AppDeploymentFailures.ps1`](../../scripts/Collect-AppDeploymentFailures.ps1).
Read-only, Managed-Identity. It writes:

- `root/App_Deployment_Failures.csv` — full, for Power BI
- `agent-data/App_Deployment_Failures_Slim.csv` — slim, for the index
- `agent-data/Triage_Category_Guidance.csv` — one row per category (the user-facing phrases)

> **Beta endpoint.** Uses `/beta` for the reports export jobs. Re-verify after Graph updates.

## Aggregate first, then drill down

Pulling per-device install status for *every* app in a large tenant is enormous. So the
collector inverts it: it first pulls the **AppInstallStatusAggregate** report to find which apps
actually *have* failures, sorts by failed-device count, and only drills into the top N
(default 50) with per-app export jobs. Most apps have zero failures and are never touched. This
is what makes it run in minutes instead of hours — do the cheap query to decide where the
expensive query is worth it.

## The triage map — the actual moat

`Get-TriageInfo` is a hashtable keyed by error code (`0x80070643`, `1603`, `0x87D00607`, …).
Each entry carries five fields: category, owner team, escalation tier, remediation steps, and
what-to-tell-the-user. That table is hard-won EUC knowledge turned into data — the difference
between an AI answer that says "the install failed" and one that says "fatal MSI error, route
to L2, enable verbose logging with `/l*v`, check for AV interference." An AI summary of the web
can't produce that; it comes from having fixed these failures.

Three fallbacks keep it honest when the code is unknown: it matches on the state-detail text
(dependency / download / detection / reboot / disk), then on the install state, and only then
lands on a labelled "Unknown" that tells you to extend the map. The map is designed to grow —
every new failure you diagnose becomes a new row, and the next occurrence auto-classifies.

## Correlation: is it the app, or the device?

A single flat list of failures hides the real story. The correlation pass stamps three patterns
onto every row:

- **Repeat-offender devices** — a device failing ≥N *distinct* apps is a device problem (IME
  health, disk, AV, certs), not an app problem, and the remediation text is rewritten to say so.
- **Dominant error per app** + **possible regression** — if an app suddenly fails on many
  devices at a high rate, it's flagged `YES - INVESTIGATE` (a package/version change, most
  likely).
- **Ticket routing** — an app failing on ≥N devices routes to the EUC team with a log-collection
  checklist; a one-off routes to the service desk with the self-fix info.

## Output shaping for the agent

The slim `agent-data` copy drops the heavy columns and keeps what the agent reasons on. The tiny
`Triage_Category_Guidance.csv` — one row per category with the user-facing phrase — means a
question like "what do I tell the user whose install is stuck on a reboot" retrieves a single
clean document instead of scanning thousands of failure rows.

## Permissions

Read-only, on the Managed Identity: `DeviceManagementApps.Read.All`,
`DeviceManagementManagedDevices.Read.All`, `User.Read.All` (optional location), plus
`Storage Blob Data Contributor`. Every call is a GET or a reports export job; nothing is written
to the tenant. `OwnerTeam` labels ("EUC-Team", "ServiceDesk") are placeholders — rename to your
own teams.

## What we still don't know (honest gaps)

- The triage map covers the common documented codes; a code that isn't in it falls to the
  text/state fallbacks and, ultimately, a labelled Unknown. Coverage grows only as you extend it.
- Aggregate-first means apps ranked below the top-N cap in a given run aren't drilled into — the
  run metadata logs how many that was, so the cap is visible, not silent.

---

*Microsoft, Intune, Entra, Microsoft Graph, and Azure are trademarks of the Microsoft group of
companies. Independent content; not endorsed by Microsoft. The error-code guidance is a starting
point — verify against your own environment.*
