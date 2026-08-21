# Lazy Serena MCP Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the Secure MCP tunnel reachable in the background while starting exactly one Serena `chatgpt` process only when GPT makes a real tool call, then stop Serena after 15 idle minutes.

**Architecture:** A dependency-free Node.js stdio MCP proxy sits between `tunnel-client` and Serena. It serves `initialize` and `tools/list` from a versioned manifest while Serena is stopped, starts and handshakes Serena on the first `tools/call`, forwards calls through a serialized bounded queue, exposes localhost-only status, and shuts the child down after an idle timeout. PowerShell launch and control scripts render the profile, protect the API key with DPAPI, supervise the tunnel with bounded restarts, and install a user-logon Scheduled Task.

**Tech Stack:** Windows PowerShell 5.1, Node.js 20+ standard library, JSON-RPC 2.0 over newline-delimited stdio, Node built-in `node:test`, existing `tunnel-client.exe`, existing Serena CLI.

**Spec:** `docs/superpowers/specs/2026-08-21-lazy-serena-proxy-design.md`

## Global Constraints

- Support Windows and Node.js 20 or newer without npm runtime dependencies.
- Keep tunnel and proxy listeners on `127.0.0.1` only.
- Start Serena exactly as `serena start-mcp-server --context chatgpt`.
- Never activate or select a Serena project automatically.
- Allow at most one Serena child per proxy and one supervised tunnel per profile.
- Use a 30-second Serena startup timeout and a 15-minute idle timeout.
- Never stop Serena while a tool call is in flight.
- Keep the control-plane API key DPAPI-protected at rest and out of logs.
- Do not log raw MCP payloads, file contents, project data, or secrets.
- Use bounded queues and bounded restart attempts; never restart forever.
- Preserve and restore the original `dwb-serena` profile during rollback.

## File Map

- Create `package.json`: Node version declaration and test commands.
- Create `lazy-proxy/protocol.mjs`: newline-delimited JSON-RPC reader/writer and response helpers.
- Create `lazy-proxy/manifest.mjs`: manifest loading, validation, and live-schema comparison.
- Create `lazy-proxy/serena-process.mjs`: Serena child lifecycle, downstream handshake, request dispatch, timeout, and shutdown.
- Create `lazy-proxy/status-server.mjs`: localhost-only JSON and HTML status endpoint.
- Create `lazy-proxy/server.mjs`: upstream MCP state machine and bounded serialized call queue.
- Create `lazy-proxy/cli.mjs`: production entrypoint and argument/environment parsing.
- Create `lazy-proxy/serena-tools.json`: versioned Serena tool manifest.
- Create `lazy-proxy/scripts/capture-manifest.mjs`: explicit manifest refresh command.
- Create `lazy-proxy/test/fixtures/fake-serena.mjs`: controllable downstream MCP fixture.
- Create `lazy-proxy/test/*.test.mjs`: protocol, manifest, lifecycle, proxy, and status tests.
- Create `scripts/lazy-common.ps1`: DPAPI, profile rendering, PID, and path helpers.
- Create `scripts/lazy-supervisor.ps1`: bounded tunnel supervision.
- Create `scripts/lazy-control.ps1`: install/start/status/stop/uninstall commands.
- Create `Lazy-Control.cmd`: simple operator entrypoint.
- Modify `profiles/serena-team.yaml`: replace the direct Serena command with a proxy-command placeholder.
- Modify `start.ps1`: render the lazy profile and start through the supervisor without native-stderr failure.
- Modify `tests/validate.ps1`: validate Node, proxy files, loopback settings, placeholders, and PowerShell syntax.
- Modify `README.md`, `README.th.md`, and `SECURITY.md`: operation, impact, failure behavior, rollback, and security model.

---

### Task 1: JSON-RPC Transport and Manifest Contract

**Files:**
- Create: `package.json`
- Create: `lazy-proxy/protocol.mjs`
- Create: `lazy-proxy/manifest.mjs`
- Create: `lazy-proxy/test/protocol.test.mjs`
- Create: `lazy-proxy/test/manifest.test.mjs`
- Create: `lazy-proxy/test/fixtures/valid-manifest.json`

