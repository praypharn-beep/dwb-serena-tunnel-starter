$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
$Client = Join-Path $Root 'tunnel-client\tunnel-client.exe'
$ProfileTemplate = Join-Path $Root 'profiles\serena-team.yaml'
$LocalConfig = Join-Path $Root 'config\team.ps1'
$SecretPath = Join-Path $Root 'config\api-key.dpapi'
$ProfileName = 'dwb-serena'
$ProfilePath = Join-Path $env:USERPROFILE ".config\tunnel-client\$ProfileName.yaml"

function Fail([string]$Message) {
    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Write-Host ''
    exit 1
}

if (-not (Test-Path $Client)) {
    Fail 'tunnel-client.exe is not installed. Run Setup.cmd first.'
}

if (-not (Test-Path $ProfileTemplate)) {
    Fail "Tunnel profile template not found: $ProfileTemplate"
}

if (-not (Test-Path $LocalConfig) -or -not (Test-Path $SecretPath)) {
    Fail 'Tunnel ID or API key has not been configured. Run Configure.cmd first.'
}

$Serena = Get-Command serena -ErrorAction SilentlyContinue
if (-not $Serena) {
    Fail 'Serena is not installed or the serena command is not available in PATH.'
}

$PreviousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $SerenaVersion = & $Serena.Source --version 2>&1
    $SerenaExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $PreviousErrorActionPreference
}
if ($SerenaExitCode -ne 0) {
    Fail "The Serena command exists but cannot start. Repair the Serena installation and run Start.cmd again. Details: $($SerenaVersion -join ' ')"
}

. $LocalConfig

if ([string]::IsNullOrWhiteSpace($TunnelId) -or $TunnelId -cnotmatch '^tunnel_[0-9a-f]{32}$') {
    Fail 'Tunnel ID is missing or invalid. Run Configure.cmd again.'
}

try {
    $EncryptedKey = (Get-Content -Raw -Path $SecretPath).Trim()
    $SecureKey = ConvertTo-SecureString $EncryptedKey
    $ControlPlaneApiKey = [System.Net.NetworkCredential]::new('', $SecureKey).Password
}
catch {
    Fail 'Could not decrypt the API key. Run Configure.cmd again under the same Windows user.'
}

if ([string]::IsNullOrWhiteSpace($ControlPlaneApiKey)) {
    Fail 'Decrypted API key is empty. Run Configure.cmd again.'
}

$env:CONTROL_PLANE_API_KEY = $ControlPlaneApiKey

$ConfigDir = Split-Path -Parent $ProfilePath
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

$Content = Get-Content -Raw -Path $ProfileTemplate
$Content = $Content.Replace('__TUNNEL_ID__', $TunnelId)
Set-Content -Path $ProfilePath -Value $Content -Encoding utf8

$InstalledVersionPath = Join-Path $Root 'tunnel-client\.installed-version'
$InstalledVersion = if (Test-Path $InstalledVersionPath) { (Get-Content -Raw $InstalledVersionPath).Trim() } else { 'unknown' }

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ' DWB Local Workspace - Serena Tunnel' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host "Profile : $ProfileName"
Write-Host "Tunnel  : $TunnelId"
Write-Host "Client  : $InstalledVersion"
Write-Host "Serena  : $($Serena.Source) ($($SerenaVersion -join ' '))"
Write-Host 'Context : built-in chatgpt'
Write-Host 'Health  : http://127.0.0.1:18010/ui'
Write-Host 'API key : decrypted locally with Windows DPAPI'
Write-Host ''
Write-Host 'Keep this window open while using ChatGPT.' -ForegroundColor Yellow
Write-Host ''

Write-Host 'Running tunnel-client preflight checks...' -ForegroundColor Cyan
& $Client doctor --profile $ProfileName --explain
if ($LASTEXITCODE -ne 0) {
    Fail 'Tunnel preflight failed. Review the diagnostics above, then run Start.cmd again.'
}
Write-Host 'Preflight : passed' -ForegroundColor Green
Write-Host ''

Push-Location (Split-Path -Parent $Client)
try {
    & $Client run --profile $ProfileName
    if ($LASTEXITCODE -ne 0) {
        Fail "Tunnel client exited with code $LASTEXITCODE."
    }
}
finally {
    $env:CONTROL_PLANE_API_KEY = $null
    $ControlPlaneApiKey = $null
    Pop-Location
}
