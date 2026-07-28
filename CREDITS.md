# Credits & acknowledgments

This project stands on work done by the Microsoft endpoint-management community. The
zero-access *architecture* is what's added here; much of the collection and reporting
groundwork is theirs, and it's credited honestly.

## Tools this project uses

**M365Documentation** — Thomas Kurth
<https://github.com/ThomasKur/M365Documentation>
Collects and renders Microsoft 365 / Intune configuration as documentation. The Intune
documentation collector in this repo runs it unattended and read-only via an injected
Managed-Identity token.
*Licensed **GPL-3.0**. This repo depends on the module (installed separately from the
PowerShell Gallery) and does **not** copy or redistribute its source, so this repo remains
MIT. The module's code is intentionally not vendored here.*

## Prior art and inspiration

**SMSAgent (Trevor Jones)** — <https://smsagent.blog> and <https://docs.smsagent.blog>
The Azure Automation → Blob CSV → Power BI reporting approach used throughout this project
is well-established in the community, and SMSAgent's MEM-reporting templates (managed
devices, Windows 11 hardware readiness, Patch My PC, Windows Update for Business, and more)
predate this repo. This project claims no primacy over that reporting pipeline — its
contribution is the read-only-by-construction discipline and the zero-access AI agent layer
built on top.

## The rest

More names will be added here as the repo grows — the Graph-teardown work in particular
leans on community tools and people (e.g. Graph X-Ray and Merill Fernando's work), which
will be credited by name as they're used.

If you see your work reflected here and want the credit worded differently — or removed —
open an issue.

---

*Microsoft, Microsoft 365, Intune, Entra, Microsoft Graph, Azure, and Power BI are
trademarks of the Microsoft group of companies. Independent content; not affiliated with or
endorsed by Microsoft.*
