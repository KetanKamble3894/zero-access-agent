# Collector teardown — Intune Documentation (the prose side)

Most of this pattern is about *structured* data — CSV snapshots the agent counts. This
collector produces the other half: **human-readable documentation** of the Intune and
Windows 365 configuration, rendered to HTML and dropped in the storage account's `reports/`
container. That HTML is what feeds the **`euc-documents`** search index — the prose the
agent quotes when a question is about *how something is configured*, not *how many devices
exist*.

Script: [`scripts/Collect-IntuneDocumentation.ps1`](../../scripts/Collect-IntuneDocumentation.ps1).
Read-only, Managed-Identity. It writes one file per run:
`reports/<OrgName>_Intune_Documentation_<date>.html`.

It leans on a community module — **M365Documentation** by Thomas Kurth — to do the actual
config collection and rendering. The clever part is getting that module to run *unattended,
read-only, with a Managed Identity* when it was built for interactive sign-in.

---

## The core trick: inject a Managed-Identity token into a community module

`M365Documentation` normally authenticates interactively (MSAL). In a runbook there's no
human to sign in — and the whole pattern forbids stored secrets. The solution is a
token-injection sleight of hand:

1. **Get a Graph token from the Managed Identity.** `Get-MiGraphToken` calls
   `Get-AzAccessToken`, and handles the Az.Accounts 5.x change where the token comes back as
   a `SecureString` (it unwraps it via `NetworkCredential`).
2. **Push that token into the module's private state.** `Set-M365DocToken` runs a
   scriptblock *inside the module's scope* with `& $Module { ... }`, setting the module's
   internal `$script:token` and cloud/base-URL variables directly. From that point the
   module makes its Graph calls with the injected read-only token — no MSAL, no secret.
3. **Refresh before it ages out.** Documentation collection can run long, so
   `Update-M365DocTokenIfNeeded` checks the remaining lifetime before each section and
   re-mints + re-injects when under the threshold.

This is the pattern's philosophy applied to third-party code: you don't grant the tool
standing access — you hand it a short-lived, read-only token and re-inject as needed.

---

## Walkthrough

1. **Auth** — `Connect-AzAccount -Identity`, then acquire the initial Graph token.
2. **Storage context** — `New-AzStorageContext -UseConnectedAccount` (data-plane OAuth via
   the same identity; no account key).
3. **Import** the module (and `PSHTML`), grab the module object for the injection.
4. **Inject** the token into module state.
5. **Fail-fast self-test** — `Test-M365DocConnection` issues a single read-only
   `GET /organization`. If the token injection didn't take, it throws *here*, with a clear
   message, instead of dying deep inside the collection loop an hour later.
6. **Resolve sections** — ask the module for the real section tokens for the chosen
   components (`Intune`, `Windows365`), minus any you exclude.
7. **Collect one section per call**, refreshing the token before each, and merge.
8. **De-duplicate, render HTML, upload** to `reports/`.

---

## Two quirks worth knowing (the honest, teachable bits)

**`-IncludeSections` is substring-matched.** You cannot drop `MobileAppDetailed` while
keeping `MobileApp` — filtering on the base token pulls the whole `MobileApp*` family. The
script documents this in a comment so the next person doesn't fight it.

**Substring-family collisions cause double collection.** Because of the above, if the
resolved token list contains both a base token and a longer token that *contains* it, the
same data can be gathered twice. The collector defends against this explicitly: it drops any
token that contains another retained token as a substring, so nothing is collected twice —
then de-duplicates the merged sections by `Title` as a final safety net.

**One component per call, on purpose.** Passing a single component per `Get-M365Doc` call
keeps each returned `[Doc]` object flat (no per-component wrapper), which makes merging a
plain `SubSections` concatenation instead of a nested walk.

---

## Where it fits

```
Intune / Windows 365 config ──(read-only, MI token injected)──▶ M365Documentation ──▶ HTML
        └──▶ Blob reports/ ──▶ Azure AI Search "euc-documents" index ──▶ agent cites config
```

This is the `euc-documents` half of retrieval. The structured collectors (device inventory,
compliance, etc.) feed the `euc-data` index; this one feeds the prose index. Together they
let the agent answer both "how many" and "how is this configured" — all from snapshots,
none from live access.

---

## Permissions

Read-only, on the Managed Identity (the scopes M365Documentation's Intune/Windows365
collectors need — confirm against the module version you install):

- `DeviceManagementConfiguration.Read.All`, `DeviceManagementApps.Read.All`,
  `DeviceManagementManagedDevices.Read.All`
- `Organization.Read.All` (the `GET /organization` self-test), `Directory.Read.All`
- `Storage Blob Data Contributor` on the storage account (to upload the HTML)

All read. The collector never writes to the tenant.

---

## What we still don't know (honest gaps)

- **It depends on a community module's internals.** Injecting into `$script:token` works
  because of how M365Documentation is written today; a future version could change those
  internals. Pin the module version and re-test on upgrade.
- **The substring-match behavior is a moving target** across module versions — re-check the
  section-token list when you upgrade.
- **The HTML is the module's built-in template.** It's serviceable for an index source, but
  it's not styled for public reading; treat it as data for the `euc-documents` index, not as
  a polished artifact.

---

## Credit & license

Huge thanks to **Thomas Kurth** for the **M365Documentation** module —
<https://github.com/ThomasKur/M365Documentation> — which does the real work of collecting and
rendering the Microsoft 365 / Intune configuration here. This collector's only contribution is
running that module unattended and read-only via an injected Managed-Identity token, as the
document source for a zero-access agent.

M365Documentation is licensed **GPL-3.0**. This collector *depends on* it — you install the
module yourself from the PowerShell Gallery — and does not copy or redistribute its code, so
this script stays MIT. The module's source is intentionally **not** vendored into this repo;
link to it and install it separately. (Not legal advice — the conservative, standard reading
of "use vs. distribution" under the GPL.)

*Microsoft, Intune, Entra, Microsoft Graph, Azure, and Windows 365 are trademarks of the
Microsoft group of companies. Independent content; not endorsed by Microsoft.*