**Interfaces:**
- Produces: `createJsonLineReader(readable, { onMessage, onError }) -> { close() }`
- Produces: `writeJsonLine(writable, message) -> Promise<void>`
- Produces: `jsonRpcResult(id, result) -> object`
- Produces: `jsonRpcError(id, code, message, data?) -> object`
- Produces: `loadManifest(path) -> Promise<SerenaManifest>`
- Produces: `compareToolLists(manifestTools, liveTools) -> { compatible, missing, added, changed }`

- [ ] **Step 1: Add the dependency-free Node project contract**

Create `package.json`:

```json
{
  "name": "dwb-serena-tunnel-starter",
  "private": true,
  "type": "module",
  "engines": { "node": ">=20" },
  "scripts": {
    "test": "node --test lazy-proxy/test/*.test.mjs",
    "test:proxy": "node --test lazy-proxy/test/proxy.integration.test.mjs"
  }
}
```

- [ ] **Step 2: Write failing protocol tests**

Test split input, multiple lines, malformed JSON isolation, and backpressure:

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';
import { createJsonLineReader, jsonRpcError, jsonRpcResult, writeJsonLine } from '../protocol.mjs';

test('reader reconstructs split newline-delimited JSON messages', async () => {
  const input = new PassThrough();
  const seen = [];
  createJsonLineReader(input, { onMessage: value => seen.push(value), onError: error => { throw error; } });
  input.write('{"jsonrpc":"2.0","id":1,');
  input.write('"method":"tools/list"}\n{"jsonrpc":"2.0","id":2,"method":"ping"}\n');
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(seen.map(x => x.id), [1, 2]);
});

