$ErrorActionPreference = 'Stop'

$Script:LazyProductionDefaults = @{
    IdleTimeoutMs    = 900000
    StartupTimeoutMs = 30000
    StatusAddress    = '127.0.0.1:18012'
}

function ConvertTo-LazyQuotedArgument {
    param([Parameter(Mandatory)] [string]$Value)
    if ($Value -match "[`r`n]") {
        throw "Argument cannot be safely represented because it contains a newline: $Value"
    }
    if ($Value -match '"') {
        throw "Argument cannot be safely represented because it contains a double quote: $Value"
    }
    if ($Value -match '\s') {
        return '"' + $Value + '"'
    }
    return $Value
}

function Get-LazyRuntimeConfig {
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [string]$TunnelIdOverride,
        [string]$OrganizationIdOverride
    )

    $NodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $NodeCommand) { $NodeCommand = Get-Command node -ErrorAction SilentlyContinue }
    if (-not $NodeCommand) { throw 'node.exe was not found on PATH.' }

    $SerenaCommand = Get-Command serena.exe -ErrorAction SilentlyContinue
    if (-not $SerenaCommand) { $SerenaCommand = Get-Command serena -ErrorAction SilentlyContinue }
    if (-not $SerenaCommand) { throw 'serena was not found on PATH.' }

    $ProxyCliPath = Join-Path $RepoRoot 'lazy-proxy\cli.mjs'
    if (-not (Test-Path -LiteralPath $ProxyCliPath)) { throw "Lazy proxy CLI not found: $ProxyCliPath" }

    $ManifestPath = Join-Path $RepoRoot 'lazy-proxy\serena-tools.json'
    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "Serena tool manifest not found: $ManifestPath" }

    $TunnelId = $TunnelIdOverride
    $OrganizationId = $OrganizationIdOverride
    if ([string]::IsNullOrWhiteSpace($TunnelId) -or [string]::IsNullOrWhiteSpace($OrganizationId)) {
        $LocalConfigPath = Join-Path $RepoRoot 'config\team.ps1'
        if (-not (Test-Path -LiteralPath $LocalConfigPath)) { throw "Tunnel configuration not found: $LocalConfigPath" }
        . $LocalConfigPath
    }
    if ([string]::IsNullOrWhiteSpace($TunnelId) -or $TunnelId -cnotmatch '^tunnel_[0-9a-f]{32}$') {
        throw 'Tunnel ID is missing or invalid.'
    }
    if ([string]::IsNullOrWhiteSpace($OrganizationId) -or $OrganizationId -cnotmatch '^org-[A-Za-z0-9]{20,}$') {
        throw 'Organization ID is missing or invalid.'
    }

    $ProxyCommandParts = @(
        (ConvertTo-LazyQuotedArgument $NodeCommand.Source.Replace('\', '/')),
        (ConvertTo-LazyQuotedArgument $ProxyCliPath.Replace('\', '/')),
        '--manifest', (ConvertTo-LazyQuotedArgument $ManifestPath.Replace('\', '/')),
        '--command', (ConvertTo-LazyQuotedArgument $SerenaCommand.Source.Replace('\', '/')),
        '--status', $Script:LazyProductionDefaults.StatusAddress
    )

    return [pscustomobject]@{
        RepoRoot               = $RepoRoot
        NodePath                = $NodeCommand.Source
        SerenaPath              = $SerenaCommand.Source
        ProxyCliPath            = $ProxyCliPath
        ManifestPath            = $ManifestPath
        TunnelClientPath        = Join-Path $RepoRoot 'tunnel-client\tunnel-client.exe'
        DpapiSecretPath         = Join-Path $RepoRoot 'config\api-key.dpapi'
        ProfileTemplatePath     = Join-Path $RepoRoot 'profiles\serena-team.yaml'
        ProfileDestinationPath  = Join-Path $env:APPDATA 'tunnel-client\dwb-serena.yaml'
        TunnelId                = $TunnelId
        OrganizationId          = $OrganizationId
        IdleTimeoutMs           = $Script:LazyProductionDefaults.IdleTimeoutMs
        StartupTimeoutMs        = $Script:LazyProductionDefaults.StartupTimeoutMs
        StatusAddress           = $Script:LazyProductionDefaults.StatusAddress
        ProxyCommand            = ($ProxyCommandParts -join ' ')
    }
}

function Write-LazyTunnelProfile {
    param(
        [Parameter(Mandatory)] [string]$TemplatePath,
        [Parameter(Mandatory)] [string]$DestinationPath,
        [Parameter(Mandatory)] [string]$TunnelId,
        [Parameter(Mandatory)] [string]$ProxyCommand
    )
    if (-not (Test-Path -LiteralPath $TemplatePath)) { throw "Tunnel profile template not found: $TemplatePath" }
    if ($TunnelId -cnotmatch '^tunnel_[0-9a-f]{32}$') { throw 'Tunnel ID is missing or invalid.' }
    if ($ProxyCommand -match "[`r`n]") { throw 'ProxyCommand cannot contain newline characters.' }

    # The template embeds __LAZY_PROXY_COMMAND__ inside a YAML single-quoted scalar
    # (command: '__LAZY_PROXY_COMMAND__'), so a literal single quote in the value must be
    # doubled per YAML single-quoted-scalar escaping. A value beginning with an unescaped
    # double quote (e.g. a quoted "C:\Program Files\..." path, which is always the first
    # token) is not valid YAML as a *plain* scalar and silently truncates/corrupts the line;
    # wrapping in single quotes and doubling embedded single quotes keeps the substituted
    # string byte-for-byte intact when the profile is parsed.
    $EscapedProxyCommand = $ProxyCommand.Replace("'", "''")
    if (($EscapedProxyCommand.Replace("''", "'")) -ne $ProxyCommand) {
        throw 'Rendered proxy command failed a round-trip safety check; refusing to write a corrupted profile.'
    }

    $Content = Get-Content -Raw -LiteralPath $TemplatePath
    $Content = $Content.Replace('__TUNNEL_ID__', $TunnelId)
    $Content = $Content.Replace('__LAZY_PROXY_COMMAND__', $EscapedProxyCommand)

    $DestinationDirectory = Split-Path -Parent $DestinationPath
    New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null

    $TemporaryPath = "$DestinationPath.tmp"
    $Written = $false
    try {
        Set-Content -LiteralPath $TemporaryPath -Value $Content -Encoding utf8 -NoNewline
        $Written = $true
        Move-Item -LiteralPath $TemporaryPath -Destination $DestinationPath -Force
        $Written = $false
    }
    finally {
        if ($Written) { Remove-Item -LiteralPath $TemporaryPath -Force -ErrorAction SilentlyContinue }
    }

    return $Content
}

function Get-LazyRuntimeStatePaths {
    param([string]$AppDataRoot = $env:APPDATA)
    $Base = Join-Path $AppDataRoot 'tunnel-client'
    return [pscustomobject]@{
        BaseDirectory       = $Base
        TunnelPidPath       = Join-Path $Base 'dwb-serena-tunnel.pid'
        TunnelClientPidPath = Join-Path $Base 'dwb-serena-tunnel-client.pid'
        ProxyPidPath        = Join-Path $Base 'dwb-serena-proxy.pid'
        SupervisorLogPath   = Join-Path $Base 'dwb-serena-supervisor.log'
        BackupDirectory     = Join-Path $Base 'backups'
    }
}

function Set-LazyPidFile {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [int]$ProcessId
    )
    $Directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    Set-Content -LiteralPath $Path -Value ([string]$ProcessId) -Encoding ascii -NoNewline
}

function Remove-LazyPidFileIfOwned {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [int]$ProcessId
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $Raw = Get-Content -Raw -LiteralPath $Path -ErrorAction SilentlyContinue
    $ParsedId = 0
    if ($Raw -and [int]::TryParse($Raw.Trim(), [ref]$ParsedId) -and $ParsedId -eq $ProcessId) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Write-LazySupervisorEvent {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Message,
        [scriptblock]$NowProvider = { Get-Date }
    )
    $Directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null

    # Keep a single bounded previous log so a long-running supervisor cannot grow APPDATA without limit.
    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -ge 1048576) {
        Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
    }

    $Timestamp = (& $NowProvider).ToUniversalTime().ToString('o')
    Add-Content -LiteralPath $Path -Encoding utf8 -Value "$Timestamp $Message"
}

function Get-DpapiApiKey {
    param([Parameter(Mandatory)] [string]$SecretPath)
    if (-not (Test-Path -LiteralPath $SecretPath)) { throw "DPAPI secret file not found: $SecretPath" }
    try {
        $EncryptedKey = (Get-Content -Raw -LiteralPath $SecretPath).Trim()
        $PreviousPSModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = Join-Path $PSHOME 'Modules'
            $SecurityModuleManifest = Join-Path $env:PSModulePath 'Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1'
            Import-Module -Name $SecurityModuleManifest -Force -ErrorAction Stop
            $SecureKey = ConvertTo-SecureString $EncryptedKey
        }
        finally {
            $env:PSModulePath = $PreviousPSModulePath
        }
        $PlaintextKey = [System.Net.NetworkCredential]::new('', $SecureKey).Password
    }
    catch {
        throw 'Could not decrypt the API key with Windows DPAPI. Run Configure.cmd again under the same Windows user.'
    }
    if ([string]::IsNullOrWhiteSpace($PlaintextKey)) { throw 'Decrypted API key is empty.' }
    return $PlaintextKey
}

function Start-LazyTunnel {
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [int]$MaxRestarts = 3,
        [int]$RestartWindowMinutes = 10,
        [int]$InitialRestartDelaySeconds = 5,
        [int]$MaxRestartDelaySeconds = 60,
        [switch]$Once,
        [scriptblock]$ConfigProvider = { param($RepoRootArg) Get-LazyRuntimeConfig -RepoRoot $RepoRootArg },
        [scriptblock]$ProcessLauncher = {
            param($FilePath, $ArgumentList, $WorkingDirectory)
            $StartArguments = @{ FilePath = $FilePath; ArgumentList = $ArgumentList; WindowStyle = 'Hidden'; PassThru = $true }
            if ($WorkingDirectory) { $StartArguments['WorkingDirectory'] = $WorkingDirectory }
            Start-Process @StartArguments
        },
        [scriptblock]$ProcessStarted = { param($Process, $ConfigArg) },
        [scriptblock]$ProcessExited = { param($Process, $ExitCodeArg, $ConfigArg) },
        [scriptblock]$Sleeper = { param($Seconds) Start-Sleep -Seconds $Seconds },
        [scriptblock]$EventLogger = { param($Message) },
        [scriptblock]$NowProvider = { Get-Date }
    )

    if ($InitialRestartDelaySeconds -lt 0) { throw 'InitialRestartDelaySeconds cannot be negative.' }
    if ($MaxRestartDelaySeconds -lt $InitialRestartDelaySeconds) { throw 'MaxRestartDelaySeconds cannot be smaller than InitialRestartDelaySeconds.' }

    $Config = & $ConfigProvider $RepoRoot
    $ApiKey = Get-DpapiApiKey -SecretPath $Config.DpapiSecretPath
    try {
        Write-LazyTunnelProfile -TemplatePath $Config.ProfileTemplatePath -DestinationPath $Config.ProfileDestinationPath -TunnelId $Config.TunnelId -ProxyCommand $Config.ProxyCommand | Out-Null

        $StartTimestamps = New-Object System.Collections.Generic.List[datetime]
        $ExitCode = 0
        do {
            $Now = & $NowProvider
            $WindowStart = $Now.AddMinutes(-$RestartWindowMinutes)
            $Recent = New-Object System.Collections.Generic.List[datetime]
            foreach ($Timestamp in $StartTimestamps) {
                if ($Timestamp -gt $WindowStart) { $Recent.Add($Timestamp) }
            }
            $StartTimestamps = $Recent
            if ($StartTimestamps.Count -ge $MaxRestarts) {
                try { & $EventLogger "restart-budget-exceeded count=$($StartTimestamps.Count) windowMinutes=$RestartWindowMinutes" } catch { }
                throw "Lazy tunnel exceeded $MaxRestarts restarts within $RestartWindowMinutes minutes; stopping supervision."
            }
            $StartTimestamps.Add($Now)

            $env:CONTROL_PLANE_API_KEY = $ApiKey
            $env:CONTROL_PLANE_ORGANIZATION_ID = $Config.OrganizationId
            try {
                $WorkingDirectory = Split-Path -Parent $Config.TunnelClientPath
                $Process = & $ProcessLauncher $Config.TunnelClientPath @('run', '--profile', 'dwb-serena') $WorkingDirectory
                if ($Process) {
                    try { & $EventLogger "tunnel-client-started pid=$($Process.Id)" } catch { }
                    try { & $ProcessStarted $Process $Config } catch {
                        try { & $EventLogger "process-started-callback-failed message=$($_.Exception.Message)" } catch { }
                    }
                    $Process.WaitForExit()
                    $ExitCode = $Process.ExitCode
                    try { & $EventLogger "tunnel-client-exited pid=$($Process.Id) code=$ExitCode" } catch { }
                    try { & $ProcessExited $Process $ExitCode $Config } catch {
                        try { & $EventLogger "process-exited-callback-failed message=$($_.Exception.Message)" } catch { }
                    }
                }
                else {
                    $ExitCode = -1
                    try { & $EventLogger 'tunnel-client-launch-returned-no-process' } catch { }
                }
            }
            catch {
                # A native child's own stderr output, or a launch failure, must never surface as a
                # terminating PowerShell error under $ErrorActionPreference = 'Stop'.
                $ExitCode = -1
                Write-Warning "Lazy tunnel process failed: $($_.Exception.Message)"
                try { & $EventLogger "tunnel-client-failed message=$($_.Exception.Message)" } catch { }
            }
            finally {
                $env:CONTROL_PLANE_API_KEY = $null
                $env:CONTROL_PLANE_ORGANIZATION_ID = $null
            }

            if (-not $Once -and $StartTimestamps.Count -lt $MaxRestarts -and $InitialRestartDelaySeconds -gt 0) {
                $Exponent = [Math]::Max(0, $StartTimestamps.Count - 1)
                $DelaySeconds = [Math]::Min($MaxRestartDelaySeconds, [int]($InitialRestartDelaySeconds * [Math]::Pow(2, $Exponent)))
                try { & $EventLogger "restart-backoff seconds=$DelaySeconds" } catch { }
                & $Sleeper $DelaySeconds
            }
        } while (-not $Once)

        return $ExitCode
    }
    finally {
        $ApiKey = $null
        $env:CONTROL_PLANE_API_KEY = $null
        $env:CONTROL_PLANE_ORGANIZATION_ID = $null
    }
}
