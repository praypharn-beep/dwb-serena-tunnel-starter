# Lazy Serena MCP Proxy Design

Date: 2026-08-21
Status: Approved for implementation planning

## Goal

Keep the OpenAI Secure MCP tunnel reachable in the background while starting Serena only when ChatGPT makes the first real Serena tool call. Stop Serena after 15 minutes of inactivity. Never activate a project automatically.

## Current State

- `tunnel-client` profile `dwb-serena` launches `serena start-mcp-server --context chatgpt` immediately over stdio.
- `tunnel-client` must remain alive so remote ChatGPT requests can reach the local machine.
- Serena currently starts as soon as the tunnel starts.
- `Start.cmd` delegates to Windows PowerShell `start.ps1`. Serena writes informational output to stderr, which Windows PowerShell converts into `NativeCommandError` while `$ErrorActionPreference = 'Stop'`, causing the starter to exit.
- The tunnel profile, DPAPI-protected API key, and Serena executable are present and valid.

## Selected Approach

Add a lightweight local MCP proxy between `tunnel-client` and Serena.

```text
Windows user logon
  -> tunnel launcher
  -> tunnel-client
  -> lazy-serena-proxy
  -> Serena is not running

First ChatGPT tools/call
  -> proxy starts one Serena child
  -> proxy performs the MCP handshake
  -> proxy forwards the call
  -> Serena stays alive while active
  -> proxy stops Serena after 15 idle minutes
```

The tunnel and proxy remain available in the background. Only Serena and its language-server children are lazy.

## Components

### Tunnel launcher

- Starts at Windows user logon.
- Decrypts the existing API key with Windows DPAPI and exposes it only to the child process environment.
- Starts one hidden `tunnel-client` process with profile `dwb-serena`.
- Does not persist the plaintext API key.
- Avoids the existing Windows PowerShell native-stderr failure path.
- Provides explicit start, status, stop, and uninstall-auto-start operations.

### Lazy Serena proxy

- Runs as the stdio MCP command configured for the tunnel's `main` channel.
- Answers MCP `initialize` and `tools/list` without starting Serena, using a versioned Serena tool manifest.
- Starts Serena only on the first `tools/call` or another operation that requires the real server.
- Launches exactly:

  `serena start-mcp-server --context chatgpt`

- Performs the downstream MCP handshake before forwarding work.
- Maintains at most one Serena child process.
- Serializes startup so concurrent first calls cannot create duplicate children.
- Does not activate or select a project.

### Tool manifest

- Contains the Serena tool names, descriptions, and input schemas needed for `tools/list` while Serena is stopped.
- Records the Serena version used to generate it.
- Is regenerated explicitly during installation or upgrade, not during normal GPT calls.
- Is compared with the live Serena tool list after startup. A mismatch is surfaced in health status and unsafe or unknown calls are rejected.

### Health status

- Remains bound to localhost only.
- Reports proxy state, Serena state, Serena PID, last activity time, idle deadline, manifest version, and last failure summary.
- Never reports API keys, file contents, MCP payload bodies, or project data.

## State Model

```text
IDLE -> STARTING -> READY -> BUSY -> IDLE
          |           |
          +-> FAILED <-+
```

- `IDLE`: proxy is ready; Serena is stopped.
- `STARTING`: one caller owns startup; other callers wait in a bounded queue.
- `READY`: Serena handshake has completed and calls may be forwarded.
- `BUSY`: one or more calls are in flight; idle shutdown is disabled.
- `FAILED`: the triggering call receives a clear MCP error. No automatic restart loop runs.

The next real tool call may make one fresh startup attempt after a failure.

## Lifecycle Rules

- Serena startup timeout: 30 seconds.
- Idle timeout: 15 minutes after the last in-flight call completes.
- Serena is never stopped while a request is in flight.
- Tunnel or proxy shutdown terminates the Serena child gracefully, then forcefully after a bounded grace period.
- Unexpected Serena exit fails current calls, records a sanitized error, and returns to a retryable stopped state.
- Queue and concurrency limits prevent unbounded resource use.
- One proxy instance and one Serena child are allowed per profile.

## Security and Privacy

- All local listeners bind to `127.0.0.1` only.
- The API key remains DPAPI-protected at rest and plaintext only in the tunnel process environment.
- Logs exclude secrets, file contents, project data, and raw MCP payloads.
- The proxy never activates a project automatically.
- Tool calls are accepted only from the existing authenticated tunnel channel.
- Auto-start is user-scoped and can be removed without deleting profiles, Serena data, or projects.

## Failure Handling

- Tunnel authentication failure: keep Serena stopped and expose a sanitized health error.
- Manifest missing or invalid: fail startup before changing the active tunnel profile.
- Serena executable missing: return a clear MCP error and remain available for status checks.
- Serena startup timeout: terminate the partial child tree and return to `FAILED`.
- Manifest mismatch: reject unknown or schema-incompatible tool calls and instruct the operator to refresh the manifest.
- Proxy crash: the launcher applies a bounded restart policy; repeated failures stop instead of looping.

## Testing and Rollout

1. Test the proxy without the live tunnel. `initialize` and `tools/list` must succeed while no Serena process exists.
2. Send one simulated `tools/call`. Verify exactly one Serena child starts, completes the handshake, and returns the result.
3. Send concurrent first calls. Verify a single startup and bounded queuing.
4. Verify Serena is not stopped during active work and stops after 15 idle minutes.
5. Exercise missing executable, startup timeout, child crash, manifest mismatch, and proxy shutdown paths.
6. Back up the current `dwb-serena` profile, switch its MCP command to the proxy, and test one real ChatGPT call.
7. Verify the full path: ChatGPT -> tunnel-client -> proxy -> Serena.
8. Configure user-logon startup and verify after a fresh logon that tunnel and proxy run while Serena remains stopped.
9. Verify stop and uninstall-auto-start operations restore the prior profile and leave Serena projects untouched.

## Rollback

- Preserve a byte-for-byte backup of the original `dwb-serena` profile before rollout.
- Disable the user-logon launcher.
- Stop proxy and Serena child processes.
- Restore the original profile command `serena start-mcp-server --context chatgpt`.
- Start the tunnel manually using the known direct-launch workaround.
- Do not delete Serena configuration, memories, projects, or the DPAPI-protected API key.

## Acceptance Criteria

- At Windows logon, tunnel-client and the proxy are running, but Serena is not.
- Opening GPT or listing tools does not start Serena.
- The first real Serena tool call starts exactly one Serena instance and succeeds.
- Concurrent first calls do not create duplicates.
- Serena stops after 15 idle minutes and restarts on the next real call.
- No project is activated automatically.
- Health and logs expose no secrets or project contents.
- Repeated failures do not create a restart loop.
- The operator can stop the system and remove auto-start without losing configuration or project data.
