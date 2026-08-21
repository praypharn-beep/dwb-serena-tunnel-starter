# Security

This starter handles credentials locally and is designed to avoid committing secrets.

## Secrets

`Configure.cmd` creates:

- `config/team.ps1` — contains the Tunnel ID
- `config/api-key.dpapi` — contains the Runtime API key encrypted with Windows DPAPI

Both paths are ignored by Git.

The Runtime API key is protected by Windows DPAPI only while stored on disk. `Start.cmd` decrypts it into the tunnel-client process environment for the lifetime of the process. Stop the client when it is not in use and treat local administrator access as trusted.

`Lazy-Control.cmd install`/`start` inherit this same DPAPI boundary through `scripts/lazy-common.ps1`: the key is decrypted only into the tunnel-client child process's environment at launch time, for the duration of that process, and cleared from the environment immediately afterward. `scripts/lazy-control.ps1` itself never decrypts the key — `install`, `status`, `stop`, and `uninstall` never call the DPAPI decryption helper, so a bug or crash in any of those actions cannot leak the plaintext key. `status` output in particular is limited to a small allow-listed set of fields (see "Lazy proxy status boundary" below) and is checked by `tests/validate.ps1` to never reference the DPAPI secret file or its plaintext content.

## Serena access boundary

Serena can provide tools that read and modify files and execute shell commands. Activate only the local project you intend to expose, use only trusted ChatGPT workspaces and tunnel principals, review tool calls, and use a sandbox or container for sensitive projects.

Keeping the tunnel and lazy proxy running (even while Serena itself is idle) means any tunnel principal authenticated by the OpenAI Secure MCP Tunnel can trigger a real Serena start and issue a real tool call at any time — the 15-minute idle stop bounds how long Serena stays running after use, but it is not an access control. Treat "the tunnel is connected" as equivalent to "Serena is reachable" when deciding which workspaces and Runtime API keys to trust.

## Lazy proxy: localhost-only listeners and a sanitized status boundary

The lazy proxy (`lazy-proxy/`) and the tunnel's own health UI bind to `127.0.0.1` only — never to `0.0.0.0` or any non-loopback interface — so neither is reachable from the network, only from the local machine.

The proxy's status endpoint (`http://127.0.0.1:18012/status`) returns exactly ten allow-listed fields: `proxy`, `serena`, `pid`, `inFlight`, `queued`, `lastActivityAt`, `idleDeadline`, `manifestVersion`, `manifestCompatible`, `lastError`. It never includes MCP tool call arguments or results, file paths, project data, the Tunnel ID, or the API key in any form. `Lazy-Control.cmd status` (and the `Get-LazyControlStatus` function behind it) reads only this same JSON plus locally-verified process identity (PID, executable path) — it never decrypts or forwards the DPAPI secret. Logs from the proxy and supervisor follow the same rule: no secrets, no tool payloads.

## Serena tool manifest trust boundary

`lazy-proxy/serena-tools.json` is a versioned snapshot of the tool list your locally installed Serena reported at capture time (see `lazy-proxy/scripts/capture-manifest.mjs`). The lazy proxy validates the manifest's shape on load and compares it against Serena's live tool list at Serena startup; on a mismatch it still starts Serena (so you are not blocked) but reports `manifestCompatible: false` via `/status` rather than silently trusting a manifest that no longer reflects Serena's real capabilities. The manifest itself never grants any tool capability — it only describes what the proxy will proxy through; actual tool execution is still performed by your locally installed Serena, subject to the Serena access boundary above.

## Scheduled Task scope (`Lazy-Control.cmd install`)

`Lazy-Control.cmd install` registers exactly one Scheduled Task, named `DWB Serena Lazy Tunnel`, scoped as follows:

- **Trigger:** `AtLogOn` for the current Windows user only — it does not run for other users, does not run as SYSTEM, and does not run before any user logs on.
- **Principal:** a **non-elevated (`Limited`) run level** for the current user. It never requests, and cannot silently escalate to, administrator rights.
- **Action:** launches `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File scripts\lazy-supervisor.ps1` directly from the repository — never a copy, and never through `lazy-control.ps1` itself. There is exactly one task action; nothing else is registered or scheduled.
- **Reversible:** `Lazy-Control.cmd uninstall` removes only this exact task by name; it never enumerates or touches any other Scheduled Task on the system.

