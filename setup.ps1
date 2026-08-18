$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
$InstallDir = Join-Path $Root 'tunnel-client'
$RepoApi = 'https://api.github.com/repos/openai/tunnel-client/releases/latest'

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ' DWB Serena Tunnel - Setup' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''

# GitHub requires modern TLS on older Windows PowerShell builds.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Serena = Get-Command serena -ErrorAction SilentlyContinue
if (-not $Serena) {
    Write-Host 'Serena was not found in PATH.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Install Serena first (official method):'
    Write-Host '  uv tool install -p 3.13 serena-agent' -ForegroundColor White
    Write-Host '  serena init' -ForegroundColor White
    Write-Host ''
    throw 'Serena is required before continuing.'
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
    Write-Host 'The Serena command was found but could not start.' -ForegroundColor Yellow
    Write-Host ($SerenaVersion -join [Environment]::NewLine)
    Write-Host ''
    Write-Host 'Repair the official installation, then try Setup.cmd again:'
    Write-Host '  uv tool uninstall serena-agent' -ForegroundColor White
    Write-Host '  uv tool install -p 3.13 serena-agent' -ForegroundColor White
    Write-Host '  serena init' -ForegroundColor White
    Write-Host ''
    throw 'Serena is installed but is not functional.'
}

Write-Host "Serena : $($Serena.Source) ($($SerenaVersion -join ' '))" -ForegroundColor Green

try {
    $Arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
}
catch {
    $Arch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } else { 'x64' }
}

switch -Regex ($Arch) {
    'arm64' { $AssetSuffix = 'windows-arm64.zip$' }
    'x64|amd64' { $AssetSuffix = 'windows-amd64.zip$' }
    default { throw "Unsupported Windows architecture: $Arch" }
}

Write-Host 'Checking latest stable OpenAI tunnel-client release...'
$Headers = @{ 'User-Agent' = 'dwb-serena-tunnel-starter' }
$Release = Invoke-RestMethod -Uri $RepoApi -Headers $Headers

$Asset = $Release.assets | Where-Object { $_.name -match $AssetSuffix } | Select-Object -First 1
if (-not $Asset) {
    throw "Could not find a Windows tunnel-client asset matching $AssetSuffix in release $($Release.tag_name)."
}

$ChecksumAsset = $Release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1

$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("dwb-serena-tunnel-" + [guid]::NewGuid().ToString('N'))
$ZipPath = Join-Path $TempRoot $Asset.name
$ExtractDir = Join-Path $TempRoot 'extract'
New-Item -ItemType Directory -Force -Path $TempRoot, $ExtractDir | Out-Null

try {
    Write-Host "Downloading $($Release.tag_name): $($Asset.name)"
    Invoke-WebRequest -Uri $Asset.browser_download_url -Headers $Headers -OutFile $ZipPath

    if ($ChecksumAsset) {
        $ChecksumPath = Join-Path $TempRoot 'SHA256SUMS.txt'
        Invoke-WebRequest -Uri $ChecksumAsset.browser_download_url -Headers $Headers -OutFile $ChecksumPath
        $ExpectedLine = Get-Content $ChecksumPath | Where-Object { $_ -match [regex]::Escape($Asset.name) } | Select-Object -First 1
        if (-not $ExpectedLine) {
            throw "SHA256SUMS.txt does not contain an entry for $($Asset.name)."
        }
        if ($ExpectedLine -notmatch '^([A-Fa-f0-9]{64})\s+') {
            throw "Invalid SHA-256 entry for $($Asset.name)."
        }

        $ExpectedHash = $Matches[1].ToLowerInvariant()
        $ActualHash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($ActualHash -ne $ExpectedHash) {
            throw 'SHA256 verification failed for the downloaded tunnel-client archive.'
        }
        Write-Host 'SHA256 : verified' -ForegroundColor Green
    }
    else {
        Write-Host 'WARNING: This release does not include SHA256SUMS.txt; the archive could not be checksum-verified.' -ForegroundColor Yellow
    }

    Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir -Force

    $TunnelExe = Get-ChildItem -Path $ExtractDir -Recurse -Filter 'tunnel-client.exe' | Select-Object -First 1
    if (-not $TunnelExe) {
        throw 'Downloaded archive does not contain tunnel-client.exe.'
    }

    $SourceDir = $TunnelExe.Directory.FullName
    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item -Path (Join-Path $SourceDir '*') -Destination $InstallDir -Recurse -Force

    $VersionFile = Join-Path $InstallDir '.installed-version'
    Set-Content -Path $VersionFile -Value $Release.tag_name -Encoding ascii

    Write-Host ''
    Write-Host "Tunnel client installed: $($Release.tag_name)" -ForegroundColor Green
    Write-Host "Location: $InstallDir"
    Write-Host ''
    Write-Host 'Tunnel client is ready.' -ForegroundColor Cyan
    Write-Host ''
}
finally {
    if (Test-Path $TempRoot) {
        Remove-Item -Path $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
