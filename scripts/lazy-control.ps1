param(
    [string]$Action
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lazy-common.ps1')

$Script:LazyControlTaskName = 'DWB Serena Lazy Tunnel'

function Get-LazyControlPaths {
    param(
        [string]$AppDataRoot = $env:APPDATA
    )
    $Base = Join-Path $AppDataRoot 'tunnel-client'
    return [pscustomobject]@{
        BaseDirectory   = $Base
        TunnelPidPath   = Join-Path $Base 'dwb-serena-tunnel.pid'
        ProxyPidPath    = Join-Path $Base 'dwb-serena-proxy.pid'
        BackupDirectory = Join-Path $Base 'backups'
    }
}

function Read-LazyPidFile {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $Raw = Get-Content -Raw -LiteralPath $Path -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $Trimmed = $Raw.Trim()
    $ParsedId = 0
    if (-not [int]::TryParse($Trimmed, [ref]$ParsedId)) { return $null }
    return $ParsedId
}

function Get-LazyProcessInfo {
    # Real (non-test) process inspector: resolves the executable path and full command line for a
    # PID via WMI. Never invoked directly by the offline test suite - tests always inject their own
    # -ProcessInspector fake, so this function is exercised only during a real (live) install/start/
    # status/stop/uninstall run, none of which this offline dispatch performs.
    param([Parameter(Mandatory)] [int]$ProcessId)
    $Wmi = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if (-not $Wmi) { return $null }
    return [pscustomobject]@{
        Id             = $Wmi.ProcessId
        ParentId       = $Wmi.ParentProcessId
        ExecutablePath = $Wmi.ExecutablePath
        CommandLine    = $Wmi.CommandLine
    }
}

function Confirm-LazyProcessMatch {
    # The single safety gate every stop/uninstall code path must pass through before signaling or
    # sending a stop request to a PID: a PID file alone (missing, stale, or reused by an unrelated
    # process) must never be trusted. The candidate's live executable path and command line are
    # re-read (via the injected inspector) and compared against what THIS script actually launched.
    param(
        $ProcessInfo,
        [string]$ExpectedExecutablePath,
        [string]$ExpectedExecutablePattern,
        [string[]]$RequiredCommandLineSubstrings = @()
    )
    if (-not $ProcessInfo) { return $false }
    if ([string]::IsNullOrWhiteSpace($ProcessInfo.ExecutablePath) -or [string]::IsNullOrWhiteSpace($ProcessInfo.CommandLine)) { return $false }

    if ($ExpectedExecutablePath) {
        if ($ProcessInfo.ExecutablePath -ine $ExpectedExecutablePath) { return $false }
    }
    elseif ($ExpectedExecutablePattern) {
        if ($ProcessInfo.ExecutablePath -notlike $ExpectedExecutablePattern) { return $false }
    }
    else {
        throw 'Confirm-LazyProcessMatch requires either -ExpectedExecutablePath or -ExpectedExecutablePattern.'
    }

    foreach ($Substring in $RequiredCommandLineSubstrings) {
        if (-not $ProcessInfo.CommandLine.Contains($Substring)) { return $false }
    }
    return $true
}

function Install-LazyControlStack {
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [string]$TaskName = $Script:LazyControlTaskName,
        [pscustomobject]$Paths,
        [scriptblock]$ConfigProvider = { param($RepoRootArg) Get-LazyRuntimeConfig -RepoRoot $RepoRootArg },
        [scriptblock]$TaskRegistrar = {
            param($TaskNameArg, $Execute, $Argument, $WorkingDirectory, $UserId, $RunLevel)
            $TaskAction = New-ScheduledTaskAction -Execute $Execute -Argument $Argument -WorkingDirectory $WorkingDirectory
            $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserId
            $Principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel $RunLevel
            Register-ScheduledTask -TaskName $TaskNameArg -Action $TaskAction -Trigger $Trigger -Principal $Principal -Force | Out-Null
        },
        [scriptblock]$NowProvider = { [DateTime]::UtcNow }
    )
    if (-not $Paths) { $Paths = Get-LazyControlPaths }
    New-Item -ItemType Directory -Force -Path $Paths.BaseDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $Paths.BackupDirectory | Out-Null

    $Config = & $ConfigProvider $RepoRoot

    $BackupPath = $null
    if (Test-Path -LiteralPath $Config.ProfileDestinationPath) {
        $Timestamp = (& $NowProvider).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
        $BackupPath = Join-Path $Paths.BackupDirectory "dwb-serena.$Timestamp.yaml"
        Copy-Item -LiteralPath $Config.ProfileDestinationPath -Destination $BackupPath -Force
    }

    Write-LazyTunnelProfile -TemplatePath $Config.ProfileTemplatePath -DestinationPath $Config.ProfileDestinationPath -TunnelId $Config.TunnelId -ProxyCommand $Config.ProxyCommand | Out-Null

    $SupervisorPath = Join-Path $RepoRoot 'scripts\lazy-supervisor.ps1'
    $PowerShellPath = (Get-Command powershell.exe).Source
    $Argument = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SupervisorPath`""
    $UserId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    & $TaskRegistrar $TaskName $PowerShellPath $Argument $RepoRoot $UserId 'Limited'

    return [pscustomobject]@{
        TaskName       = $TaskName
        BackupPath     = $BackupPath
        ProfilePath    = $Config.ProfileDestinationPath
        SupervisorPath = $SupervisorPath
    }
}

function Start-LazyControlStack {
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [pscustomobject]$Paths,
        [scriptblock]$ConfigProvider = { param($RepoRootArg) Get-LazyRuntimeConfig -RepoRoot $RepoRootArg },
        [scriptblock]$ProcessLauncher = {
            param($FilePath, $ArgumentList, $WorkingDirectory)
            Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru
        },
        [scriptblock]$ProcessEnumerator = {
            Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{ Id = $_.ProcessId; ParentId = $_.ParentProcessId; ExecutablePath = $_.ExecutablePath; CommandLine = $_.CommandLine }
            }
        },
        [int]$DiscoveryTimeoutMs,
        [int]$DiscoveryPollMs = 250,
        [scriptblock]$Sleeper = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds },
        [scriptblock]$NowProvider = { Get-Date }
    )
    if (-not $Paths) { $Paths = Get-LazyControlPaths }
    New-Item -ItemType Directory -Force -Path $Paths.BaseDirectory | Out-Null

    $Config = & $ConfigProvider $RepoRoot
    if (-not $DiscoveryTimeoutMs) { $DiscoveryTimeoutMs = $Config.StartupTimeoutMs }

    $SupervisorPath = Join-Path $RepoRoot 'scripts\lazy-supervisor.ps1'
    $PowerShellPath = (Get-Command powershell.exe).Source
    $ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $SupervisorPath)

    $Process = & $ProcessLauncher $PowerShellPath $ArgumentList $RepoRoot
    if (-not $Process -or -not $Process.Id) {
        throw 'Failed to launch the lazy tunnel supervisor process.'
    }
    Set-Content -LiteralPath $Paths.TunnelPidPath -Value ([string]$Process.Id) -Encoding ascii -NoNewline

    $ProxyProcessId = $null
    $Deadline = (& $NowProvider).AddMilliseconds($DiscoveryTimeoutMs)
    while ((& $NowProvider) -lt $Deadline) {
        $Candidates = & $ProcessEnumerator
        $Match = $Candidates | Where-Object {
            $_.ExecutablePath -and $_.CommandLine -and
            ($_.ExecutablePath -ieq $Config.NodePath) -and
            ($_.CommandLine.Contains('cli.mjs')) -and
            ($_.CommandLine.Contains($Config.ManifestPath))
        } | Select-Object -First 1
        if ($Match) { $ProxyProcessId = $Match.Id; break }
        & $Sleeper $DiscoveryPollMs
    }

    if ($ProxyProcessId) {
        Set-Content -LiteralPath $Paths.ProxyPidPath -Value ([string]$ProxyProcessId) -Encoding ascii -NoNewline
    }

    return [pscustomobject]@{
        TunnelPid = $Process.Id
        ProxyPid  = $ProxyProcessId
    }
}

function Get-LazyControlStatus {
    # Deliberately never decrypts the DPAPI-protected secret (see lazy-common.ps1's key helper) or
    # reads Config.DpapiSecretPath: status reporting must never require or expose the plaintext key.
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [pscustomobject]$Paths,
        [scriptblock]$ConfigProvider = { param($RepoRootArg) Get-LazyRuntimeConfig -RepoRoot $RepoRootArg },
        [scriptblock]$ProcessInspector = { param($ProcessId) Get-LazyProcessInfo -ProcessId $ProcessId },
        [scriptblock]$StatusHttpGetter = { param($Url) Invoke-RestMethod -Uri $Url -TimeoutSec 3 }
    )
    if (-not $Paths) { $Paths = Get-LazyControlPaths }
    $Config = & $ConfigProvider $RepoRoot

    $TunnelPid = Read-LazyPidFile -Path $Paths.TunnelPidPath
    $TunnelVerified = $false
    if ($TunnelPid) {
        $TunnelInfo = & $ProcessInspector $TunnelPid
        $TunnelVerified = Confirm-LazyProcessMatch -ProcessInfo $TunnelInfo -ExpectedExecutablePattern '*powershell*' -RequiredCommandLineSubstrings @('lazy-supervisor.ps1')
    }

    $ProxyPid = Read-LazyPidFile -Path $Paths.ProxyPidPath
    $ProxyVerified = $false
    if ($ProxyPid) {
        $ProxyInfo = & $ProcessInspector $ProxyPid
        $ProxyVerified = Confirm-LazyProcessMatch -ProcessInfo $ProxyInfo -ExpectedExecutablePath $Config.NodePath -RequiredCommandLineSubstrings @('cli.mjs', $Config.ManifestPath)
    }

    $StatusUrl = "http://$($Config.StatusAddress)/status"
    $ProxyStatus = $null
    $StatusError = $null
    try {
        $ProxyStatus = & $StatusHttpGetter $StatusUrl
    }
    catch {
        $StatusError = $_.Exception.Message
    }

    return [pscustomobject]@{
        TunnelPid          = $TunnelPid
        TunnelVerified      = $TunnelVerified
        ProxyPid            = $ProxyPid
        ProxyVerified        = $ProxyVerified
        StatusUrl           = $StatusUrl
        HealthUrl           = 'http://127.0.0.1:18010/ui'
        SerenaState         = if ($ProxyStatus) { $ProxyStatus.serena } else { $null }
        SerenaPid           = if ($ProxyStatus) { $ProxyStatus.pid } else { $null }
        IdleDeadline        = if ($ProxyStatus) { $ProxyStatus.idleDeadline } else { $null }
        ManifestVersion     = if ($ProxyStatus) { $ProxyStatus.manifestVersion } else { $null }
        ManifestCompatible  = if ($ProxyStatus) { $ProxyStatus.manifestCompatible } else { $null }
        LastError           = if ($ProxyStatus -and $ProxyStatus.lastError) { $ProxyStatus.lastError } elseif ($StatusError) { $StatusError } else { $null }
    }
}

function Format-LazyControlStatus {
    param([Parameter(Mandatory)] $Status)
    $Lines = @(
        'DWB Serena Lazy Tunnel - status'
        "Tunnel process : $(if ($Status.TunnelVerified) { "PID $($Status.TunnelPid) (verified)" } elseif ($Status.TunnelPid) { "PID $($Status.TunnelPid) (NOT verified - ignored)" } else { 'not running' })"
        "Proxy process  : $(if ($Status.ProxyVerified) { "PID $($Status.ProxyPid) (verified)" } elseif ($Status.ProxyPid) { "PID $($Status.ProxyPid) (NOT verified - ignored)" } else { 'not running' })"
        "Tunnel health  : $($Status.HealthUrl)"
        "Proxy status   : $($Status.StatusUrl)"
        "Serena state   : $(if ($null -ne $Status.SerenaState) { $Status.SerenaState } else { 'unknown' })"
        "Serena PID     : $(if ($Status.SerenaPid) { $Status.SerenaPid } else { 'none' })"
        "Idle deadline  : $(if ($Status.IdleDeadline) { $Status.IdleDeadline } else { 'n/a' })"
        "Manifest       : version $($Status.ManifestVersion), compatible=$($Status.ManifestCompatible)"
    )
    if ($Status.LastError) { $Lines += "Last error     : $($Status.LastError)" }
    return ($Lines -join [Environment]::NewLine)
}

function Stop-LazyControlStack {
    # Safety-critical: every stop attempt on every PID (tunnel and proxy) is independently
    # verified - twice - against the exact executable path and command line this script itself
    # would have launched, before any stop signal (graceful or forced) is ever sent. A PID file
    # that is missing, unparsable, points at a process that no longer exists, or points at a
    # process whose identity does not match is left completely untouched.
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [pscustomobject]$Paths,
        [scriptblock]$ConfigProvider = { param($RepoRootArg) Get-LazyRuntimeConfig -RepoRoot $RepoRootArg },
        [scriptblock]$ProcessInspector = { param($ProcessId) Get-LazyProcessInfo -ProcessId $ProcessId },
        [scriptblock]$GracefulStopper = { param($ProcessId) Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', $ProcessId) -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null },
        [scriptblock]$ForceStopper = { param($ProcessId) Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', $ProcessId, '/T', '/F') -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null },
        [int]$GracefulTimeoutMs = 5000,
        [int]$PollIntervalMs = 250,
        [scriptblock]$Sleeper = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds },
        [scriptblock]$NowProvider = { Get-Date }
    )
    if (-not $Paths) { $Paths = Get-LazyControlPaths }
    $Config = & $ConfigProvider $RepoRoot

    $Result = [pscustomobject]@{
        TunnelStopped = $false
        ProxyStopped  = $false
        SkippedStale  = New-Object System.Collections.Generic.List[string]
    }

    $Targets = @(
        [pscustomobject]@{ Name = 'Tunnel'; PidPath = $Paths.TunnelPidPath; ExecutablePath = $null; ExecutablePattern = '*powershell*'; Substrings = @('lazy-supervisor.ps1') }
        [pscustomobject]@{ Name = 'Proxy';  PidPath = $Paths.ProxyPidPath;  ExecutablePath = $Config.NodePath; ExecutablePattern = $null; Substrings = @('cli.mjs', $Config.ManifestPath) }
    )

    foreach ($Target in $Targets) {
        $ProcessId = Read-LazyPidFile -Path $Target.PidPath
        if (-not $ProcessId) {
            $Result.SkippedStale.Add("$($Target.Name): no valid PID file found; nothing to stop.")
            continue
        }

        $Info = & $ProcessInspector $ProcessId
        $Verified = Confirm-LazyProcessMatch -ProcessInfo $Info -ExpectedExecutablePath $Target.ExecutablePath -ExpectedExecutablePattern $Target.ExecutablePattern -RequiredCommandLineSubstrings $Target.Substrings
        if (-not $Verified) {
            $Result.SkippedStale.Add("$($Target.Name): PID $ProcessId did not match the expected managed process; left untouched.")
            continue
        }

        & $GracefulStopper $ProcessId

        $Stopped = $false
        $Deadline = (& $NowProvider).AddMilliseconds($GracefulTimeoutMs)
        while ((& $NowProvider) -lt $Deadline) {
            $Recheck = & $ProcessInspector $ProcessId
            $StillOurs = Confirm-LazyProcessMatch -ProcessInfo $Recheck -ExpectedExecutablePath $Target.ExecutablePath -ExpectedExecutablePattern $Target.ExecutablePattern -RequiredCommandLineSubstrings $Target.Substrings
            if (-not $StillOurs) { $Stopped = $true; break }
            & $Sleeper $PollIntervalMs
        }

        if (-not $Stopped) {
            # Re-verify immediately before force-killing: never force-kill on a stale/reused PID,
            # even if it matched moments earlier during the polling loop.
            $FinalCheck = & $ProcessInspector $ProcessId
            $StillOursAtForceTime = Confirm-LazyProcessMatch -ProcessInfo $FinalCheck -ExpectedExecutablePath $Target.ExecutablePath -ExpectedExecutablePattern $Target.ExecutablePattern -RequiredCommandLineSubstrings $Target.Substrings
            if ($StillOursAtForceTime) {
                & $ForceStopper $ProcessId
                $Stopped = $true
            }
        }

        if ($Target.Name -eq 'Tunnel') { $Result.TunnelStopped = $Stopped }
        if ($Target.Name -eq 'Proxy') { $Result.ProxyStopped = $Stopped }

        if ($Stopped) {
            Remove-Item -LiteralPath $Target.PidPath -Force -ErrorAction SilentlyContinue
        }
        else {
            $Result.SkippedStale.Add("$($Target.Name): PID $ProcessId could not be confirmed stopped; PID file left in place.")
        }
    }

    return $Result
}

function Uninstall-LazyControlStack {
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [string]$TaskName = $Script:LazyControlTaskName,
        [pscustomobject]$Paths,
        [scriptblock]$ConfigProvider = { param($RepoRootArg) Get-LazyRuntimeConfig -RepoRoot $RepoRootArg },
        [scriptblock]$TaskExistenceChecker = { param($TaskNameArg) [bool](Get-ScheduledTask -TaskName $TaskNameArg -ErrorAction SilentlyContinue) },
        [scriptblock]$TaskRemover = { param($TaskNameArg) Unregister-ScheduledTask -TaskName $TaskNameArg -Confirm:$false },
        [scriptblock]$ProcessInspector = { param($ProcessId) Get-LazyProcessInfo -ProcessId $ProcessId },
        [scriptblock]$GracefulStopper = { param($ProcessId) Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', $ProcessId) -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null },
        [scriptblock]$ForceStopper = { param($ProcessId) Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', $ProcessId, '/T', '/F') -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null },
        [int]$GracefulTimeoutMs = 5000,
        [int]$PollIntervalMs = 250,
        [scriptblock]$Sleeper = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds },
        [scriptblock]$NowProvider = { Get-Date }
    )
    if (-not $Paths) { $Paths = Get-LazyControlPaths }
    $Config = & $ConfigProvider $RepoRoot

    $TaskExisted = [bool](& $TaskExistenceChecker $TaskName)
    if ($TaskExisted) {
        & $TaskRemover $TaskName
    }

    $StopResult = Stop-LazyControlStack -RepoRoot $RepoRoot -Paths $Paths -ConfigProvider $ConfigProvider `
        -ProcessInspector $ProcessInspector -GracefulStopper $GracefulStopper -ForceStopper $ForceStopper `
        -GracefulTimeoutMs $GracefulTimeoutMs -PollIntervalMs $PollIntervalMs -Sleeper $Sleeper -NowProvider $NowProvider

    $RestoredFrom = $null
    if (Test-Path -LiteralPath $Paths.BackupDirectory) {
        $Candidates = Get-ChildItem -LiteralPath $Paths.BackupDirectory -Filter 'dwb-serena.*.yaml' -File -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
        foreach ($Candidate in $Candidates) {
            $Content = Get-Content -Raw -LiteralPath $Candidate.FullName -ErrorAction SilentlyContinue
            if ([string]::IsNullOrWhiteSpace($Content)) { continue }
            if (-not $Content.Contains('tunnel_id:')) { continue }
            Copy-Item -LiteralPath $Candidate.FullName -Destination $Config.ProfileDestinationPath -Force
            $RestoredFrom = $Candidate.FullName
            break
        }
    }

    return [pscustomobject]@{
        TaskName      = $TaskName
        TaskRemoved   = $TaskExisted
        StopResult    = $StopResult
        RestoredFrom  = $RestoredFrom
    }
}

if ($Action) {
    switch ($Action.ToLowerInvariant()) {
        'install' {
            $Result = Install-LazyControlStack -RepoRoot $RepoRoot
            Write-Host "Installed Scheduled Task '$($Result.TaskName)'." -ForegroundColor Green
            if ($Result.BackupPath) { Write-Host "Backed up existing profile to: $($Result.BackupPath)" }
            Write-Host "Rendered profile: $($Result.ProfilePath)"
        }
        'start' {
            $Result = Start-LazyControlStack -RepoRoot $RepoRoot
            Write-Host "Started lazy tunnel supervisor (PID $($Result.TunnelPid))." -ForegroundColor Green
            if ($Result.ProxyPid) {
                Write-Host "Detected lazy proxy process (PID $($Result.ProxyPid))."
            }
            else {
                Write-Host 'Lazy proxy process was not detected within the startup timeout.' -ForegroundColor Yellow
            }
        }
        'status' {
            $Status = Get-LazyControlStatus -RepoRoot $RepoRoot
            Write-Host (Format-LazyControlStatus -Status $Status)
        }
        'stop' {
            $Result = Stop-LazyControlStack -RepoRoot $RepoRoot
            Write-Host "Tunnel stopped: $($Result.TunnelStopped); Proxy stopped: $($Result.ProxyStopped)" -ForegroundColor Green
            foreach ($Skip in $Result.SkippedStale) { Write-Host "Note: $Skip" -ForegroundColor Yellow }
        }
        'uninstall' {
            $Result = Uninstall-LazyControlStack -RepoRoot $RepoRoot
            Write-Host "Scheduled Task removed: $($Result.TaskRemoved)" -ForegroundColor Green
            if ($Result.RestoredFrom) { Write-Host "Restored profile from: $($Result.RestoredFrom)" }
            else { Write-Host 'No backup was available to restore.' -ForegroundColor Yellow }
        }
        default {
            Write-Host "Unknown action: $Action" -ForegroundColor Red
            Write-Host 'Supported actions: install, start, status, stop, uninstall'
            exit 1
        }
    }
}
