# DWB Serena Tunnel Starter

A small Windows starter kit for connecting **ChatGPT → OpenAI Secure MCP Tunnel → Serena → your local workspace**.

ชุด Starter สำหรับ Windows เพื่อเชื่อม **ChatGPT → OpenAI Secure MCP Tunnel → Serena → Local Workspace** โดยไม่ต้องเปิด MCP server ออก Internet โดยตรง

ภาษาไทย: **[README.th.md](README.th.md)**

> Community starter by **Dev with Bebz**. This repository is not an official OpenAI or Serena distribution.
>
> 🎥 **Video walkthrough:** https://youtu.be/18S_QaMpUtY

## What this repo does

- Downloads the latest stable **OpenAI tunnel-client** Windows release from the official `openai/tunnel-client` GitHub repository.
- Uses your locally installed **Serena** MCP server.
- First-time setup asks only for your Tunnel ID and OpenAI Runtime API key.
- Stores the API key locally with **Windows DPAPI** instead of plaintext.
- Starts Serena using its built-in `chatgpt` context.

## Requirements

- Windows 10/11 (x64 or ARM64)
- PowerShell 5.1+
- `uv`
- Serena installed and initialized
- An OpenAI Secure MCP Tunnel ID
- An OpenAI **Runtime API key** that can use the tunnel
- OpenAI Platform permission **Tunnels Read + Use**
- ChatGPT developer-mode access in the workspace you will use

### Install Serena

Official Serena installation:

```powershell
uv tool install -p 3.13 serena-agent
serena init
```

Verify:

```powershell
serena --help
```

