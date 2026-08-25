# Serena Organization Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Persist the Serena Organization ID and pass it only to the managed tunnel-client child process.

**Architecture:** config/team.ps1 stores the non-secret Tunnel and Organization IDs. Get-LazyRuntimeConfig validates both; Start-LazyTunnel places CONTROL_PLANE_ORGANIZATION_ID in the child environment only during launch and clears it with the API key.

**Tech Stack:** Windows PowerShell 5.1, tunnel-client 0.0.11, Windows DPAPI, existing PowerShell test harness.

## Global Constraints

- No global Windows environment variable.
- No Hermes production changes.
- No Serena tool or manifest changes.
- No deletion of API keys or tunnels without separate approval.
- Do not repeat the unrelated Node 53/53 suite.
- Never print or commit the plaintext Runtime API key.

---

### Task 1: Add and test the Organization context contract

**Files:**
- Modify: scripts/lazy-common.ps1:23-73,145-223
- Modify: configure.ps1:14-40
- Modify: start.ps1:49-100
- Modify: tests/lazy-launcher.Tests.ps1:120-170,185-345

**Interfaces:**
- Consumes: $TunnelId and $OrganizationId from config/team.ps1.
- Produces: Get-LazyRuntimeConfig(...).OrganizationId as a string.
- Produces: CONTROL_PLANE_ORGANIZATION_ID during ProcessLauncher, cleared afterward.

- [ ] **Step 1: Write failing configuration tests**

~~~powershell
$FakeOrganizationId = 'org-aaaaaaaaaaaaaaaaaaaaaaaa'
$Config = Get-LazyRuntimeConfig -RepoRoot $RepoRoot -TunnelIdOverride $FakeTunnelId -OrganizationIdOverride $FakeOrganizationId
Assert-True ($Config.OrganizationId -eq $FakeOrganizationId) 'Runtime config must return the validated Organization ID.'

$InvalidOrganizationRejected = $false
try {
    Get-LazyRuntimeConfig -RepoRoot $RepoRoot -TunnelIdOverride $FakeTunnelId -OrganizationIdOverride 'not-an-org-id' | Out-Null
}
catch {
    $InvalidOrganizationRejected = $true
}
Assert-True $InvalidOrganizationRejected 'Runtime config must reject a malformed Organization ID before launch.'
~~~

This catches removal of validation or failure to expose the approved ID.

- [ ] **Step 2: Write failing child-environment tests**

Add OrganizationId = $FakeOrganizationId to $FakeConfig. Extend the existing observing launcher:

~~~powershell
Assert-True ([string]::IsNullOrEmpty($env:CONTROL_PLANE_ORGANIZATION_ID)) 'Organization environment precondition must be empty.'
$ObservedOrganization = @{ WasSet = $false; Value = $null }

$ApiKeyObservingLauncher = {
    param($FilePath, $ArgumentList, $WorkingDirectory)
    $ObservedApiKey.WasSet = -not [string]::IsNullOrEmpty($env:CONTROL_PLANE_API_KEY)
    $ObservedApiKey.Value = $env:CONTROL_PLANE_API_KEY
    $ObservedOrganization.WasSet = -not [string]::IsNullOrEmpty($env:CONTROL_PLANE_ORGANIZATION_ID)
    $ObservedOrganization.Value = $env:CONTROL_PLANE_ORGANIZATION_ID
    [pscustomobject]@{ ExitCode = 1 } |
        Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { } -PassThru
}.GetNewClosure()
~~~

After the existing Start-LazyTunnel call:

~~~powershell
Assert-True $ObservedOrganization.WasSet 'Organization context must exist when the child launches.'
Assert-True ($ObservedOrganization.Value -eq $FakeOrganizationId) 'The child must receive the configured Organization ID.'
Assert-True ([string]::IsNullOrEmpty($env:CONTROL_PLANE_ORGANIZATION_ID)) 'Organization context must clear after success.'
~~~

After the throwing-launcher path:

~~~powershell
Assert-True ([string]::IsNullOrEmpty($env:CONTROL_PLANE_ORGANIZATION_ID)) 'Organization context must clear after failure.'
~~~

These catch a missing assignment, wrong value, or missing cleanup.

- [ ] **Step 3: Run RED**

Run:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\lazy-launcher.Tests.ps1
~~~

Expected: FAIL because OrganizationIdOverride and the child environment behavior do not exist.

- [ ] **Step 4: Implement runtime validation**

Change Get-LazyRuntimeConfig to:

~~~powershell
param(
    [Parameter(Mandatory)] [string]$RepoRoot,
    [string]$TunnelIdOverride,
    [string]$OrganizationIdOverride
)

$TunnelId = $TunnelIdOverride
$OrganizationId = $OrganizationIdOverride
if ([string]::IsNullOrWhiteSpace($TunnelId) -or [string]::IsNullOrWhiteSpace($OrganizationId)) {
    $LocalConfigPath = Join-Path $RepoRoot 'config\team.ps1'
    if (-not (Test-Path -LiteralPath $LocalConfigPath)) { throw "Tunnel configuration not found: $LocalConfigPath" }
    . $LocalConfigPath
}
if ([string]::IsNullOrWhiteSpace($TunnelId) -or $TunnelId -cnotmatch '^tunnel_[0-9a-f]{32}$') {
    throw 'Tunnel ID is missing or invalid.'
}
if ([string]::IsNullOrWhiteSpace($OrganizationId) -or $OrganizationId -cnotmatch '^org-[A-Za-z0-9]{20,}$') {
    throw 'Organization ID is missing or invalid.'
}
~~~

