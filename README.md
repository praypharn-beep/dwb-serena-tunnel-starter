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

## Security notes

- **Do not use an OpenAI Admin API key for the tunnel daemon.** Use a Runtime API key intended for tunnel use.
- Never paste API keys into GitHub issues, screenshots, videos, or commits.
- `config\api-key.dpapi` is encrypted with Windows DPAPI and is intended to be usable only by the Windows user that created it.
- If you copy this starter to another PC or another Windows account, run `Configure.cmd` again.
- If a key is accidentally exposed, revoke/rotate it immediately from the OpenAI Platform.
- Serena can expose tools that read and modify files and execute shell commands. Connect only trusted OpenAI/ChatGPT workspaces and activate only the intended local project.
- Review tool calls before approval. For sensitive source code, run Serena in an appropriately sandboxed environment.
- Windows DPAPI protects the API key at rest. While the tunnel is running, the key is decrypted into the tunnel-client process environment and is accessible to that process and trusted local administrators.
- Stop `Start.cmd` whenever the tunnel is not in use.

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
Serena MCP Server
   │
   ▼
Local Workspace / Project
```

The tunnel profile launches Serena with:

```text
serena start-mcp-server --context chatgpt
```

## Repository layout

```text
serena-tunnel/
├─ Setup.cmd
├─ setup.ps1
├─ Configure.cmd
├─ configure.ps1
├─ Start.cmd
├─ start.ps1
├─ profiles/
│  └─ serena-team.yaml
├─ config/
│  └─ README.md
├─ examples/
│  └─ flowpilot-ai-landing-page.md
├─ tests/
│  └─ validate.ps1
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