Before continuing, create or select a tunnel in [OpenAI Platform tunnel settings](https://platform.openai.com/settings/organization/tunnels), associate it with the intended Platform organization and ChatGPT workspace, and create a Runtime API key for the daemon. Creating or editing a tunnel requires **Tunnels Read + Manage**; running it and selecting it in ChatGPT requires **Tunnels Read + Use**.

## Quick Start

### 1. Download this repository

Use **Code → Download ZIP** on GitHub, extract it anywhere, or clone it with Git.

The starter does not depend on a fixed path such as `C:\tools\serena-tunnel`.

### 2. Run Setup once

Double-click:

```text
Setup.cmd
```

Setup will:

1. Check that Serena is available.
2. Download the latest stable Windows release of OpenAI `tunnel-client` from the official GitHub release.
3. Verify SHA-256 when the release checksum file is available.
4. Ask for your Tunnel ID (`tunnel_...`).
5. Ask for your OpenAI **Runtime API key**.
6. Encrypt the API key locally with Windows DPAPI.

The Tunnel ID must be `tunnel_` followed by 32 lowercase hexadecimal characters.

The Tunnel ID is stored locally in:

```text
config\team.ps1
```

The API key is encrypted for the current Windows user and stored in:

```text
config\api-key.dpapi
```

Both files are excluded by `.gitignore`.

### 3. Start

Double-click:

```text
Start.cmd
```

Keep the window open while ChatGPT is using Serena.

Before starting the daemon, the script runs `tunnel-client doctor --profile dwb-serena --explain`. If a preflight check fails, fix the reported problem and run `Start.cmd` again.

Local tunnel status UI:

```text
http://127.0.0.1:18010/ui
```

### 4. Add the tunnel in ChatGPT

When the local UI reports that the tunnel is ready:

1. Enable developer mode for your ChatGPT workspace if it is not already enabled.
2. Open [ChatGPT Plugins](https://chatgpt.com/plugins).
3. Select the plus button to create a developer-mode app.
4. Choose **Tunnel** under **Connection**.
5. Select the tunnel from the list, or paste your valid Tunnel ID.

If the tunnel does not appear, confirm that it is associated with the target ChatGPT workspace and that your account has **Tunnels Read + Use**.

### 5. Activate the local project

This starter intentionally does not hard-code a project path, so one tunnel setup can be used with different local projects. At the beginning of a ChatGPT conversation, explicitly activate only the project you intend to expose:

```text
Use Serena to activate the project C:\path\to\your\project, then show the current Serena configuration.
```

Review the returned project path before asking ChatGPT to read or modify files. Serena keeps one coding project active at a time.

### 6. Try the demo prompt

After Serena is connected and your local project is active, try the same prompt used in the **Dev with Bebz** demo:

🎥 Watch the walkthrough: https://youtu.be/18S_QaMpUtY

**[FlowPilot AI Landing Page Test Prompt](examples/flowpilot-ai-landing-page.md)**

It asks ChatGPT + Serena to create a production-style **FlowPilot AI** SaaS landing page. This is useful as an end-to-end test that ChatGPT can work with your local project through Serena.

## Daily use

After first-time setup, normally you only need:

```text
Start.cmd
```

Use `Configure.cmd` if you need to replace the Tunnel ID or Runtime API key.

Use `Setup.cmd` again if you want to refresh the local tunnel-client to the latest stable release. It will also ask you to configure the credentials again.

Close the `Start.cmd` window when you are finished. The tunnel is available only while the client remains running.

## On-demand Serena (lazy start)

`Start.cmd` no longer launches Serena directly. It renders a tunnel profile whose MCP command is a small lazy proxy (`lazy-proxy/cli.mjs`) that sits between `tunnel-client` and Serena:

```text
ChatGPT → tunnel-client → lazy proxy → Serena (started on demand)
```

- **The tunnel and the proxy stay running** the whole time `Start.cmd` (or the lazy control stack, below) is up. Only the **Serena child process** is lazy.
- Serena is **not** started when `Start.cmd` opens, when ChatGPT connects, or when it calls `tools/list`. It starts on the **first real `tools/call`**.
- Serena runs as a **singleton** — concurrent calls are queued for the one Serena instance rather than starting a second one.
- Serena **stops automatically after 15 minutes of inactivity** (`900000` ms) and restarts on the next real tool call. Expect a short delay (typically a few seconds, bounded by a 30-second startup timeout) on the first call after Serena has been idle-stopped or has never started this session.
- **No project is activated automatically.** Activating a project is still an explicit step you take from ChatGPT (see [Activate the local project](#5-activate-the-local-project)), independent of whether Serena happens to be running.
- The lazy proxy's tool manifest is captured once from your locally installed Serena and versioned; if Serena's own tool set doesn't match the captured manifest, the proxy still runs but reports `manifestCompatible: false` in its status so you can recapture it if needed.

### Health and status URLs

| URL | What it shows |
| --- | --- |
| `http://127.0.0.1:18010/ui` | Tunnel connection health (same as before). |
| `http://127.0.0.1:18012/status` | Lazy proxy JSON status: `proxy`, `serena` (state), `pid`, `inFlight`, `queued`, `lastActivityAt`, `idleDeadline`, `manifestVersion`, `manifestCompatible`, `lastError`. |

Both listeners are bound to `127.0.0.1` only. The status endpoint never returns secrets, MCP tool arguments/results, or project data.

### A note on `Start.cmd` reliability

`Start.cmd`'s preflight and tunnel launch now go through the same bounded restart supervisor used by the lazy control stack below. A native child process (`tunnel-client.exe`) writing to its own stderr can no longer be mistaken for a PowerShell error and abort the window early.

## User-logon auto-start (`Lazy-Control.cmd`)

For unattended, always-available access (so the tunnel/proxy come up automatically when you log in, without leaving a `Start.cmd` window open), use `Lazy-Control.cmd` instead of `Start.cmd`:

```text
Lazy-Control.cmd install     Register a current-user logon task that starts the supervisor hidden.
Lazy-Control.cmd start       Start the tunnel/proxy supervisor right now, without installing auto-start.
Lazy-Control.cmd status      Show tunnel/proxy/Serena status (PIDs, health URLs, idle deadline) without secrets.
Lazy-Control.cmd stop        Stop the tunnel/proxy stack.
Lazy-Control.cmd uninstall   Remove the logon task, stop the stack, and restore the previous tunnel profile.
```

Details:

- The logon task is named **`DWB Serena Lazy Tunnel`**, triggers `AtLogOn` for the current Windows user only, runs a **hidden** PowerShell window, and is registered with a **non-elevated (Limited)** run level — it never requests administrator rights.
- `install` persists resilience settings for the long-running tunnel: `StartWhenAvailable`, restart-on-failure (10 attempts at 1-minute intervals), unlimited execution time, `IgnoreNew` duplicate-instance protection, battery-safe continuation, and idle-end termination disabled.
- The supervisor records its own PID, the active `tunnel-client.exe` PID, the lazy proxy PID, and a bounded lifecycle log under `%APPDATA%\tunnel-client\`. This keeps an orphan client identifiable if the supervisor is terminated externally.
- `install` and `start` render the tunnel profile from the same template `Start.cmd` uses, so the profile always points at the lazy proxy, never at Serena directly.
- `install` **backs up the current tunnel profile** before rendering, to `%APPDATA%\tunnel-client\backups\dwb-serena.<UTC timestamp>.yaml` (for example `dwb-serena.20260821T100000Z.yaml`), before overwriting it.
- `stop` and `uninstall` verify a managed process's **executable path and command line** before sending it any stop signal, and re-verify immediately before a forced termination. A missing, stale, or reused PID is left alone rather than acted on — see [Security](#security) below.
- `status` never touches or displays the decrypted API key.

### Rollback (byte-for-byte)

If you need to return to a previous tunnel profile exactly as it was:

1. Run `Lazy-Control.cmd uninstall`. This removes the logon task, stops the stack, and automatically restores the **newest valid backup** from `%APPDATA%\tunnel-client\backups\` over the active profile.
2. To restore a specific earlier backup instead, copy the desired `dwb-serena.<timestamp>.yaml` file from `%APPDATA%\tunnel-client\backups\` over `%APPDATA%\tunnel-client\dwb-serena.yaml`, byte for byte (do not hand-edit it).
3. Run `Start.cmd` (or `Lazy-Control.cmd start`) again to pick up the restored profile.

`install` never deletes a backup, so every profile it has ever replaced remains available under `%APPDATA%\tunnel-client\backups\` for rollback.

## Security notes

- **Do not use an OpenAI Admin API key for the tunnel daemon.** Use a Runtime API key intended for tunnel use.
- Never paste API keys into GitHub issues, screenshots, videos, or commits.
- `config\api-key.dpapi` is encrypted with Windows DPAPI and is intended to be usable only by the Windows user that created it.
- If you copy this starter to another PC or another Windows account, run `Configure.cmd` again.
- If a key is accidentally exposed, revoke/rotate it immediately from the OpenAI Platform.
- Serena can expose tools that read and modify files and execute shell commands. Connect only trusted OpenAI/ChatGPT workspaces and activate only the intended local project.
- Review tool calls before approval. For sensitive source code, run Serena in an appropriately sandboxed environment.
- Windows DPAPI protects the API key at rest. While the tunnel is running, the key is decrypted into the tunnel-client process environment and is accessible to that process and trusted local administrators.
- Stop `Start.cmd` whenever the tunnel is not in use (or run `Lazy-Control.cmd stop` / `uninstall` if you installed the logon task).
- The lazy proxy and tunnel-client listeners are loopback-only (`127.0.0.1`); the status endpoint (`18012`) never exposes secrets, tool arguments/results, or project paths.
- `Lazy-Control.cmd install` registers a **user-scoped, non-elevated** logon task. `stop`/`uninstall` verify a process's executable path and command line before ever sending it a stop signal — see [SECURITY.md](SECURITY.md) for the full threat model.
- Keeping the tunnel/proxy running (even while Serena itself is idle) still means an authenticated tunnel principal can trigger a real Serena start and tool call at any time; treat "tunnel connected" the same as "Serena reachable" from a trust perspective.

## Troubleshooting

### Serena was found but cannot start

Verify the command directly:

```powershell
serena --version
serena --help
```

If the installation is damaged, reinstall the official package and initialize it again:

```powershell
uv tool uninstall serena-agent
uv tool install -p 3.13 serena-agent
serena init
```

### Tunnel preflight failed

Read the `doctor --explain` output in the `Start.cmd` window. Common causes are an invalid or unauthorized Runtime API key, a Tunnel ID associated with the wrong organization/workspace, or a broken Serena command.

### Tunnel is ready but missing in ChatGPT

Confirm all three items:

1. The tunnel is associated with the intended ChatGPT workspace.
2. Your account has **Tunnels Read + Use**.
3. ChatGPT developer mode is enabled for that workspace.

## How it works

```text
ChatGPT
   │
   │ OpenAI Secure MCP Tunnel
   ▼
tunnel-client
   │
   │ stdio
   ▼
lazy-proxy (lazy-proxy/cli.mjs) — always running once the tunnel is up
   │
   │ starts Serena on the first real tools/call; stops it after 15 idle minutes
   ▼
Serena MCP Server (start-mcp-server --context chatgpt)
   │
   ▼
Local Workspace / Project
```

The tunnel profile's MCP command launches the lazy proxy, not Serena directly. The proxy itself launches Serena with:

```text
serena start-mcp-server --context chatgpt
```

only once the first real tool call arrives.

## Repository layout

```text
serena-tunnel/
├─ Setup.cmd
├─ setup.ps1
├─ Configure.cmd
├─ configure.ps1
├─ Start.cmd
├─ start.ps1
├─ Lazy-Control.cmd
├─ profiles/
│  └─ serena-team.yaml
├─ config/
│  └─ README.md
├─ lazy-proxy/
│  ├─ cli.mjs
│  ├─ server.mjs
│  ├─ status-server.mjs
│  ├─ serena-process.mjs
│  ├─ manifest.mjs
│  ├─ protocol.mjs
│  └─ serena-tools.json
├─ scripts/
│  ├─ lazy-common.ps1
│  ├─ lazy-supervisor.ps1
│  └─ lazy-control.ps1
├─ examples/
│  └─ flowpilot-ai-landing-page.md
├─ tests/
│  ├─ validate.ps1
│  ├─ lazy-launcher.Tests.ps1
│  └─ lazy-control.Tests.ps1
├─ .github/workflows/
│  └─ validate.yml
├─ README.md
├─ README.th.md
├─ SECURITY.md
├─ LICENSE
└─ .gitignore
```

`tunnel-client/` is created locally by `Setup.cmd` and is intentionally not committed to this repository.

## Demo prompts

Prompts used in Dev with Bebz demos are kept under [`examples/`](examples/), so viewers can reproduce the same workflow shown in the videos.

Current example:

- [FlowPilot AI Landing Page](examples/flowpilot-ai-landing-page.md)

## Official references

- OpenAI Secure MCP Tunnel guide: https://developers.openai.com/api/docs/guides/secure-mcp-tunnels
- OpenAI Platform tunnel settings: https://platform.openai.com/settings/organization/tunnels
- OpenAI tunnel-client: https://github.com/openai/tunnel-client
- OpenAI tunnel-client releases: https://github.com/openai/tunnel-client/releases/latest
- Serena: https://github.com/oraios/serena
- Serena installation: https://oraios.github.io/serena/02-usage/010_installation.html
- Serena security considerations: https://oraios.github.io/serena/02-usage/070_security.html

## License

The starter scripts in this repository are released under the MIT License. Third-party software downloaded by `Setup.cmd` keeps its own license and notices.