test('helpers preserve JSON-RPC ids', () => {
  assert.deepEqual(jsonRpcResult('a', { ok: true }), { jsonrpc: '2.0', id: 'a', result: { ok: true } });
  assert.equal(jsonRpcError(9, -32601, 'not found').error.code, -32601);
});
```

- [ ] **Step 3: Run protocol tests and verify RED**

Run: `node --test lazy-proxy/test/protocol.test.mjs`

Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `lazy-proxy/protocol.mjs`.

- [ ] **Step 4: Implement the protocol module**

Implement buffered UTF-8 line parsing with a 1 MiB maximum line, reject non-object messages, send one compact JSON object per line, and wait for `drain` when `writable.write()` returns false. Export exactly the signatures in the Interfaces block.

- [ ] **Step 5: Run protocol tests and verify GREEN**

Run: `node --test lazy-proxy/test/protocol.test.mjs`

Expected: all protocol tests PASS.

- [ ] **Step 6: Write failing manifest tests**

Use this fixture shape:

```json
{
  "manifestVersion": 1,
  "serenaVersion": "1.7.0",
  "protocolVersion": "2025-06-18",
  "tools": [{ "name": "read_file", "description": "Read a file", "inputSchema": { "type": "object" } }]
}
```

Test that missing fields reject and that description-only changes are reported in `changed`.

- [ ] **Step 7: Run manifest tests and verify RED**

Run: `node --test lazy-proxy/test/manifest.test.mjs`

Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `lazy-proxy/manifest.mjs`.

- [ ] **Step 8: Implement manifest validation and comparison**

Validate `manifestVersion === 1`, non-empty version strings, unique tool names, and object input schemas. Compare canonical JSON containing `name`, `description`, and `inputSchema`; return sorted tool-name arrays.

- [ ] **Step 9: Run Task 1 tests**

Run: `node --test lazy-proxy/test/protocol.test.mjs lazy-proxy/test/manifest.test.mjs`

Expected: all tests PASS.

- [ ] **Step 10: Commit Task 1**

```powershell
git add package.json lazy-proxy/protocol.mjs lazy-proxy/manifest.mjs lazy-proxy/test
git commit -m "feat: add MCP protocol and manifest contracts"
```

---

### Task 2: Lazy Serena Child Lifecycle

**Files:**
- Create: `lazy-proxy/serena-process.mjs`
- Create: `lazy-proxy/test/serena-process.test.mjs`
- Create: `lazy-proxy/test/fixtures/fake-serena.mjs`

**Interfaces:**
- Consumes: `createJsonLineReader`, `writeJsonLine`, `compareToolLists`
- Produces: `class SerenaProcessManager`
- Constructor: `new SerenaProcessManager({ command, args, manifest, startupTimeoutMs, idleTimeoutMs, shutdownGraceMs, spawnImpl?, clock? })`
- Method: `start() -> Promise<{ pid, tools }>`
- Method: `callTool(requestId, params) -> Promise<object>`
- Method: `shutdown(reason) -> Promise<void>`
- Method: `snapshot() -> { state, pid, inFlight, lastActivityAt, idleDeadline, lastError, manifestCompatible }`
- Emits: `state` event with the snapshot object.

- [ ] **Step 1: Build the fake Serena fixture**

The fixture must read JSON lines and support environment switches:

```js
const behavior = process.env.FAKE_SERENA_BEHAVIOR ?? 'normal';
// normal: initialize, tools/list, and tools/call succeed
// slow-start: delay initialize beyond the supplied timeout
// crash-on-call: exit after receiving tools/call
// mismatched-tools: return a changed schema from tools/list
```

Expose one fake tool named `echo` whose result returns the provided text.

- [ ] **Step 2: Write failing lifecycle tests**

Cover:

```js
test('does not spawn until start is requested', async () => { /* assert spawn count is zero */ });
test('concurrent starts create one child', async () => { /* await Promise.all([start(), start()]) */ });
test('start performs initialize, initialized notification, and tools/list', async () => { /* assert READY */ });
test('startup timeout terminates the partial child and enters failed state', async () => { /* fake slow-start */ });
test('shutdown waits for active call before stopping', async () => { /* hold fake call open */ });
test('idle timer stops child only after the last call finishes', async () => { /* fake clock */ });
```

- [ ] **Step 3: Run lifecycle tests and verify RED**

Run: `node --test lazy-proxy/test/serena-process.test.mjs`

Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `lazy-proxy/serena-process.mjs`.

- [ ] **Step 4: Implement startup and handshake**

Use `spawn(command, args, { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true })`. On startup send:

```js
{
  jsonrpc: '2.0',
  id: 'lazy-proxy-initialize',
  method: 'initialize',
  params: {
    protocolVersion: manifest.protocolVersion,
    capabilities: {},
    clientInfo: { name: 'lazy-serena-proxy', version: '1.0.0' }
  }
}
```

After the result, send `notifications/initialized`, request `tools/list`, compare it to the manifest, and enter `ready` only when compatible.

- [ ] **Step 5: Implement serialized calls and lifecycle rules**

Maintain one promise chain for calls, `inFlight`, `lastActivityAt`, and a resettable idle timer. Forward only `tools/call`; reject calls in `failed` with MCP error data. Store only sanitized stderr tail lines with a 16 KiB cap. Never log arguments or results.

- [ ] **Step 6: Implement bounded shutdown**

Close stdin and wait `shutdownGraceMs`. If the tree remains, run Windows `taskkill.exe /PID <pid> /T /F`; tests must inject `spawnImpl` so they never kill real processes. Clear all timers and listeners.

- [ ] **Step 7: Run lifecycle tests and verify GREEN**

Run: `node --test lazy-proxy/test/serena-process.test.mjs`

Expected: all lifecycle tests PASS and no fake child remains.

- [ ] **Step 8: Commit Task 2**

```powershell
git add lazy-proxy/serena-process.mjs lazy-proxy/test/serena-process.test.mjs lazy-proxy/test/fixtures/fake-serena.mjs
git commit -m "feat: add lazy Serena process lifecycle"
```

---

### Task 3: MCP Proxy Server and Local Status UI

**Files:**
- Create: `lazy-proxy/server.mjs`
- Create: `lazy-proxy/status-server.mjs`
- Create: `lazy-proxy/cli.mjs`
- Create: `lazy-proxy/test/proxy.integration.test.mjs`
- Create: `lazy-proxy/test/status-server.test.mjs`

**Interfaces:**
- Consumes: protocol helpers, `loadManifest`, `SerenaProcessManager`
- Produces: `createProxyServer({ input, output, manifest, manager, maxQueuedCalls }) -> { run(), close() }`
- Produces: `startStatusServer({ host, port, snapshotProvider }) -> Promise<{ url, close() }>`
- CLI environment: `LAZY_SERENA_MANIFEST`, `LAZY_SERENA_IDLE_MS`, `LAZY_SERENA_STARTUP_MS`, `LAZY_SERENA_STATUS_ADDR`, `LAZY_SERENA_MAX_QUEUE`

- [ ] **Step 1: Write failing proxy integration tests**

The test launches `cli.mjs` as a child and verifies:

```js
test('initialize and tools/list do not start fake Serena', async () => { /* status remains idle */ });
test('first tools/call starts Serena and returns the tool result', async () => { /* state ready */ });
test('concurrent first calls produce one Serena pid', async () => { /* one fixture spawn marker */ });
test('queue overflow returns JSON-RPC -32001 without starting another child', async () => {});
test('unknown tools are rejected before downstream dispatch', async () => {});
test('SIGTERM closes the downstream child', async () => {});
```

- [ ] **Step 2: Run proxy tests and verify RED**

Run: `node --test lazy-proxy/test/proxy.integration.test.mjs`

Expected: FAIL because `server.mjs` and `cli.mjs` do not exist.

- [ ] **Step 3: Implement upstream MCP handling**

Handle these methods without Serena:

- `initialize`: return the manifest protocol version, `{ tools: { listChanged: false } }`, and server info.
- `notifications/initialized`: acknowledge by doing nothing.
- `ping`: return `{}`.
- `tools/list`: return `{ tools: manifest.tools }`.

For `tools/call`, validate the tool name against the manifest, enforce `maxQueuedCalls`, call `manager.start()`, then `manager.callTool()`. Return `-32601` for unsupported requests and ignore unknown notifications.

- [ ] **Step 4: Write failing status-server tests**

Verify `127.0.0.1:0` binding, JSON response at `/status`, safe HTML at `/ui`, no-store headers, and 404 for other paths. Assert the serialized response excludes properties named `apiKey`, `arguments`, `result`, and `stderr`.

- [ ] **Step 5: Implement status server and CLI**

The status JSON contains only:

```js
{
  proxy: 'ready',
  serena: snapshot.state,
  pid: snapshot.pid,
  inFlight: snapshot.inFlight,
  queued: proxy.queued,
  lastActivityAt: snapshot.lastActivityAt,
  idleDeadline: snapshot.idleDeadline,
  manifestVersion: manifest.serenaVersion,
  manifestCompatible: snapshot.manifestCompatible,
  lastError: snapshot.lastError
}
```

Default status address is `127.0.0.1:18012`. Refuse non-loopback hosts. The CLI must write diagnostics to stderr and MCP JSON only to stdout.

- [ ] **Step 6: Run Task 3 tests**

Run: `node --test lazy-proxy/test/proxy.integration.test.mjs lazy-proxy/test/status-server.test.mjs`

Expected: all tests PASS.

- [ ] **Step 7: Run the complete Node suite**

Run: `npm test`

Expected: all Node tests PASS with no child processes left behind.

- [ ] **Step 8: Commit Task 3**

```powershell
git add lazy-proxy/server.mjs lazy-proxy/status-server.mjs lazy-proxy/cli.mjs lazy-proxy/test
git commit -m "feat: add lazy MCP proxy and status UI"
```

---

### Task 4: Serena Tool Manifest Capture

**Files:**
- Create: `lazy-proxy/scripts/capture-manifest.mjs`
- Create: `lazy-proxy/serena-tools.json`
- Create: `lazy-proxy/test/capture-manifest.test.mjs`

**Interfaces:**
- Consumes: protocol helpers and the same downstream handshake used by `SerenaProcessManager`
- CLI: `node lazy-proxy/scripts/capture-manifest.mjs --output lazy-proxy/serena-tools.json`
- Produces: atomic manifest replacement only after successful validation.

- [ ] **Step 1: Write failing capture tests**

Use the fake Serena fixture and a temporary directory. Verify successful capture, unchanged destination on child failure, sorted tools, no temporary file left behind, and no project activation request.

- [ ] **Step 2: Run capture tests and verify RED**

Run: `node --test lazy-proxy/test/capture-manifest.test.mjs`

Expected: FAIL because the capture script does not exist.

- [ ] **Step 3: Implement atomic manifest capture**

Start `serena start-mcp-server --context chatgpt`, initialize it, request `tools/list`, call `serena --version` separately, validate the result, write `<output>.tmp`, then rename it over the destination. Always terminate the child in `finally`. Never call `tools/call` or `activate_project`.

- [ ] **Step 4: Run capture tests and verify GREEN**

Run: `node --test lazy-proxy/test/capture-manifest.test.mjs`

Expected: all capture tests PASS.

- [ ] **Step 5: Capture the real Serena manifest**

Run: `node lazy-proxy/scripts/capture-manifest.mjs --output lazy-proxy/serena-tools.json`

Expected: exit 0, manifest version 1, Serena version `1.7.0`, 29 tools, and no active project.

- [ ] **Step 6: Validate the captured manifest**

Run:

```powershell
node -e "import('./lazy-proxy/manifest.mjs').then(async m => console.log((await m.loadManifest('lazy-proxy/serena-tools.json')).tools.length))"
```

Expected: prints `29`.

- [ ] **Step 7: Commit Task 4**

```powershell
git add lazy-proxy/scripts/capture-manifest.mjs lazy-proxy/serena-tools.json lazy-proxy/test/capture-manifest.test.mjs
git commit -m "feat: add versioned Serena tool manifest"
```

---

### Task 5: Profile Rendering and Reliable Tunnel Supervision

**Files:**
- Create: `scripts/lazy-common.ps1`
- Create: `scripts/lazy-supervisor.ps1`
- Create: `tests/lazy-launcher.Tests.ps1`
- Modify: `profiles/serena-team.yaml`
- Modify: `start.ps1`
- Modify: `tests/validate.ps1`

**Interfaces:**
- Produces: `Get-LazyRuntimeConfig -RepoRoot <path>`
- Produces: `Write-LazyTunnelProfile -TemplatePath <path> -DestinationPath <path> -TunnelId <id> -ProxyCommand <command>`
- Produces: `Get-DpapiApiKey -SecretPath <path>`
- Produces: `Start-LazyTunnel -RepoRoot <path> -MaxRestarts 3 -RestartWindowMinutes 10 -Once:$false`
- Profile placeholder: `__LAZY_PROXY_COMMAND__`

- [ ] **Step 1: Write failing PowerShell tests**

Create `tests/lazy-launcher.Tests.ps1` as a dependency-free script with a local `Assert-True` helper and injected fake process-launch functions. Tests must verify:

- Profile rendering replaces both placeholders and preserves `127.0.0.1:18010`.
- The rendered command invokes `node.exe`, `lazy-proxy/cli.mjs`, the manifest path, `serena`, 900000 ms idle timeout, 30000 ms startup timeout, and `127.0.0.1:18012` status.
- API key plaintext is never returned from a formatting or status function.
- Restart policy allows at most three starts in ten minutes.
- A native child writing stderr does not terminate the PowerShell supervisor.

- [ ] **Step 2: Run launcher tests and verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\lazy-launcher.Tests.ps1`

