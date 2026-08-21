$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

Write-Host 'Checking PowerShell syntax...'
$ScriptFiles = @('setup.ps1', 'configure.ps1', 'start.ps1', 'scripts\lazy-common.ps1', 'scripts\lazy-supervisor.ps1', 'scripts\lazy-control.ps1')
foreach ($ScriptFile in $ScriptFiles) {
    $Path = Join-Path $RepoRoot $ScriptFile
    $Tokens = $null
    $Errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors) | Out-Null
    Assert-True ($Errors.Count -eq 0) "$ScriptFile contains PowerShell syntax errors."
}

Write-Host 'Checking Tunnel ID validation...'
$TunnelIdPattern = '^tunnel_[0-9a-f]{32}$'
Assert-True ('tunnel_0123456789abcdef0123456789abcdef' -cmatch $TunnelIdPattern) 'A valid Tunnel ID was rejected.'
Assert-True ('tunnel_ABCDEF0123456789ABCDEF0123456789' -cnotmatch $TunnelIdPattern) 'An uppercase Tunnel ID was accepted.'
Assert-True ('tunnel_short' -cnotmatch $TunnelIdPattern) 'A short Tunnel ID was accepted.'

foreach ($ScriptFile in @('configure.ps1', 'start.ps1')) {
    $Content = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot $ScriptFile)
    Assert-True ($Content.Contains("-cnotmatch '^tunnel_[0-9a-f]{32}$'")) "$ScriptFile must enforce the case-sensitive Tunnel ID format."
}

Write-Host 'Checking the public profile...'
$ProfileContent = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'profiles\serena-team.yaml')
Assert-True ($ProfileContent.Contains('tunnel_id: "__TUNNEL_ID__"')) 'The public profile must contain the Tunnel ID placeholder.'
Assert-True ($ProfileContent.Contains('api_key: "env:CONTROL_PLANE_API_KEY"')) 'The public profile must read the API key from the environment.'
Assert-True ($ProfileContent.Contains('listen_addr: 127.0.0.1:18010')) 'The health listener must remain loopback-only.'
Assert-True ($ProfileContent.Contains("command: '__LAZY_PROXY_COMMAND__'")) 'The public profile must invoke the lazy proxy through its command placeholder, wrapped in YAML single quotes so a quoted executable path cannot corrupt the scalar.'
Assert-True (-not $ProfileContent.Contains('serena start-mcp-server')) 'The public profile must not launch Serena directly; the lazy proxy owns that.'

Write-Host 'Checking the Node.js runtime version...'
$PreviousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $NodeVersionOutput = (& node --version 2>&1 | Out-String).Trim()
    $NodeVersionExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $PreviousErrorActionPreference
}
Assert-True ($NodeVersionExitCode -eq 0) 'node --version must succeed; Node.js must be installed and on PATH.'
$NodeVersionMatch = [regex]::Match($NodeVersionOutput, 'v(\d+)\.')
Assert-True $NodeVersionMatch.Success "Unable to parse a Node.js version from: $NodeVersionOutput"
Assert-True ([int]$NodeVersionMatch.Groups[1].Value -ge 20) "Node.js 20 or newer is required; found $NodeVersionOutput."

Write-Host 'Checking required lazy proxy files...'
$RequiredLazyFiles = @(
    'lazy-proxy\protocol.mjs',
    'lazy-proxy\manifest.mjs',
    'lazy-proxy\serena-process.mjs',
    'lazy-proxy\server.mjs',
    'lazy-proxy\status-server.mjs',
    'lazy-proxy\cli.mjs',
    'lazy-proxy\serena-tools.json',
    'lazy-proxy\scripts\capture-manifest.mjs',
    'scripts\lazy-common.ps1',
    'scripts\lazy-supervisor.ps1',
    'scripts\lazy-control.ps1',
    'Lazy-Control.cmd'
)
foreach ($RequiredFile in $RequiredLazyFiles) {
    Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot $RequiredFile)) "Required lazy proxy file is missing: $RequiredFile"
}

Write-Host 'Checking loopback health and status addresses...'
$CliContent = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'lazy-proxy\cli.mjs')
Assert-True ($CliContent.Contains("statusAddress: '127.0.0.1:18012'")) 'The lazy proxy status address must default to 127.0.0.1:18012.'
$LazyCommonContent = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'scripts\lazy-common.ps1')
Assert-True ($LazyCommonContent.Contains("StatusAddress    = '127.0.0.1:18012'")) 'The launcher must render the same loopback-only status address.'

