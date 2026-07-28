#requires -Version 7.0
<#
.SYNOPSIS
    Collect-PolicyAssignments.ps1 — the policy-assignment collector for the Zero-Access
    Pattern. Read-only, Managed-Identity, pre-aggregating.

.DESCRIPTION
    Sweeps every Intune policy type (compliance, configuration profiles, settings catalog,
    endpoint-security intents), flattens their assignments, resolves each targeted group once
    (static groups → members; dynamic groups → membership rule), flags assignments pointing
    at deleted groups, and writes a family of CSVs:

      root/ (full, with IDs — for Power BI):
        PolicyAssignments.csv, UnassignedPolicies.csv, PolicyGroupMembership(.csv|_Part###),
        DeletedGroupAssignments.csv, DynamicGroupRules.csv, PolicyAssignments_Summary.csv
      agent-data/ (slim, no IDs, size-gated — for the search index): the same set

    The per-policy Summary is the important one for the agent: ONE row per policy carrying the
    COMPLETE include/exclude targeting, so the agent answers "who is this assigned to" from a
    single complete document instead of a partial sample of assignment rows.

    Read-only throughout — every call is a GET. Nothing is written to the tenant.

.NOTES
    GENERIC / PARAMETERIZED: no resource group, storage account, or container is hardcoded.
    Run against a personal lab tenant only.

    BETA ENDPOINT: policy lists use https://graph.microsoft.com/beta; group resolution uses
    /v1.0. Beta endpoints can change without notice — re-verify after Graph updates.

    Read-only Graph app roles on the Managed Identity:
      DeviceManagementConfiguration.Read.All   (policies + endpoint-security intents)
      Group.Read.All, Directory.Read.All       (group metadata + transitiveMembers)
    Plus "Storage Blob Data Contributor" on the storage account (to write CSVs).

    MIT licensed. Microsoft, Intune, Entra, Microsoft Graph and Azure are trademarks of the
    Microsoft group of companies. Independent content; not endorsed by Microsoft. Verify every
    endpoint and permission in your own lab tenant before relying on it.
#>

# ===========================================================================
#  CONFIGURE ME  ->  set these to your own values, then run.
#  These three lines are the only thing you MUST change.
# ===========================================================================
$ResourceGroup  = "<your-resource-group-name>"     # resource group that holds your storage account
$StorageAccount = "<your-storage-account-name>"    # storage account name (lowercase, globally unique)
$Container      = "<your-container-name>"           # blob container, e.g. "intune-report"

# -- optional settings (safe to leave as they are) --------------------------
$Keyword = ""   # optional filter: leave empty for everything (e.g. "Compliance","USB","BitLocker")
# ===========================================================================

# Safety net - stop if the placeholders above weren't replaced.
if ("$ResourceGroup $StorageAccount $Container" -match '<your-') {
    throw "Please set ResourceGroup, StorageAccount, and Container at the top of the script before running."
}

# --- Step 1: Initialize Variables
$GraphBase   = "https://graph.microsoft.com/beta"
$GraphBaseV1 = "https://graph.microsoft.com/v1.0"

$ExportDir = $env:TEMP
$Today     = Get-Date -Format 'yyyy-MM-dd'

$ProgressPreference = 'SilentlyContinue'
$VerbosePreference  = 'Continue'

# Hardening options
$MaxGraphRetries               = 8
$BaseRetrySeconds              = 3
$InterRequestDelayMs           = 75
$GroupChunkRowCount            = 250000
$EnableGroupMembershipChunking = $true
$UploadChunkFilesToAgentData   = $true

# Cap for the semicolon-joined target lists in the summary file
$TargetListMaxChars = 1500

Write-Verbose "Script started at $(Get-Date)"


# --- Step 2: Authenticate with Azure Managed Identity
function Get-ManagedIdentityToken {
    $url = $env:IDENTITY_ENDPOINT
    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("X-IDENTITY-HEADER", $env:IDENTITY_HEADER)
    $headers.Add("Metadata", "True")
    $body = @{ resource = 'https://graph.microsoft.com/' }

    Write-Verbose "Obtaining access token"
    $token = (Invoke-RestMethod $url -Method 'POST' -Headers $headers -ContentType 'application/x-www-form-urlencoded' -Body $body).access_token
    Write-Verbose "Access token obtained successfully"
    return $token
}

$accessToken = Get-ManagedIdentityToken
$script:Headers = @{ 'Authorization' = "Bearer $accessToken" }


# --- Step 3: Get storage account context
try {
    $StorageAccountContext = (Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $StorageAccount).Context
    Write-Verbose "Storage account context obtained successfully"
}
catch {
    Write-Error "Failed to get storage account context: $_"
    return
}


# --- Step 4: Graph GET with retry + pagination
function Invoke-MyGraphGetRequest {
    param (
        [Parameter(Mandatory = $true)]
        [string]$URL
    )

    Write-Verbose "Sending request to $URL"
    $AllResults = @()
    $NextUrl = $URL

    while ($NextUrl) {
        $Attempt = 0
        $Succeeded = $false

        while (-not $Succeeded -and $Attempt -lt $MaxGraphRetries) {
            $Attempt++

            try {
                $Response = Invoke-WebRequest -Uri $NextUrl -Method GET -Headers $script:Headers -UseBasicParsing -ErrorAction Stop
                $Succeeded = $true

                if ($InterRequestDelayMs -gt 0) {
                    Start-Sleep -Milliseconds $InterRequestDelayMs
                }

                Write-Verbose "Received response from $NextUrl"
                $ResponseData = $Response.Content | ConvertFrom-Json

                if ($null -ne $ResponseData.value) {
                    $AllResults += $ResponseData.value
                    $NextUrl = $ResponseData.'@odata.nextLink'
                }
                else {
                    return $ResponseData
                }
            }
            catch {
                $StatusCode = $null
                $RetryAfter = $null

                if ($_.Exception.Response) {
                    try { $StatusCode = [int]$_.Exception.Response.StatusCode } catch {}
                    try { $RetryAfter = $_.Exception.Response.Headers['Retry-After'] } catch {}
                }

                if ($StatusCode -in 429, 503, 504) {
                    $WaitSeconds = if ($RetryAfter) {
                        [int]$RetryAfter
                    }
                    else {
                        [math]::Min(60, ($BaseRetrySeconds * [math]::Pow(2, ($Attempt - 1))))
                    }

                    Write-Warning "Transient Graph error $StatusCode for $NextUrl. Retry $Attempt/$MaxGraphRetries after $WaitSeconds seconds."
                    Start-Sleep -Seconds $WaitSeconds
                }
                else {
                    Write-Warning "Failed to fetch data from ${NextUrl}: $_"
                    return $null
                }
            }
        }

        if (-not $Succeeded) {
            Write-Warning "Exceeded retry count for $NextUrl"
            return $null
        }
    }

    return $AllResults
}


# --- Step 5: Define policy endpoints to sweep
$PolicyEndpoints = @(
    @{
        Type = 'Compliance'
        ListUri = "$GraphBase/deviceManagement/deviceCompliancePolicies?`$expand=assignments"
        AssignmentMode = 'ExpandedOnly'
        AssignmentsUri = $null
    }
    @{
        Type = 'ConfigurationProfile'
        ListUri = "$GraphBase/deviceManagement/deviceConfigurations?`$expand=assignments"
        AssignmentMode = 'ExpandedOnly'
        AssignmentsUri = $null
    }
    @{
        Type = 'SettingsCatalog'
        ListUri = "$GraphBase/deviceManagement/configurationPolicies?`$expand=assignments"
        AssignmentMode = 'ExpandedOnly'
        AssignmentsUri = $null
    }
    @{
        Type = 'EndpointSecurity'
        ListUri = "$GraphBase/deviceManagement/intents"
        AssignmentMode = 'PerPolicy'
        AssignmentsUri = "$GraphBase/deviceManagement/intents/{0}/assignments"
    }
)


# --- Step 6: Helper functions
function Get-PolicyName($p) {
    foreach ($f in 'displayName', 'name') {
        if ($p.$f) { return $p.$f }
    }
    return $p.id
}

function Get-PolicyAssignments {
    param(
        [Parameter(Mandatory = $true)]$Policy,
        [Parameter(Mandatory = $true)]$Endpoint
    )

    switch ($Endpoint.AssignmentMode) {
        'PerPolicy' {
            $uri = [string]::Format($Endpoint.AssignmentsUri, $Policy.id)
            $assignments = Invoke-MyGraphGetRequest -URL $uri
            return @($assignments)
        }
        'ExpandedOnly' {
            return @($Policy.assignments)
        }
        default {
            return @()
        }
    }
}


# --- Step 7: Sweep policies, flatten assignments, collect distinct group IDs
$assignmentRows = [System.Collections.Generic.List[object]]::new()
$groupIds       = [System.Collections.Generic.HashSet[string]]::new()

foreach ($ep in $PolicyEndpoints) {
    Write-Verbose "Sweeping $($ep.Type)"
    $policies = Invoke-MyGraphGetRequest -URL $ep.ListUri

    if (-not $policies) {
        Write-Warning "No data returned for $($ep.Type)"
        continue
    }

    foreach ($pol in $policies) {
        $polName = Get-PolicyName $pol

        if ($Keyword -and
            ($polName -notmatch [regex]::Escape($Keyword)) -and
            ($ep.Type -notmatch [regex]::Escape($Keyword))) {
            continue
        }

        $asgs = Get-PolicyAssignments -Policy $pol -Endpoint $ep

        if (-not $asgs -or $asgs.Count -eq 0) {
            $assignmentRows.Add([pscustomobject]@{
                PolicyName = $polName
                PolicyType = $ep.Type
                PolicyId = $pol.id
                Intent = ''
                TargetType = 'UNASSIGNED'
                TargetGroupId = ''
                TargetGroupName = '(none)'
                TargetGroupStatus = ''
                IsDynamicGroup = ''
                GroupMembershipRule = ''
                GroupMembershipRuleProcessingState = ''
                SnapshotDate = $Today
            })
            continue
        }

        foreach ($a in $asgs) {
            $t = $a.target

            if (-not $t) {
                $assignmentRows.Add([pscustomobject]@{
                    PolicyName = $polName
                    PolicyType = $ep.Type
                    PolicyId = $pol.id
                    Intent = 'Include'
                    TargetType = 'Unknown'
                    TargetGroupId = ''
                    TargetGroupName = '(missing target)'
                    TargetGroupStatus = ''
                    IsDynamicGroup = ''
                    GroupMembershipRule = ''
                    GroupMembershipRuleProcessingState = ''
                    SnapshotDate = $Today
                })
                continue
            }

            $odata  = $t.'@odata.type'
            $intent = if ($odata -match 'exclusion') { 'Exclude' } else { 'Include' }

            switch -Regex ($odata) {
                'allDevices' {
                    $tType = 'All Devices'
                    $gid   = ''
                    $gname = 'All Devices'
                    break
                }
                'allLicensedUsers' {
                    $tType = 'All Users'
                    $gid   = ''
                    $gname = 'All Users'
                    break
                }
                'groupAssignment|exclusionGroup' {
                    $tType = 'Group'
                    $gid   = $t.groupId
                    $gname = $gid
                    if ($gid) { [void]$groupIds.Add($gid) }
                    break
                }
                default {
                    $tType = if ($odata) { $odata } else { 'Unknown' }
                    $gid   = ''
                    $gname = if ($odata) { $odata } else { '(unknown target)' }
                }
            }

            $assignmentRows.Add([pscustomobject]@{
                PolicyName = $polName
                PolicyType = $ep.Type
                PolicyId = $pol.id
                Intent = $intent
                TargetType = $tType
                TargetGroupId = $gid
                TargetGroupName = $gname
                TargetGroupStatus = ''
                IsDynamicGroup = ''
                GroupMembershipRule = ''
                GroupMembershipRuleProcessingState = ''
                SnapshotDate = $Today
            })
        }
    }
}


# --- Step 8: Resolve each distinct group once: metadata + members only for static groups
$groupCache = @{}
$deletedGroupAssignments = [System.Collections.Generic.List[object]]::new()

Write-Verbose "Resolving group names and metadata..."

foreach ($gid in $groupIds) {
    $groupUrl = "{0}/groups/{1}?`$select=id,displayName,groupTypes,membershipRule,membershipRuleProcessingState" -f $GraphBaseV1, $gid
    $groupObj = Invoke-MyGraphGetRequest -URL $groupUrl

    if (-not $groupObj -or -not $groupObj.id) {
        Write-Warning "Group not found or no longer resolvable: $gid"
        $groupCache[$gid] = @{
            Name = $gid
            Exists = $false
            IsDynamic = $false
            MembershipRule = $null
            MembershipRuleProcessingState = $null
            Members = @()
        }
        continue
    }

    $isDynamic = @($groupObj.groupTypes) -contains 'DynamicMembership'

    if ($isDynamic) {
        $groupCache[$gid] = @{
            Name = $groupObj.displayName
            Exists = $true
            IsDynamic = $true
            MembershipRule = $groupObj.membershipRule
            MembershipRuleProcessingState = $groupObj.membershipRuleProcessingState
            Members = @()
        }
    }
    else {
        $members = Invoke-MyGraphGetRequest -URL ("{0}/groups/{1}/transitiveMembers?`$select=id,displayName,deviceId,userPrincipalName" -f $GraphBaseV1, $gid)

        $groupCache[$gid] = @{
            Name = $groupObj.displayName
            Exists = $true
            IsDynamic = $false
            MembershipRule = $null
            MembershipRuleProcessingState = $null
            Members = @(
                $members | ForEach-Object {
                    [pscustomobject]@{
                        MemberType = if ($_.userPrincipalName) { 'User' } elseif ($_.deviceId) { 'Device' } else { 'Other' }
                        MemberName = if ($_.userPrincipalName) { $_.userPrincipalName } else { $_.displayName }
                        MemberId   = $_.id
                    }
                }
            )
        }
    }
}


# Backfill group metadata into assignment rows
foreach ($row in $assignmentRows) {
    if ($row.TargetGroupId -and $groupCache.ContainsKey($row.TargetGroupId)) {
        $g = $groupCache[$row.TargetGroupId]

        $row.TargetGroupName = $g.Name
        $row.TargetGroupStatus = if ($g.Exists) { 'Active' } else { 'DeletedOrMissing' }
        $row.IsDynamicGroup = if ($g.Exists) { [string]$g.IsDynamic } else { '' }
        $row.GroupMembershipRule = if ($g.IsDynamic) { $g.MembershipRule } else { '' }
        $row.GroupMembershipRuleProcessingState = if ($g.IsDynamic) { $g.MembershipRuleProcessingState } else { '' }

        if (-not $g.Exists) {
            $deletedGroupAssignments.Add([pscustomobject]@{
                PolicyName = $row.PolicyName
                PolicyType = $row.PolicyType
                PolicyId = $row.PolicyId
                Intent = $row.Intent
                TargetType = $row.TargetType
                DeletedGroupId = $row.TargetGroupId
                DeletedGroupName = $row.TargetGroupName
                SnapshotDate = $Today
            })
        }
    }
}


# --- Step 9: Build outputs
# 9a. PolicyAssignments.csv
$policyAssignments = $assignmentRows | ForEach-Object {
    $mc = ''
    if ($_.TargetGroupId -and $groupCache.ContainsKey($_.TargetGroupId)) {
        $g = $groupCache[$_.TargetGroupId]
        if ($g.Exists -and -not $g.IsDynamic) {
            $mc = $g.Members.Count
        }
    }

    $_ | Add-Member -NotePropertyName MemberCount -NotePropertyValue $mc -PassThru
}

# 9b. UnassignedPolicies.csv
$unassigned = $assignmentRows |
    Where-Object { $_.TargetType -eq 'UNASSIGNED' } |
    Select-Object PolicyName, PolicyType, PolicyId, SnapshotDate

# 9c. PolicyGroupMembership.csv
# Only static groups are expanded to members
$groupMembership = foreach ($gid in $groupCache.Keys) {
    $g = $groupCache[$gid]

    if (-not $g.Exists) { continue }
    if ($g.IsDynamic) { continue }

    foreach ($m in $g.Members) {
        [pscustomobject]@{
            GroupId      = $gid
            GroupName    = $g.Name
            MemberType   = $m.MemberType
            MemberName   = $m.MemberName
            MemberId     = $m.MemberId
            SnapshotDate = $Today
        }
    }
}

# 9d. DeletedGroupAssignments.csv
$deletedGroupAssignmentsCsv = $deletedGroupAssignments |
    Sort-Object PolicyType, PolicyName, DeletedGroupId -Unique

# 9e. DynamicGroupRules.csv
$dynamicGroupRules = foreach ($gid in $groupCache.Keys) {
    $g = $groupCache[$gid]
    if ($g.Exists -and $g.IsDynamic) {
        [pscustomobject]@{
            GroupId                       = $gid
            GroupName                     = $g.Name
            MembershipRule                = $g.MembershipRule
            MembershipRuleProcessingState = $g.MembershipRuleProcessingState
            SnapshotDate                  = $Today
        }
    }
}

# 9f. PolicyAssignments_Summary.csv
#     ONE row per policy = the COMPLETE targeting in a single searchable document.
#     Stops the agent building an answer from a partial sample of assignment rows.
#     Built AFTER the backfill loop so TargetGroupName holds real names, not GUIDs.
Write-Verbose "Building per-policy assignment summary..."

function Limit-TargetList {
    param([string]$Value, [int]$MaxChars)
    if ($Value.Length -gt $MaxChars) { return $Value.Substring(0, $MaxChars) + ' ...(truncated)' }
    return $Value
}

$policySummary = $assignmentRows | Group-Object PolicyName | ForEach-Object {

    $unassignedPolicy = @($_.Group | Where-Object { $_.TargetType -eq 'UNASSIGNED' }).Count -gt 0

    $inc = @($_.Group | Where-Object { $_.Intent -eq 'Include' } |
             Select-Object -ExpandProperty TargetGroupName -Unique)
    $exc = @($_.Group | Where-Object { $_.Intent -eq 'Exclude' } |
             Select-Object -ExpandProperty TargetGroupName -Unique)

    $incStr = Limit-TargetList -Value ($inc -join '; ') -MaxChars $TargetListMaxChars
    $excStr = Limit-TargetList -Value ($exc -join '; ') -MaxChars $TargetListMaxChars

    [pscustomobject]@{
        ReportType     = 'PolicyAssignmentSummary'
        PolicyName     = $_.Name
        PolicyType     = $_.Group[0].PolicyType
        IsUnassigned   = [string]$unassignedPolicy
        IncludeCount   = $inc.Count
        ExcludeCount   = $exc.Count
        IncludeTargets = $incStr
        ExcludeTargets = $excStr
        SnapshotDate   = $Today
    }
}

Write-Verbose "Summary rows: $(@($policySummary).Count)"


# --- Step 10: Slim agent copies (no IDs)
$policyAssignmentsAgent = $policyAssignments | Select-Object `
    PolicyName,
    PolicyType,
    Intent,
    TargetType,
    TargetGroupName,
    TargetGroupStatus,
    IsDynamicGroup,
    GroupMembershipRule,
    GroupMembershipRuleProcessingState,
    SnapshotDate,
    MemberCount

$unassignedAgent = $unassigned | Select-Object `
    PolicyName,
    PolicyType,
    SnapshotDate

$deletedGroupAssignmentsAgent = $deletedGroupAssignmentsCsv | Select-Object `
    PolicyName,
    PolicyType,
    Intent,
    TargetType,
    DeletedGroupName,
    SnapshotDate

$dynamicGroupRulesAgent = $dynamicGroupRules | Select-Object `
    GroupName,
    MembershipRule,
    MembershipRuleProcessingState,
    SnapshotDate

$groupMembershipAgent = $groupMembership | Select-Object `
    GroupName,
    MemberType,
    MemberName,
    SnapshotDate

# Summary has no IDs already - use as-is for both root and agent
$policySummaryAgent = $policySummary


# --- Step 11: Export helpers
function Publish-Csv {
    param(
        [Parameter(Mandatory = $true)]$Data,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$SkipAgentCopy
    )

    if (-not $Data) {
        Write-Warning "No rows for $Name"
        return
    }

    $path = Join-Path $ExportDir $Name
    $Data | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8 -Force

    Set-AzStorageBlobContent -File $path -Container $Container -Blob $Name -Context $StorageAccountContext -Force | Out-Null

    $mb = [math]::Round((Get-Item $path).Length / 1MB, 2)
    if (-not $SkipAgentCopy) {
        if ($mb -le 12) {
            Set-AzStorageBlobContent -File $path -Container $Container -Blob "agent-data/$Name" -Context $StorageAccountContext -Force | Out-Null
            Write-Output "$Name -> agent-data ($mb MB)"
        }
        else {
            Write-Warning "$Name is $mb MB - over gate; kept in Power BI root only."
        }
    }
    else {
        Write-Verbose "$Name uploaded only to root container path."
    }
}

function Publish-CsvAgentOnly {
    param(
        [Parameter(Mandatory = $true)]$Data,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $Data) {
        Write-Warning "No rows for slim agent copy $Name"
        return
    }

    $path = Join-Path $ExportDir $Name
    $Data | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8 -Force

    $mb = [math]::Round((Get-Item $path).Length / 1MB, 2)
    if ($mb -le 12) {
        Set-AzStorageBlobContent -File $path -Container $Container -Blob "agent-data/$Name" -Context $StorageAccountContext -Force | Out-Null
        Write-Output "$Name -> agent-data ($mb MB)"
    }
    else {
        Write-Warning "$Name is $mb MB - over gate; slim agent copy not uploaded."
    }
}

function Publish-CsvChunks {
    param(
        [Parameter(Mandatory = $true)][array]$Data,
        [Parameter(Mandatory = $true)][string]$BaseName,
        [Parameter(Mandatory = $true)][int]$ChunkSize
    )

    if (-not $Data -or $Data.Count -eq 0) {
        Write-Warning "No rows for $BaseName"
        return
    }

    $totalRows = $Data.Count
    $chunkCount = [math]::Ceiling($totalRows / $ChunkSize)

    Write-Verbose "Chunking $BaseName into $chunkCount file(s) with up to $ChunkSize rows each"

    for ($i = 0; $i -lt $chunkCount; $i++) {
        $start = $i * $ChunkSize
        $end   = [math]::Min($start + $ChunkSize - 1, $totalRows - 1)
        $chunk = $Data[$start..$end]
        $chunkName = "{0}_Part{1:D3}.csv" -f $BaseName, ($i + 1)

        $path = Join-Path $ExportDir $chunkName
        $chunk | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8 -Force

        Set-AzStorageBlobContent -File $path -Container $Container -Blob $chunkName -Context $StorageAccountContext -Force | Out-Null

        $mb = [math]::Round((Get-Item $path).Length / 1MB, 2)
        if ($UploadChunkFilesToAgentData -and $mb -le 12) {
            Set-AzStorageBlobContent -File $path -Container $Container -Blob "agent-data/$chunkName" -Context $StorageAccountContext -Force | Out-Null
            Write-Output "$chunkName -> agent-data ($mb MB)"
        }
        elseif ($UploadChunkFilesToAgentData) {
            Write-Warning "$chunkName is $mb MB - over gate; uploaded to root only."
        }
    }
}

function Publish-CsvChunksAgentOnly {
    param(
        [Parameter(Mandatory = $true)][array]$Data,
        [Parameter(Mandatory = $true)][string]$BaseName,
        [Parameter(Mandatory = $true)][int]$ChunkSize
    )

    if (-not $Data -or $Data.Count -eq 0) {
        Write-Warning "No rows for slim agent chunk set $BaseName"
        return
    }

    $totalRows = $Data.Count
    $chunkCount = [math]::Ceiling($totalRows / $ChunkSize)

    Write-Verbose "Chunking slim agent copy $BaseName into $chunkCount file(s) with up to $ChunkSize rows each"

    for ($i = 0; $i -lt $chunkCount; $i++) {
        $start = $i * $ChunkSize
        $end   = [math]::Min($start + $ChunkSize - 1, $totalRows - 1)
        $chunk = $Data[$start..$end]
        $chunkName = "{0}_Part{1:D3}.csv" -f $BaseName, ($i + 1)

        $path = Join-Path $ExportDir $chunkName
        $chunk | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8 -Force

        $mb = [math]::Round((Get-Item $path).Length / 1MB, 2)
        if ($mb -le 12) {
            Set-AzStorageBlobContent -File $path -Container $Container -Blob "agent-data/$chunkName" -Context $StorageAccountContext -Force | Out-Null
            Write-Output "$chunkName -> agent-data ($mb MB)"
        }
        else {
            Write-Warning "$chunkName is $mb MB - over gate; slim agent copy not uploaded."
        }
    }
}


# --- Step 12: Publish full outputs to root + slim outputs to agent-data
Publish-Csv -Data $policyAssignments -Name "PolicyAssignments.csv" -SkipAgentCopy
Publish-Csv -Data $unassigned -Name "UnassignedPolicies.csv" -SkipAgentCopy
Publish-Csv -Data $deletedGroupAssignmentsCsv -Name "DeletedGroupAssignments.csv" -SkipAgentCopy
Publish-Csv -Data $dynamicGroupRules -Name "DynamicGroupRules.csv" -SkipAgentCopy
Publish-Csv -Data $policySummary -Name "PolicyAssignments_Summary.csv" -SkipAgentCopy

Publish-CsvAgentOnly -Data $policyAssignmentsAgent -Name "PolicyAssignments.csv"
Publish-CsvAgentOnly -Data $unassignedAgent -Name "UnassignedPolicies.csv"
Publish-CsvAgentOnly -Data $deletedGroupAssignmentsAgent -Name "DeletedGroupAssignments.csv"
Publish-CsvAgentOnly -Data $dynamicGroupRulesAgent -Name "DynamicGroupRules.csv"
Publish-CsvAgentOnly -Data $policySummaryAgent -Name "PolicyAssignments_Summary.csv"

if ($EnableGroupMembershipChunking -and $groupMembership.Count -gt $GroupChunkRowCount) {
    Publish-Csv -Data (
        [pscustomobject]@{
            FileType      = 'ChunkManifest'
            BaseFileName  = 'PolicyGroupMembership'
            TotalRows     = $groupMembership.Count
            ChunkRowCount = $GroupChunkRowCount
            SnapshotDate  = $Today
        }
    ) -Name "PolicyGroupMembership_Manifest.csv" -SkipAgentCopy

    Publish-CsvChunks -Data @($groupMembership) -BaseName "PolicyGroupMembership" -ChunkSize $GroupChunkRowCount

    Publish-CsvAgentOnly -Data (
        [pscustomobject]@{
            FileType      = 'ChunkManifest'
            BaseFileName  = 'PolicyGroupMembership'
            TotalRows     = $groupMembershipAgent.Count
            ChunkRowCount = $GroupChunkRowCount
            SnapshotDate  = $Today
        }
    ) -Name "PolicyGroupMembership_Manifest.csv"

    Publish-CsvChunksAgentOnly -Data @($groupMembershipAgent) -BaseName "PolicyGroupMembership" -ChunkSize $GroupChunkRowCount
}
else {
    Publish-Csv -Data $groupMembership -Name "PolicyGroupMembership.csv" -SkipAgentCopy
    Publish-CsvAgentOnly -Data $groupMembershipAgent -Name "PolicyGroupMembership.csv"
}

Write-Verbose "Script completed successfully at $(Get-Date)"
