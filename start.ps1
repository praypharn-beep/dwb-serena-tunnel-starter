$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
$Client = Join-Path $Root 'tunnel-client\tunnel-client.exe'
$ProfileTemplate = Join-Path $Root 'profiles\serena-team.yaml'
$LocalConfig = Join-Path $Root 'config\team.ps1'
$SecretPath = Join-Path $Root 'config\api-key.dpapi'
$ProfileName = 'dwb-serena'

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

. (Join-Path $Root 'scripts\lazy-common.ps1')

try {
    $Config = Get-LazyRuntimeConfig -RepoRoot $Root -TunnelIdOverride $TunnelId
}
catch {
    Fail "Lazy proxy is not ready: $($_.Exception.Message)"
}

try {
    Write-LazyTunnelProfile -TemplatePath $Config.ProfileTemplatePath -DestinationPath $Config.ProfileDestinationPath -TunnelId $Config.TunnelId -ProxyCommand $Config.ProxyCommand | Out-Null
}
catch {
    Fail "Could not render the tunnel profile: $($_.Exception.Message)"
}

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
Write-Host 'Context : built-in chatgpt (starts on first tool call, stops after 15 idle minutes)'
Write-Host 'Health  : http://127.0.0.1:18010/ui'
Write-Host "Status  : http://$($Config.StatusAddress)/status"
Write-Host 'API key : decrypted locally with Windows DPAPI'
Write-Host ''
Write-Host 'Keep this window open while using ChatGPT.' -ForegroundColor Yellow
Write-Host ''

Write-Host 'Running tunnel-client preflight checks...' -ForegroundColor Cyan
try {
    $PreflightApiKey = Get-DpapiApiKey -SecretPath $Config.DpapiSecretPath
}
catch {
    Fail "Could not decrypt the API key for preflight: $($_.Exception.Message)"
}
$env:CONTROL_PLANE_API_KEY = $PreflightApiKey
$PreviousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $DoctorOutput = & $Client doctor --profile $ProfileName --explain 2>&1
    $DoctorExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $PreviousErrorActionPreference
    $PreflightApiKey = $null
    $env:CONTROL_PLANE_API_KEY = $null
}
Write-Host ($DoctorOutput -join "`n")
if ($DoctorExitCode -ne 0) {
    Fail 'Tunnel preflight failed. Review the diagnostics above, then run Start.cmd again.'
}
Write-Host 'Preflight : passed' -ForegroundColor Green
Write-Host ''

$SupervisorScript = Join-Path $Root 'scripts\lazy-supervisor.ps1'
& $SupervisorScript -Once
exit $LASTEXITCODE