## PID verification before any stop or force-kill

`stop` and `uninstall` never trust a PID file on its own. Before sending any stop signal, `scripts/lazy-control.ps1` re-reads the live process's executable path and full command line (via WMI/`Win32_Process`) and compares both against what the script itself would have launched. The **"Tunnel" umbrella covers two independently-verified process identities, not one**:

- the hidden PowerShell **supervisor** (its PID is what's actually recorded in `dwb-serena-tunnel.pid`) — matched on the resolved `powershell.exe` path plus the resolved **absolute** `lazy-supervisor.ps1` path for *this repo checkout* (not a bare filename, and not a wildcard executable pattern); and
- the supervisor's **`tunnel-client.exe` child** — matched on the exact resolved `tunnel-client.exe` path for this checkout plus a command line containing `run --profile dwb-serena`. This PID is never written to its own file; it is discovered live by enumerating the supervisor's children (`ParentProcessId` equal to the supervisor's PID) *while the supervisor is still verified alive to be its parent*, and identity-verified the same way as every other target before anything is done with it.

Both identities matter because `tunnel-client.exe` is a genuine OS child of the supervisor, and **Windows does not terminate a process's children when the parent process is killed**. Stopping only the supervisor would leave `tunnel-client.exe` running and still listening on its port — silently orphaned — even though the control script would otherwise report success. `stop` therefore always stops the supervisor first (which halts its restart-supervision loop) and then independently stops the discovered, identity-verified `tunnel-client.exe`, rather than relying on a tree-kill (`taskkill /T`) walking down from an already-dead parent PID, which would depend on Windows not having reused that dead PID number yet — exactly the class of PID-reuse assumption this script avoids everywhere else.

The proxy target is matched on the resolved `node.exe` path plus `lazy-proxy/cli.mjs` and the exact manifest path. The absolute-path requirement for the supervisor and `tunnel-client.exe` matters specifically because this starter kit is designed to be checked out more than once on the same machine — two checkouts both have a script literally named `scripts\lazy-supervisor.ps1` and a binary at `tunnel-client\tunnel-client.exe`, so a bare filename match would treat any checkout's process as a match for any other checkout's stale PID file; comparing the full resolved path scopes the check to the exact checkout that wrote the PID file. If either the executable or the required command-line substring(s) do not match — because a PID file is missing, stale, corrupt, or the numeric PID has been reused by an unrelated process (including another checkout of this same repo) — that PID is left completely untouched: no graceful stop request and no forced termination are ever sent to it. If a verified process does not exit within the graceful-stop timeout, the identity check is performed **a second time**, immediately before the forced termination, to close the race window where the original process could have exited and its PID number been reused by something else in the interim. This behavior is covered by dedicated tests in `tests/lazy-control.Tests.ps1`, including a simulated cross-checkout PID-reuse race and a test against real, disposable OS parent/child dummy processes that verifies both are actually gone afterward (not just that the function reports success).

## If a key is exposed

Revoke or rotate the exposed OpenAI API key immediately, then run `Configure.cmd` again with the replacement key.

Do not post API keys, tunnel credentials, or secret-bearing logs in public GitHub issues.

## Reporting a vulnerability

Use the repository's **Security → Report a vulnerability** flow to send a private GitHub security advisory. Do not include a secret, exploit, or sensitive log in a public issue.

If private vulnerability reporting is not available, open a minimal public issue asking the maintainer for a private contact channel. Include no sensitive technical details until a private channel is established.

## Third-party runtime

`Setup.cmd` downloads the OpenAI tunnel-client from the official `openai/tunnel-client` GitHub release. The downloaded runtime is not committed to this repository.

When `SHA256SUMS.txt` is present in the release, setup requires a matching checksum entry and verifies the archive before extraction. If a release does not publish a checksum file, setup prints an explicit warning.
