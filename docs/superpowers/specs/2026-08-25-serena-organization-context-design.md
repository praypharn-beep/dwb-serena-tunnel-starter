# Serena Organization Context Design

**Date:** 2026-08-25
**Status:** Draft for owner review

## Context

The ChatGPT-facing Serena tunnel belongs to a Personal Platform organization that requires an explicit organization context on runtime requests.
A live foreground test passed only when the correct Runtime API key and Organization ID were supplied together; omitting the ID returned `tunnel_active_organization_required`, and a mismatched ID returned `mismatched_organization`.

The current launcher stores only the Tunnel ID in `config/team.ps1` and passes only the DPAPI-protected API key to the tunnel-client child process.

## Decision

Store the non-secret Organization ID beside the Tunnel ID in the local `config/team.ps1` file.

`Get-LazyRuntimeConfig` will load and validate both identifiers and return the Organization ID as runtime configuration.

`Start-LazyTunnel` will set `CONTROL_PLANE_ORGANIZATION_ID` only in the supervisor process immediately before launching tunnel-client, so the child inherits it, and will clear it together with the plaintext API key in `finally` cleanup.

This keeps the setting scoped to the Serena tunnel process and avoids a user-level environment variable that could affect Hermes or other tunnel-client profiles.

## Validation and failure behavior

- Require an Organization ID beginning with `org-` followed by a conservative alphanumeric identifier.
- Fail before launching tunnel-client when the value is missing or malformed.
- Never print the Organization ID together with credentials or expose the API key.
- Continue using Windows DPAPI for the Runtime API key at rest.

## Files in scope

- `config/team.ps1`: add the current Serena Organization ID.
- `configure.ps1`: request, validate, and persist an Organization ID during future configuration runs.
- `scripts/lazy-common.ps1`: load the ID and pass it only to the tunnel-client child environment.
- `tests/lazy-launcher.Tests.ps1`: cover validation, child propagation, and cleanup.

## Verification

1. Add a failing launcher regression test that expects an organization context.
2. Run the targeted PowerShell launcher test and confirm the expected RED failure.
3. Implement the minimal configuration and child-environment change.
4. Re-run the targeted launcher test and existing validation scripts.
5. Render the real profile and run `doctor` without repeating unrelated Node tests.
6. Start the managed stack and verify ports 18010/18012, `readyz`, tunnel metadata, and `probe_status: ok`.
7. Run one harmless ChatGPT Serena read-only tool call and confirm proxy activity.

## Out of scope

- No global Windows environment variable.
- No Hermes production changes.
- No changes to Serena tool behavior or manifest.
- No deletion of unused API keys or old tunnels without separate approval.
