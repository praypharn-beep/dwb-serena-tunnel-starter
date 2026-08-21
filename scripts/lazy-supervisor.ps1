param(
    [switch]$Once
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lazy-common.ps1')

try {
    $ExitCode = Start-LazyTunnel -RepoRoot $RepoRoot -MaxRestarts 3 -RestartWindowMinutes 10 -Once:$Once
    exit $ExitCode
}
catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    exit 1
}