Expected: FAIL because lazy helper scripts and the profile placeholder do not exist.

- [ ] **Step 3: Implement common helpers**

Resolve `node.exe`, `serena.exe`, the proxy CLI, manifest, tunnel client, DPAPI secret, tunnel ID, and profile destination. Render a quoted proxy command without shell interpolation. Reject paths containing newline or quote characters that cannot be represented safely.

- [ ] **Step 4: Change the public profile template**

Replace:

```yaml
command: serena start-mcp-server --context chatgpt
```

with:

```yaml
command: __LAZY_PROXY_COMMAND__
```

Keep `api_key: "env:CONTROL_PLANE_API_KEY"`, `127.0.0.1:18010`, and `open_browser: false` unchanged.

- [ ] **Step 5: Implement bounded supervision**

`lazy-supervisor.ps1` decrypts the API key, renders the profile, starts `tunnel-client.exe run --profile dwb-serena` with `Start-Process -PassThru -WindowStyle Hidden`, waits for exit, clears plaintext references, and restarts at most three times inside ten minutes. `-Once` disables restart for manual diagnostics. Do not pipe native stderr through a terminating PowerShell error stream.

- [ ] **Step 6: Refactor `start.ps1` to use the supervisor**

Retain prerequisite output and preflight, then invoke `scripts/lazy-supervisor.ps1 -Once`. Ensure preflight runs before the long-lived process and that informational Serena stderr cannot abort the starter.

