<#
    read-only-gate.ps1  —  the founding artifact of the Zero-Access Pattern.

    THE IDEA
    --------
    The Zero-Access Pattern claims that its collectors *cannot* write to your
    tenant. Most projects ask you to take that on trust. This script makes the
    claim executable: it runs AS the identity a collector uses, asks Microsoft
    Graph which application permissions that identity actually holds, and
    HARD-FAILS the run if any of them is not read-only.

    So the boundary is enforced by architecture, not by good intentions — if
    someone ever grants a write scope to the managed identity, the gate throws
    and the collector never gets to make its first call.

    HOW TO USE IT
    -------------
      • Standalone audit:  run it and read the report / exit code.
      • As a guard:        dot-source it at the top of every collector runbook —
                           `. .\read-only-gate.ps1` — so the collector aborts
                           before it touches Graph if the identity isn't clean.

    REQUIREMENTS
    ------------
      • Runs as a system-assigned Managed Identity (Connect-MgGraph -Identity).
      • To read its OWN permissions it needs a directory read scope —
        `Directory.Read.All` or `Application.Read.All`. Both are read-only and
        already part of the pattern; the gate simply reports them as such.
      • Module: Microsoft.Graph.Authentication (for Invoke-MgGraphRequest).
        Deliberately no full SDK — the Graph calls stay visible and light.

    HONEST CAVEAT
    -------------
      This verifies the app roles *granted* to the identity. It is a guardrail,
      not a licence to be careless: the first line of defence is still never
      granting a write scope. The gate is what catches the day someone does.
#>

[CmdletBinding()]
param(
    # A granted Graph app role counts as read-only if its value ends with one
    # of these suffixes...
    [string[]]$ReadOnlySuffixes = @('.Read.All', '.Read'),

    # ...or is on this explicit allow-list (rare read scopes that don't fit the
    # suffix rule). Keep this list tiny and reviewed.
    [string[]]$ReadOnlyExceptions = @(),

    # Report and warn instead of throwing. Use for a dry-run audit; leave OFF
    # when the gate guards a real collector.
    [switch]$ReportOnly
)

$ErrorActionPreference = 'Stop'
$GraphAppId = '00000003-0000-0000-c000-000000000000'   # Microsoft Graph, well-known

function Test-ReadOnlyRole {
    param([string]$Role)
    if ([string]::IsNullOrWhiteSpace($Role)) { return $false }
    if ($ReadOnlyExceptions -contains $Role) { return $true }
    foreach ($suffix in $ReadOnlySuffixes) {
        if ($Role.EndsWith($suffix)) { return $true }
    }
    return $false
}

function Get-AllPages {
    param([string]$Uri)
    $items = @()
    do {
        $page   = Invoke-MgGraphRequest -Method GET -Uri $Uri
        $items += $page.value
        $Uri    = $page.'@odata.nextLink'
    } while ($Uri)
    return $items
}

# --- Authenticate AS the managed identity -------------------------------------
Connect-MgGraph -Identity -NoWelcome
$ctx = Get-MgContext
if (-not $ctx.ClientId) { throw "No Managed Identity context — run this under a system-assigned identity." }

# --- Resolve the identity's own service principal -----------------------------
$miSp = (Get-AllPages "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($ctx.ClientId)'")[0]
if (-not $miSp) { throw "Could not resolve the managed identity's service principal (need Directory.Read.All or Application.Read.All)." }

# --- Map Microsoft Graph's app-role IDs to their human-readable values ---------
$graphSp = (Get-AllPages "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$GraphAppId'")[0]
$roleMap = @{}
foreach ($role in $graphSp.appRoles) { $roleMap[$role.id] = $role.value }

# --- What Graph roles is THIS identity actually granted? -----------------------
$assignments = Get-AllPages "https://graph.microsoft.com/v1.0/servicePrincipals/$($miSp.id)/appRoleAssignments"
$graphGrants = $assignments | Where-Object { $_.resourceId -eq $graphSp.id }

$results = foreach ($a in $graphGrants) {
    $value = $roleMap[$a.appRoleId]
    [pscustomobject]@{
        Role     = if ($value) { $value } else { "(unknown role id $($a.appRoleId))" }
        ReadOnly = Test-ReadOnlyRole $value
    }
}

# --- Report -------------------------------------------------------------------
Write-Output "Zero-Access read-only gate — identity: $($miSp.displayName)  [$($ctx.ClientId)]"
$results | Sort-Object Role | ForEach-Object {
    "{0}  {1}" -f $(if ($_.ReadOnly) { '[read ]' } else { '[WRITE]' }), $_.Role
} | Write-Output

# --- Verdict ------------------------------------------------------------------
$writes = @($results | Where-Object { -not $_.ReadOnly })

if ($writes.Count -gt 0) {
    $bad = ($writes.Role -join ', ')
    if ($ReportOnly) {
        Write-Warning "GATE WOULD FAIL — write-capable Graph roles granted: $bad"
    } else {
        throw "READ-ONLY GATE FAILED — write-capable Graph roles granted: $bad. Refusing to run the collector."
    }
} else {
    Write-Output "READ-ONLY GATE PASSED — $($results.Count) Graph role(s), all read-only. Safe to collect."
}
