$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

Write-Host 'Checking PowerShell syntax...'
$ScriptFiles = @('setup.ps1', 'configure.ps1', 'start.ps1')
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
