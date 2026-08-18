# Local configuration

`Configure.cmd` creates two local files in this directory:

- `team.ps1` — Tunnel ID only
- `api-key.dpapi` — OpenAI Runtime API key encrypted with Windows DPAPI

Both files are ignored by Git.

All other files created in this directory are ignored by default; only this README is tracked. Do not manually force-add local configuration or credential files.