- [ ] **Step 7: Extend public validation**

Add Node version >=20, required lazy files, profile placeholder, loopback health/status addresses, PowerShell syntax, forbidden secret patterns, and absence of direct `serena start-mcp-server` in the tunnel profile.

- [ ] **Step 8: Run Task 5 tests and validation**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\lazy-launcher.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\validate.ps1
```

Expected: launcher tests pass and validation prints `All public-readiness checks passed.`

- [ ] **Step 9: Run the Node suite**

Run: `npm test`

Expected: all Node tests PASS.

- [ ] **Step 10: Commit Task 5**

```powershell
git add scripts profiles/serena-team.yaml start.ps1 tests package.json
git commit -m "feat: supervise the lazy Serena tunnel"
```

---

### Task 6: User-Logon Control, Documentation, and Controlled Rollout

**Files:**
- Create: `scripts/lazy-control.ps1`
- Create: `Lazy-Control.cmd`
- Create: `tests/lazy-control.Tests.ps1`
- Modify: `README.md`
- Modify: `README.th.md`
- Modify: `SECURITY.md`
- Modify: `tests/validate.ps1`

**Interfaces:**
- CLI: `Lazy-Control.cmd install|start|status|stop|uninstall`
- Scheduled Task name: `DWB Serena Lazy Tunnel`
- PID files: `%APPDATA%\tunnel-client\dwb-serena-tunnel.pid` and `%APPDATA%\tunnel-client\dwb-serena-proxy.pid`
- Backup profile: `%APPDATA%\tunnel-client\backups\dwb-serena.<UTC timestamp>.yaml`

- [ ] **Step 1: Write failing control-script tests**

Mock ScheduledTasks and process commands. Verify:

- `install` creates a current-user logon task with hidden PowerShell and the exact supervisor path.
- `install` backs up the existing profile before rendering the lazy profile.
- `status` reports tunnel PID, proxy status URL, Serena state/PID, and idle deadline without secrets.
- `stop` requests graceful shutdown, then kills only verified descendant PIDs after timeout.
- `uninstall` removes only the named task, stops the stack, and restores the latest valid backup.
- Missing or stale PID files never cause an unrelated process to be stopped; executable path and command line must match first.

- [ ] **Step 2: Run control tests and verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\lazy-control.Tests.ps1`