Add OrganizationId = $OrganizationId to the returned object.

- [ ] **Step 5: Persist future configuration**

In configure.ps1, prompt and validate:

~~~powershell
$OrganizationId = Read-Host 'Organization ID (org-...)'
if ([string]::IsNullOrWhiteSpace($OrganizationId) -or $OrganizationId -cnotmatch '^org-[A-Za-z0-9]{20,}$') {
    throw 'Invalid Organization ID. Expected org- followed by at least 20 alphanumeric characters.'
}
~~~

Write both identifiers without expanding arbitrary input:

~~~powershell
$TunnelEscaped = $TunnelId.Replace("'", "''")
$OrganizationEscaped = $OrganizationId.Replace("'", "''")
$ConfigContent = @'
# DWB Serena Tunnel - local configuration
# Generated by Configure.cmd.
# This file contains the Tunnel and Organization IDs only. The API key is stored separately using Windows DPAPI.

$TunnelId = '__TUNNEL_ID__'
$OrganizationId = '__ORGANIZATION_ID__'
'@
$ConfigContent = $ConfigContent.Replace('__TUNNEL_ID__', $TunnelEscaped).Replace('__ORGANIZATION_ID__', $OrganizationEscaped)
~~~

- [ ] **Step 6: Propagate and clear the child environment**

Before ProcessLauncher:

~~~powershell
$env:CONTROL_PLANE_API_KEY = $ApiKey
$env:CONTROL_PLANE_ORGANIZATION_ID = $Config.OrganizationId
~~~

In both inner and outer finally blocks:

~~~powershell
$env:CONTROL_PLANE_API_KEY = $null
$env:CONTROL_PLANE_ORGANIZATION_ID = $null
~~~

- [ ] **Step 7: Keep start.ps1 consistent**

Validate $OrganizationId after dot-sourcing config/team.ps1. Call:

~~~powershell
$Config = Get-LazyRuntimeConfig -RepoRoot $Root -TunnelIdOverride $TunnelId -OrganizationIdOverride $OrganizationId
~~~

Set and clear CONTROL_PLANE_ORGANIZATION_ID beside CONTROL_PLANE_API_KEY during doctor preflight.

- [ ] **Step 8: Run GREEN**

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\lazy-launcher.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\validate.ps1
~~~

Expected: both exit 0; launcher output ends with All lazy launcher checks passed.

- [ ] **Step 9: Review and commit**

~~~powershell
git diff --check
git diff -- scripts/lazy-common.ps1 configure.ps1 start.ps1 tests/lazy-launcher.Tests.ps1
git add scripts/lazy-common.ps1 configure.ps1 start.ps1 tests/lazy-launcher.Tests.ps1
git commit -m "fix: scope Serena tunnel organization context"
~~~

Confirm no key, Hermes path, or unrelated refactor appears.

### Task 2: Apply local configuration and complete live gates

**Files:**
- Modify locally (ignored): config/team.ps1
- Verify only: C:\Users\User\AppData\Roaming\tunnel-client\dwb-serena.yaml

**Interfaces:**
- Consumes: org-yNy4ZFDK3sAXFVQ1NJglZDmp.
- Produces: tunnel-client on 127.0.0.1:18010 and lazy proxy on 127.0.0.1:18012.

- [ ] **Step 1: Back up and update config/team.ps1**

Use this complete content:

~~~powershell
# DWB Serena Tunnel - local configuration
# Generated by Configure.cmd.
# This file contains the Tunnel and Organization IDs only. The API key is stored separately using Windows DPAPI.

$TunnelId = 'tunnel_6a8d2595a9d88191ae99dc773bcf54ed'
$OrganizationId = 'org-yNy4ZFDK3sAXFVQ1NJglZDmp'
~~~

Verify only the comment and Organization ID were added.

- [ ] **Step 2: Run doctor with scoped credentials**

Decrypt the DPAPI key only in Windows PowerShell memory, set both control-plane environment variables, and run:

~~~powershell
tunnel-client.exe doctor --profile dwb-serena --explain
~~~

Expected: RESULT ok and no plaintext key.

- [ ] **Step 3: Start the managed stack**

~~~powershell
Lazy-Control.cmd start
~~~

Expected: supervisor, tunnel-client, and lazy proxy start. No cloudflared child is required because route_mode is direct.

- [ ] **Step 4: Verify health and metadata**

~~~text
GET http://127.0.0.1:18010/healthz  -> 200 live
GET http://127.0.0.1:18010/readyz   -> 200 ready
GET http://127.0.0.1:18010/api/status
GET http://127.0.0.1:18012/status
~~~

Expected: new tunnel ID, serena-local-pilot metadata, main probe_status ok, proxy ready, Serena stopped, and no last error.

- [ ] **Step 5: Complete ChatGPT live MCP gate**

Select the existing serena-local-pilot tunnel in ChatGPT Plugins, install it, and run the harmless read-only get_current_config tool.

Expected: proxy lastActivityAt changes, Serena starts for the call, the queue returns to zero, and the tool succeeds.

- [ ] **Step 6: Report final status**

Report PASS only after local health and the ChatGPT tool call both succeed. Otherwise report BLOCKED with the exact error and first failing boundary.
