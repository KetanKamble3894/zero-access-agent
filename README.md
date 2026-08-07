# Zero-Access Agent

**An AI agent that answers questions about your whole Microsoft endpoint fleet in plain English — while holding zero access to any live system.**

> "How many devices fail Firewall in Finland?" · "Which Lenovos are out of warranty?" · "Is Ollama installed anywhere, and is it approved?"
>
> The agent answers all of it — and holds **no Graph scope, no key, and no connection to Intune, Entra or any live tenant.** Its entire world is two read-only search indexes built from sanitized, dated snapshots.

Full write-up (the *why*, the architecture, and the honest trade-offs): **[The read-only AI agent that can't touch your tenant](https://ketankamble.com/blog/the-read-only-ai-agent-that-cant-touch-your-tenant/)** · more at **[ketankamble.com](https://ketankamble.com/)**.

---

## The idea — the Zero-Access Pattern

Most "chat with your Intune data" builds hand an AI live access to Microsoft Graph and trust it not to misuse it. This one removes the trust from the equation by **separating reading the estate from answering about it**:

1. **Collect** — scheduled, read-only collectors run as Azure Automation runbooks under a **Managed Identity holding only `*.Read.All` Graph scopes** — no write or action permission of any kind. Each writes a **sanitized CSV snapshot** plus a `_Stats` file with counts already computed.
2. **Store** — snapshots land in Azure Blob: full files feed Power BI; slim copies feed the agent.
3. **Index** — two Azure AI Search indexes: `fleet-structured` (one document per report row) and `fleet-docs` (vector-embedded configuration documentation).
4. **Answer** — a Foundry (Azure AI Foundry) agent whose **only tool is Azure AI Search**. No Graph connector, no code interpreter, no way to call out.
5. **Ask** — you ask in plain English; the agent searches, grounds its answer in the retrieved rows, and names the report the fact came from.

The containment is **structural**: there is no tool that can act, so nothing the agent is told to do can reach the tenant. Worst case, it reads a dated snapshot you could already export from Power BI.

> The architecture diagram and a full walkthrough are in the [capstone post](https://ketankamble.com/blog/the-read-only-ai-agent-that-cant-touch-your-tenant/).

---

## The read-only guarantee

The "it only reads" claim is enforced, not asserted:

- The collectors' Managed Identity is granted **only `.Read.All` application scopes**. It cannot write to the tenant.
- **`read-only-gate.ps1`** runs *as* the identity, asks Graph which application permissions it actually holds, and **refuses to run if any of them can write.** Dot-source it at the top of every runbook:

  ```powershell
  . .\read-only-gate.ps1     # throws if the identity can write — the collector never runs
  # ...collector logic only reaches here on a clean, read-only identity...
  ```

- The agent connects to Azure AI Search with a **query key, never an admin key**, and personal fields are minimised **at the collector** before they ever reach an index — the system prompt is a behavioural layer on top, not the only control.

> **One honest exception.** The repo ships **one** optional, human-run enrichment utility ([`tools/Enrich-LenovoWarrantyToNotes.ps1`](./tools/Enrich-LenovoWarrantyToNotes.ps1)) that can write device **warranty** into the Notes field. It is fenced off, opt-in, defaults to a read-only report, and named openly rather than hidden. The agent never touches it.

---

## What's in here

| Path | What it is |
|---|---|
| [`scripts/`](./scripts/) | The read-only collectors (`Collect-*.ps1`) plus `New-SyntheticFleet.ps1` for generating a synthetic lab fleet. |
| [`tools/`](./tools/) | The opt-in Lenovo warranty enrichment utility (the one honest write-exception). |
| [`azure-ai-search/`](./azure-ai-search/) | Copy-paste index definitions (`fleet-structured`, `fleet-docs`), the agent's sanitized system prompt, and a README on creating the indexes. |
| [`docs/`](./docs/) | Build-it-yourself walkthrough, Azure Automation setup, and per-collector notes. |
| [`CREDITS.md`](./CREDITS.md) | Community tools and prior art this stands on (M365Documentation, SMSAgent). |
| [`ROADMAP.md`](./ROADMAP.md) | What's shipped and what's next. |
| [`LICENSE`](./LICENSE) | MIT. |

The collectors ship progressively — the [full ten-collector series](https://ketankamble.com/blog/) is written up on the site, and `ROADMAP.md` tracks which are in the repo.

---

## Quick start

1. **Stand up the collect layer** — follow [`docs/azure-automation-setup.md`](./docs/azure-automation-setup.md): a resource group, an Automation account with a system-assigned Managed Identity (no secrets), storage, and **read-only `.Read.All` Graph roles**.
2. **Import the collectors** from [`scripts/`](./scripts/) as PowerShell 7.2 runbooks, dot-source `read-only-gate.ps1` at the top of each, publish, and schedule them. No live tenant? Generate one with `New-SyntheticFleet.ps1`.
3. **Create the two search indexes** from [`azure-ai-search/`](./azure-ai-search/) and point indexers at the snapshots.
4. **Create the Foundry agent** with Azure AI Search as its only tool and paste in the system prompt from [`azure-ai-search/agent-system-prompt.md`](./azure-ai-search/agent-system-prompt.md).

The end-to-end walkthrough is in [`docs/build-it-yourself.md`](./docs/build-it-yourself.md) and the [capstone post](https://ketankamble.com/blog/the-read-only-ai-agent-that-cant-touch-your-tenant/).

---

## Security notes

- Everything runs read-only by construction; `read-only-gate.ps1` is the backstop for the day discipline slips.
- Lock the Azure AI Search query key with RBAC; minimise personal fields at the collector.
- All sample data in this repo is **synthetic** (`@contoso.com` / `contoso.onmicrosoft.com`). No real tenant, users, or devices.

## License & credits

- **MIT** — see [`LICENSE`](./LICENSE).
- Built on community work — see [`CREDITS.md`](./CREDITS.md). Notably, the Intune Documentation collector uses **[M365Documentation](https://github.com/ThomasKur/M365Documentation)** by Thomas Kurth (GPL) as an **install-only** dependency (installed from the PowerShell Gallery, not vendored here), so this repo stays MIT.

## Disclaimer

Independent content — **not affiliated with, sponsored by, or endorsed by Microsoft.** Microsoft, Intune, Entra, Microsoft Graph, Azure and Power BI are trademarks of the Microsoft group of companies. Everything here comes from a personal lab; verify in your own tenant before relying on it.