Expected: FAIL because `scripts/lazy-control.ps1` does not exist.

- [ ] **Step 3: Implement control actions**

Use `Register-ScheduledTask` with an `AtLogOn` trigger for the current user, `-WindowStyle Hidden`, and no elevated principal. Record verified PIDs only after health checks pass. Every stop action validates process executable path and profile arguments before termination.

- [ ] **Step 4: Add the operator wrapper**

Create `Lazy-Control.cmd` that accepts exactly one action and delegates to:

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\lazy-control.ps1" -Action "%~1"
```

Reject missing or unsupported actions with usage text.

- [ ] **Step 5: Update English and Thai documentation**

Document the on-demand behavior, always-on tunnel/proxy impact, 15-minute idle stop, no automatic project activation, health URLs `18010` and `18012`, install/start/status/stop/uninstall commands, expected first-call delay, manifest refresh, Start.cmd stderr fix, and byte-for-byte rollback procedure.

- [ ] **Step 6: Update security documentation**

Document DPAPI inheritance, localhost-only listeners, sanitized status/log fields, Scheduled Task scope, PID verification, manifest trust boundary, and the fact that tunnel connectivity allows authenticated remote MCP tool calls.

- [ ] **Step 7: Run all offline tests**

Run:

```powershell
npm test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\validate.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\lazy-control.Tests.ps1
```

Expected: all commands exit 0; no Serena or tunnel process is created by offline tests.

- [ ] **Step 8: Back up current runtime state**

Record current tunnel and Serena PIDs. Copy `%APPDATA%\tunnel-client\dwb-serena.yaml` to the timestamped backup directory and verify SHA-256 equality before changing the active profile.

- [ ] **Step 9: Stop the current direct-run stack safely**

Verify the tunnel process executable is the repository's `tunnel-client.exe` and its arguments contain `run --profile dwb-serena`. Stop its descendant Serena `--context chatgpt` tree, then the tunnel. Confirm ports `18010` and the chatgpt Serena dashboard port are no longer listening.

- [ ] **Step 10: Start the lazy stack without installing auto-start**

Run: `Lazy-Control.cmd start`

Expected: tunnel health `http://127.0.0.1:18010/ui` returns 200; proxy status `http://127.0.0.1:18012/status` reports `serena: idle`; no process command contains `start-mcp-server --context chatgpt`.

