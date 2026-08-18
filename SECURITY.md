# Security

This starter handles credentials locally and is designed to avoid committing secrets.

## Secrets

`Configure.cmd` creates:

- `config/team.ps1` — contains the Tunnel ID
- `config/api-key.dpapi` — contains the Runtime API key encrypted with Windows DPAPI

Both paths are ignored by Git.

The Runtime API key is protected by Windows DPAPI only while stored on disk. `Start.cmd` decrypts it into the tunnel-client process environment for the lifetime of the process. Stop the client when it is not in use and treat local administrator access as trusted.

## Serena access boundary

Serena can provide tools that read and modify files and execute shell commands. Activate only the local project you intend to expose, use only trusted ChatGPT workspaces and tunnel principals, review tool calls, and use a sandbox or container for sensitive projects.

## If a key is exposed

Revoke or rotate the exposed OpenAI API key immediately, then run `Configure.cmd` again with the replacement key.

Do not post API keys, tunnel credentials, or secret-bearing logs in public GitHub issues.

## Reporting a vulnerability

Use the repository's **Security → Report a vulnerability** flow to send a private GitHub security advisory. Do not include a secret, exploit, or sensitive log in a public issue.

If private vulnerability reporting is not available, open a minimal public issue asking the maintainer for a private contact channel. Include no sensitive technical details until a private channel is established.

## Third-party runtime

`Setup.cmd` downloads the OpenAI tunnel-client from the official `openai/tunnel-client` GitHub release. The downloaded runtime is not committed to this repository.

When `SHA256SUMS.txt` is present in the release, setup requires a matching checksum entry and verifies the archive before extraction. If a release does not publish a checksum file, setup prints an explicit warning.