Write-Host 'Checking the lazy control script and its operator wrapper...'
$LazyControlContent = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'scripts\lazy-control.ps1')
Assert-True (-not $LazyControlContent.Contains('Get-DpapiApiKey')) 'scripts\lazy-control.ps1 must never decrypt or handle the plaintext API key; install/start/status/stop/uninstall must not need it.'
Assert-True ($LazyControlContent.Contains('Confirm-LazyProcessMatch')) 'scripts\lazy-control.ps1 must verify process identity (executable path and command line) before any stop action.'
Assert-True ($LazyControlContent.Contains("'DWB Serena Lazy Tunnel'")) 'scripts\lazy-control.ps1 must use the exact approved Scheduled Task name.'
Assert-True ($LazyControlContent.Contains('-RunLevel')) 'scripts\lazy-control.ps1 must explicitly set the Scheduled Task principal run level (never implicitly elevated).'
Assert-True ($LazyControlContent -notmatch "RunLevel\s+'?Highest'?") 'scripts\lazy-control.ps1 must never register the logon task with an elevated (Highest) run level.'

$LazyControlCmdContent = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'Lazy-Control.cmd')
Assert-True ($LazyControlCmdContent.Contains('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\lazy-control.ps1" -Action "%~1"')) 'Lazy-Control.cmd must delegate to scripts\lazy-control.ps1 using the exact specified command line.'
Assert-True ($LazyControlCmdContent -match '(?i)usage') 'Lazy-Control.cmd must print usage text for a missing or unsupported action.'

Write-Host 'Checking for forbidden secret patterns in tracked files...'
Push-Location $RepoRoot
try {
    $TrackedFiles = @(& git ls-files)
    $ForbiddenSecretPattern = '(?i)(-----BEGIN [A-Z ]*PRIVATE KEY-----|\bsk-[A-Za-z0-9]{16,}\b|\bAKIA[0-9A-Z]{16}\b|^01000000[0-9a-f]{16,}$)'
    $FilesWithSecrets = New-Object System.Collections.Generic.List[string]
    foreach ($TrackedFile in $TrackedFiles) {
        $FullPath = Join-Path $RepoRoot $TrackedFile
        if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { continue }
        $Bytes = [System.IO.File]::ReadAllBytes($FullPath)
        if ($Bytes.Length -eq 0) { continue }
        $IsBinary = $false
        $SampleLength = [Math]::Min(8000, $Bytes.Length)
        for ($Index = 0; $Index -lt $SampleLength; $Index++) {
            if ($Bytes[$Index] -eq 0) { $IsBinary = $true; break }
        }
        if ($IsBinary) { continue }
        $FileContent = Get-Content -Raw -LiteralPath $FullPath
        if ($FileContent -match $ForbiddenSecretPattern) {
            $FilesWithSecrets.Add($TrackedFile)
        }
    }
    Assert-True ($FilesWithSecrets.Count -eq 0) "Forbidden secret-like patterns found in tracked files: $($FilesWithSecrets -join ', ')"
}
finally {
    Pop-Location
}

Write-Host 'Checking ignored local files...'
Push-Location $RepoRoot
try {
    $IgnoredPaths = @(
        '.env.local',
        'config/team.ps1',
        'config/api-key.dpapi',
        'tunnel-client/tunnel-client.exe',
        'example.pem',
        'example.pfx'
    )
    foreach ($IgnoredPath in $IgnoredPaths) {
        & git check-ignore --quiet -- $IgnoredPath
        Assert-True ($LASTEXITCODE -eq 0) "$IgnoredPath must be ignored by Git."
    }

    $ForbiddenTrackedPattern = '(^|/)(tunnel-client|config/team\.ps1|config/api-key\.dpapi)(/|$)|\.(exe|dll|zip|7z|pfx|p12|pem|key|secret)$'
    $ForbiddenTrackedFiles = @(& git ls-files | Where-Object { $_ -match $ForbiddenTrackedPattern })
    Assert-True ($ForbiddenTrackedFiles.Count -eq 0) "Forbidden generated or sensitive files are tracked: $($ForbiddenTrackedFiles -join ', ')"
}
finally {
    Pop-Location
}

Write-Host 'All public-readiness checks passed.' -ForegroundColor Green