- [ ] **Step 11: Verify a real GPT call**

From GPT, call a non-mutating Serena tool such as `get_current_config`. Verify exactly one Serena process appears, the tool result returns, context is `chatgpt`, and active project remains `None`.

- [ ] **Step 12: Verify idle shutdown using a test override**

Temporarily start the proxy with `LAZY_SERENA_IDLE_MS=5000` in the controlled test launch, make one non-mutating call, and verify Serena exits after at least five idle seconds while tunnel and proxy remain alive. Restore the production value `900000` before continuing.

- [ ] **Step 13: Install and verify user-logon auto-start**

Run: `Lazy-Control.cmd install`, inspect the task definition, and run the task once without logging off. Verify tunnel and proxy are alive, Serena is idle, restart attempts are bounded, and no elevated principal is configured.

- [ ] **Step 14: Run rollback rehearsal**

Run `Lazy-Control.cmd uninstall`, verify the task is gone and the original profile hash is restored, then reinstall. Do not delete Serena configuration, memories, projects, or the DPAPI key.

- [ ] **Step 15: Final verification**

Run all offline tests again, `Lazy-Control.cmd status`, HTTP checks for both health endpoints, a process-tree check proving one tunnel/one proxy/no idle Serena, and `git diff --check`.

- [ ] **Step 16: Commit Task 6**

```powershell
git add scripts/lazy-control.ps1 Lazy-Control.cmd tests README.md README.th.md SECURITY.md
git commit -m "feat: add on-demand Serena startup controls"
```

## Completion Checklist

- [ ] Every spec requirement maps to a task above.
- [ ] Opening GPT and `tools/list` leaves Serena stopped.
- [ ] First real tool call starts exactly one Serena child and succeeds.
- [ ] Serena stops after 15 idle minutes and restarts on the next real call.
- [ ] No project is activated automatically.
- [ ] Tunnel/proxy listeners are loopback-only.
- [ ] Secrets and project data are absent from logs and status.
- [ ] Auto-start is user-scoped, bounded, and reversible.
- [ ] Original profile rollback is verified by SHA-256.
- [ ] Offline and live integration checks pass.
