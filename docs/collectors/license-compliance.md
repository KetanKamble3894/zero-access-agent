# Collector teardown — License Compliance

The simplest collector in the set, and a good one to read first: it answers "which corporate
Windows devices have a primary user who is *missing* an Intune and/or Windows Enterprise
license" — a question that's tedious by hand and trivial once the data is a snapshot.

Script: [`scripts/Collect-LicenseComplianceCheck.ps1`](../../scripts/Collect-LicenseComplianceCheck.ps1).
Read-only, Managed-Identity. Writes `License_Compliance.csv` to `root/` (Power BI) and a
size-gated copy to `agent-data/`.

> **Beta endpoint.** Managed devices use `/beta`; users and licenses use `/v1.0`.

## How it works

1. Pull Windows, company-owned managed devices that have a primary user.
2. For each **distinct** user (cached, so a user with five devices is checked once), read their
   assigned license SKUs.
3. Compare against two configurable sets — `$IntuneSKUs` and `$WindowsEnterpriseSKUs`. If either
   entitlement is missing, the device is reported with the user's manager, department, and
   location so a real person can act on it.

The per-user cache is the only performance trick it needs: license checks are per user, devices
are per device, and a fleet has far more devices than users.

## Two small touches worth copying

- **Friendly license names.** Raw SKUs like `SPE_E3` mean nothing to most readers, so it resolves
  them through Microsoft's public "Product names and service plan identifiers" mapping
  (`License_Details.csv`, which you keep in the container). A missing mapping degrades to the raw
  SKU — never breaks.
- **An explicit all-clear row.** If nobody is missing a license, the CSV isn't empty — it carries
  a single "ALL CLEAR" row with the date. An empty file is ambiguous ("did it run? did it fail?");
  an explicit all-clear is an answer. The agent can say "everyone's licensed as of the 28th"
  instead of finding nothing.

## Permissions

Read-only, on the Managed Identity: `DeviceManagementManagedDevices.Read.All`, `User.Read.All`,
`Directory.Read.All` (user detail, manager, `licenseDetails`), plus `Storage Blob Data
Contributor`. Every call is a GET; nothing is written to the tenant.

## What we still don't know (honest gaps)

- The SKU lists define what "licensed" means; they're configurable because every tenant's
  entitlement mix differs. Get them wrong and the report is wrong — they're the one thing to
  review before trusting the output.
- The `employeeType` filter scopes which account types are checked; adjust it to match how your
  tenant classifies users.

---

*Microsoft, Intune, Entra, Microsoft Graph, and Azure are trademarks of the Microsoft group of
companies. Independent content; not endorsed by Microsoft.*
