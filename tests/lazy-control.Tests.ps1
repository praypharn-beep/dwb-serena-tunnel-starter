$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'scripts\lazy-control.ps1')

$FakeTunnelId = 'tunnel_0123456789abcdef0123456789abcdef'
$FakeSupervisorPath = Join-Path $RepoRoot 'scripts\lazy-supervisor.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) {
        throw "$Message (expected [$Expected], got [$Actual])"
    }
}

function New-LazyTestDirectory {
    $Directory = Join-Path ([System.IO.Path]::GetTempPath()) ("lazy-control-test-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $Directory | Out-Null
    return $Directory
}

$TestDirectories = New-Object System.Collections.Generic.List[string]
function New-TrackedLazyTestDirectory {
    $Directory = New-LazyTestDirectory
    $TestDirectories.Add($Directory)
    return $Directory
}

function New-FakeControlPaths([string]$Root) {
    $Base = Join-Path $Root 'appdata-tunnel-client'
    $Backups = Join-Path $Base 'backups'
    return [pscustomobject]@{
        BaseDirectory   = $Base
        TunnelPidPath   = Join-Path $Base 'dwb-serena-tunnel.pid'
        ProxyPidPath    = Join-Path $Base 'dwb-serena-proxy.pid'
        BackupDirectory = $Backups
    }
}

function New-FakeTemplateFile([string]$Directory) {
    $TemplatePath = Join-Path $Directory 'serena-team.yaml'
    Set-Content -LiteralPath $TemplatePath -Encoding utf8 -Value @'
config_version: 1
control_plane:
  base_url: "https://api.openai.com"
  tunnel_id: "__TUNNEL_ID__"
  api_key: "env:CONTROL_PLANE_API_KEY"
health:
  listen_addr: 127.0.0.1:18010
admin_ui:
  open_browser: false
log:
  level: info
  format: json
mcp:
  commands:
    - channel: main
      command: '__LAZY_PROXY_COMMAND__'
'@
    return $TemplatePath
}

function New-FakeRuntimeConfig([string]$Directory, [string]$DestinationPath) {
    $TemplatePath = New-FakeTemplateFile $Directory
    $ManifestPath = Join-Path $RepoRoot 'lazy-proxy\serena-tools.json'
    $NodePath = 'C:\Program Files\nodejs\node.exe'
    $ProxyCommand = "`"$NodePath`" `"$RepoRoot\lazy-proxy\cli.mjs`" --manifest `"$ManifestPath`" --command `"C:\serena\serena.exe`" --status 127.0.0.1:18012"
    return [pscustomobject]@{
        RepoRoot               = $RepoRoot
        NodePath                = $NodePath
        SerenaPath              = 'C:\serena\serena.exe'
        ProxyCliPath            = Join-Path $RepoRoot 'lazy-proxy\cli.mjs'
        ManifestPath            = $ManifestPath
        TunnelClientPath        = Join-Path $RepoRoot 'tunnel-client\tunnel-client.exe'
        DpapiSecretPath         = 'Z:\does-not-exist\api-key.dpapi'
        ProfileTemplatePath     = $TemplatePath
        ProfileDestinationPath  = $DestinationPath
        TunnelId                = $FakeTunnelId
        IdleTimeoutMs           = 900000
        StartupTimeoutMs        = 30000
        StatusAddress           = '127.0.0.1:18012'
        ProxyCommand            = $ProxyCommand
    }
}

try {
    Write-Host 'Checking Get-LazyControlPaths never resolves under a real APPDATA in tests...'
    $FakeAppData = Join-Path (New-TrackedLazyTestDirectory) 'AppData\Roaming'
    $Paths = Get-LazyControlPaths -AppDataRoot $FakeAppData
    Assert-Equal (Join-Path $FakeAppData 'tunnel-client') $Paths.BaseDirectory 'Get-LazyControlPaths must derive BaseDirectory from the supplied AppData root.'
    Assert-Equal (Join-Path $Paths.BaseDirectory 'dwb-serena-tunnel.pid') $Paths.TunnelPidPath 'Get-LazyControlPaths must name the tunnel PID file exactly.'
    Assert-Equal (Join-Path $Paths.BaseDirectory 'dwb-serena-proxy.pid') $Paths.ProxyPidPath 'Get-LazyControlPaths must name the proxy PID file exactly.'
    Assert-Equal (Join-Path $Paths.BaseDirectory 'backups') $Paths.BackupDirectory 'Get-LazyControlPaths must name the backups directory exactly.'

    Write-Host 'Checking Read-LazyPidFile handles missing, empty, corrupt and valid content...'
    $PidScratch = New-TrackedLazyTestDirectory
    $MissingPidPath = Join-Path $PidScratch 'missing.pid'
    Assert-True ($null -eq (Read-LazyPidFile -Path $MissingPidPath)) 'A missing PID file must read as null.'
    $EmptyPidPath = Join-Path $PidScratch 'empty.pid'
    Set-Content -LiteralPath $EmptyPidPath -Value '' -NoNewline
    Assert-True ($null -eq (Read-LazyPidFile -Path $EmptyPidPath)) 'An empty PID file must read as null.'
    $CorruptPidPath = Join-Path $PidScratch 'corrupt.pid'
    Set-Content -LiteralPath $CorruptPidPath -Value 'not-a-pid' -NoNewline
    Assert-True ($null -eq (Read-LazyPidFile -Path $CorruptPidPath)) 'A non-numeric PID file must read as null.'
    $ValidPidPath = Join-Path $PidScratch 'valid.pid'
    Set-Content -LiteralPath $ValidPidPath -Value '  4242  ' -NoNewline
    Assert-Equal 4242 (Read-LazyPidFile -Path $ValidPidPath) 'A valid PID file must parse to its integer value.'

    Write-Host 'Checking Confirm-LazyProcessMatch...'
    Assert-True (-not (Confirm-LazyProcessMatch -ProcessInfo $null -ExpectedExecutablePath 'C:\node.exe' -RequiredCommandLineSubstrings @('cli.mjs'))) 'A null process (not found) must never match.'
    $RealInfo = [pscustomobject]@{ Id = 111; ExecutablePath = 'C:\Program Files\nodejs\node.exe'; CommandLine = '"C:\Program Files\nodejs\node.exe" "cli.mjs" --manifest "C:\repo\serena-tools.json"' }
    Assert-True (Confirm-LazyProcessMatch -ProcessInfo $RealInfo -ExpectedExecutablePath 'C:\Program Files\nodejs\node.exe' -RequiredCommandLineSubstrings @('cli.mjs', 'serena-tools.json')) 'An exact executable path plus all required substrings must match.'
    Assert-True (-not (Confirm-LazyProcessMatch -ProcessInfo $RealInfo -ExpectedExecutablePath 'C:\Program Files\nodejs\node.exe' -RequiredCommandLineSubstrings @('cli.mjs', 'this-substring-is-not-present'))) 'A missing required substring must fail the match.'
    Assert-True (-not (Confirm-LazyProcessMatch -ProcessInfo $RealInfo -ExpectedExecutablePath 'C:\Windows\System32\notepad.exe' -RequiredCommandLineSubstrings @('cli.mjs'))) 'A mismatched executable path must fail the match, even if command-line substrings are present.'
    $UpperCaseInfo = [pscustomobject]@{ Id = 111; ExecutablePath = 'C:\PROGRAM FILES\NODEJS\NODE.EXE'; CommandLine = 'cli.mjs' }
    Assert-True (Confirm-LazyProcessMatch -ProcessInfo $UpperCaseInfo -ExpectedExecutablePath 'C:\Program Files\nodejs\node.exe' -RequiredCommandLineSubstrings @('cli.mjs')) 'Executable path comparison must be case-insensitive (Windows paths).'
    $PowerShellInfo = [pscustomobject]@{ Id = 222; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'; CommandLine = '-NoProfile -File "C:\repo\scripts\lazy-supervisor.ps1"' }
    Assert-True (Confirm-LazyProcessMatch -ProcessInfo $PowerShellInfo -ExpectedExecutablePattern '*powershell.exe' -RequiredCommandLineSubstrings @('lazy-supervisor.ps1')) 'A wildcard executable pattern must match when no exact path is supplied.'
    $MissingFieldsInfo = [pscustomobject]@{ Id = 333; ExecutablePath = $null; CommandLine = $null }
    Assert-True (-not (Confirm-LazyProcessMatch -ProcessInfo $MissingFieldsInfo -ExpectedExecutablePattern '*powershell.exe' -RequiredCommandLineSubstrings @('lazy-supervisor.ps1'))) 'A process with unreadable executable/command-line fields must never match.'

    Write-Host 'Checking Install-LazyControlStack creates a current-user logon task with hidden PowerShell and the exact supervisor path...'
    $InstallDirectory = New-TrackedLazyTestDirectory
    $InstallDestination = Join-Path $InstallDirectory 'rendered.yaml'
    $InstallConfig = New-FakeRuntimeConfig -Directory $InstallDirectory -DestinationPath $InstallDestination
    $InstallPaths = New-FakeControlPaths $InstallDirectory
    $RegisteredTask = @{ Called = 0 }
    $TaskRegistrar = {
        param($TaskName, $Execute, $Argument, $WorkingDirectory, $UserId, $RunLevel)
        $RegisteredTask.Called += 1
        $RegisteredTask.TaskName = $TaskName
        $RegisteredTask.Execute = $Execute
        $RegisteredTask.Argument = $Argument
        $RegisteredTask.WorkingDirectory = $WorkingDirectory
        $RegisteredTask.UserId = $UserId
        $RegisteredTask.RunLevel = $RunLevel
    }.GetNewClosure()
    $InstallResult = Install-LazyControlStack -RepoRoot $RepoRoot -Paths $InstallPaths `
        -ConfigProvider { param($RepoRootArg) $InstallConfig }.GetNewClosure() `
        -TaskRegistrar $TaskRegistrar `
        -NowProvider { [DateTime]::Parse('2026-08-21T10:00:00Z').ToUniversalTime() }

    Assert-Equal 1 $RegisteredTask.Called 'Install must register the Scheduled Task exactly once.'
    Assert-Equal 'DWB Serena Lazy Tunnel' $RegisteredTask.TaskName 'Install must register the task under the exact expected name.'
    Assert-True ($RegisteredTask.Execute -like '*powershell.exe') 'Install must run the task via powershell.exe.'
    Assert-True ($RegisteredTask.Argument.Contains($FakeSupervisorPath)) 'Install must point the task at the exact lazy-supervisor.ps1 path.'
    Assert-True ($RegisteredTask.Argument -match '-WindowStyle\s+Hidden') 'Install must launch the supervisor with a hidden PowerShell window.'
    Assert-True ($RegisteredTask.Argument -notmatch '-Action') 'Install must invoke the supervisor script directly, not re-enter lazy-control.ps1.'
    Assert-Equal 'Limited' $RegisteredTask.RunLevel 'Install must never request an elevated principal for the logon task.'
    Assert-True (-not [string]::IsNullOrWhiteSpace($RegisteredTask.UserId)) 'Install must scope the task to the current user.'
    Assert-Equal 'DWB Serena Lazy Tunnel' $InstallResult.TaskName 'Install must report the task name it registered.'

    Write-Host 'Checking Install-LazyControlStack backs up the existing profile before rendering the lazy profile...'
    $BackupDirectory = New-TrackedLazyTestDirectory
    $BackupDestination = Join-Path $BackupDirectory 'rendered.yaml'
    $OldProfileContent = "config_version: 1`ncontrol_plane:`n  tunnel_id: `"OLD-PRE-EXISTING-PROFILE`"`n"
    Set-Content -LiteralPath $BackupDestination -Value $OldProfileContent -Encoding utf8 -NoNewline
    $BackupConfig = New-FakeRuntimeConfig -Directory $BackupDirectory -DestinationPath $BackupDestination
    $BackupPaths = New-FakeControlPaths $BackupDirectory
    $NoOpRegistrar = { param($TaskName, $Execute, $Argument, $WorkingDirectory, $UserId, $RunLevel) }.GetNewClosure()
    $BackupResult = Install-LazyControlStack -RepoRoot $RepoRoot -Paths $BackupPaths `
        -ConfigProvider { param($RepoRootArg) $BackupConfig }.GetNewClosure() `
        -TaskRegistrar $NoOpRegistrar `
        -NowProvider { [DateTime]::Parse('2026-08-21T11:22:33Z').ToUniversalTime() }

    Assert-True ($null -ne $BackupResult.BackupPath) 'Install must report where it backed up the existing profile.'
    Assert-True (Test-Path -LiteralPath $BackupResult.BackupPath) 'The reported backup file must actually exist.'
    Assert-True ($BackupResult.BackupPath.StartsWith($BackupPaths.BackupDirectory)) 'The backup must be written under the backups directory.'
    $BackupFileContent = Get-Content -Raw -LiteralPath $BackupResult.BackupPath
    Assert-Equal $OldProfileContent $BackupFileContent 'The backup must be a byte-for-byte copy of the pre-existing profile, captured before rendering.'
    $RenderedContent = Get-Content -Raw -LiteralPath $BackupDestination
    Assert-True (-not $RenderedContent.Contains('OLD-PRE-EXISTING-PROFILE')) 'After install, the active profile must be the freshly rendered lazy profile, not the old content.'
    Assert-True ($RenderedContent.Contains($FakeTunnelId)) 'The freshly rendered profile must contain the real Tunnel ID.'

    Write-Host 'Checking Install-LazyControlStack does not fabricate a backup when no profile exists yet...'
    $FreshInstallDirectory = New-TrackedLazyTestDirectory
    $FreshDestination = Join-Path $FreshInstallDirectory 'rendered.yaml'
    $FreshConfig = New-FakeRuntimeConfig -Directory $FreshInstallDirectory -DestinationPath $FreshDestination
    $FreshPaths = New-FakeControlPaths $FreshInstallDirectory
    $FreshResult = Install-LazyControlStack -RepoRoot $RepoRoot -Paths $FreshPaths `
        -ConfigProvider { param($RepoRootArg) $FreshConfig }.GetNewClosure() `
        -TaskRegistrar $NoOpRegistrar `
        -NowProvider { Get-Date }
    Assert-True ($null -eq $FreshResult.BackupPath) 'A first-time install with no pre-existing profile must not report a backup.'
    if (Test-Path -LiteralPath $FreshPaths.BackupDirectory) {
        $BackupCount = (Get-ChildItem -LiteralPath $FreshPaths.BackupDirectory -File -ErrorAction SilentlyContinue | Measure-Object).Count
        Assert-Equal 0 $BackupCount 'A first-time install must not create any backup file.'
    }
    Assert-True (Test-Path -LiteralPath $FreshDestination) 'A first-time install must still render the lazy profile.'

    Write-Host 'Checking Install-LazyControlStack never contacts the DPAPI secret...'
    Assert-True (-not (Test-Path -LiteralPath $FreshConfig.DpapiSecretPath)) 'Test precondition: the fake DPAPI secret path must not exist.'
    # (FreshConfig.DpapiSecretPath deliberately points at a nonexistent path; Get-DpapiApiKey would
    # throw "DPAPI secret file not found" if install ever attempted to decrypt it. The prior
    # Install-LazyControlStack call above already completed without throwing, which proves install
    # never called Get-DpapiApiKey.)

    Write-Host 'Checking Start-LazyControlStack launches the hidden supervisor and records the tunnel PID...'
    $StartDirectory = New-TrackedLazyTestDirectory
    $StartDestination = Join-Path $StartDirectory 'rendered.yaml'
    $StartConfig = New-FakeRuntimeConfig -Directory $StartDirectory -DestinationPath $StartDestination
    $StartPaths = New-FakeControlPaths $StartDirectory
    $LaunchRecorder = @{ Called = 0 }
    $FakeProcessLauncher = {
        param($FilePath, $ArgumentList, $WorkingDirectory)
        $LaunchRecorder.Called += 1
        $LaunchRecorder.FilePath = $FilePath
        $LaunchRecorder.ArgumentList = $ArgumentList
        $LaunchRecorder.WorkingDirectory = $WorkingDirectory
        [pscustomobject]@{ Id = 9001 }
    }.GetNewClosure()
    $MatchingProxyProcess = [pscustomobject]@{ Id = 9099; ParentId = 9001; ExecutablePath = $StartConfig.NodePath; CommandLine = $StartConfig.ProxyCommand }
    $FakeEnumerator = { , @($MatchingProxyProcess) }.GetNewClosure()
    $StartResult = Start-LazyControlStack -RepoRoot $RepoRoot -Paths $StartPaths `
        -ConfigProvider { param($RepoRootArg) $StartConfig }.GetNewClosure() `
        -ProcessLauncher $FakeProcessLauncher `
        -ProcessEnumerator $FakeEnumerator `
        -Sleeper { param($Milliseconds) } `
        -NowProvider { Get-Date }

    Assert-Equal 1 $LaunchRecorder.Called 'Start must launch the supervisor process exactly once.'
    Assert-True ($LaunchRecorder.FilePath -like '*powershell.exe') 'Start must launch the supervisor via powershell.exe.'
    Assert-True (($LaunchRecorder.ArgumentList -join ' ').Contains($FakeSupervisorPath)) 'Start must launch the exact lazy-supervisor.ps1 path.'
    Assert-True (($LaunchRecorder.ArgumentList -join ' ') -match 'Hidden') 'Start must launch the supervisor hidden.'
    Assert-Equal 9001 $StartResult.TunnelPid 'Start must report the launched supervisor PID.'
    Assert-Equal (Read-LazyPidFile -Path $StartPaths.TunnelPidPath) $StartResult.TunnelPid 'Start must persist the tunnel PID to its PID file.'
    Assert-Equal 9099 $StartResult.ProxyPid 'Start must discover and report the matching proxy process PID.'
    Assert-Equal (Read-LazyPidFile -Path $StartPaths.ProxyPidPath) $StartResult.ProxyPid 'Start must persist the discovered proxy PID to its PID file.'

    Write-Host 'Checking Start-LazyControlStack tolerates the proxy process not appearing within the discovery timeout...'
    $NoProxyDirectory = New-TrackedLazyTestDirectory
    $NoProxyDestination = Join-Path $NoProxyDirectory 'rendered.yaml'
    $NoProxyConfig = New-FakeRuntimeConfig -Directory $NoProxyDirectory -DestinationPath $NoProxyDestination
    $NoProxyPaths = New-FakeControlPaths $NoProxyDirectory
    $TimeQueue = New-Object System.Collections.Generic.Queue[datetime]
    $Base = Get-Date '2026-08-21T09:00:00'
    foreach ($OffsetMs in @(0, 100, 40100)) { $TimeQueue.Enqueue($Base.AddMilliseconds($OffsetMs)) }
    $QueueNowProvider = { if ($TimeQueue.Count -gt 0) { $TimeQueue.Dequeue() } else { $Base.AddMilliseconds(999999) } }.GetNewClosure()
    $NoProxyResult = Start-LazyControlStack -RepoRoot $RepoRoot -Paths $NoProxyPaths `
        -ConfigProvider { param($RepoRootArg) $NoProxyConfig }.GetNewClosure() `
        -ProcessLauncher { param($FilePath, $ArgumentList, $WorkingDirectory) [pscustomobject]@{ Id = 8001 } }.GetNewClosure() `
        -ProcessEnumerator { , @() }.GetNewClosure() `
        -DiscoveryTimeoutMs 30000 `
        -Sleeper { param($Milliseconds) } `
        -NowProvider $QueueNowProvider
    Assert-Equal 8001 $NoProxyResult.TunnelPid 'Start must still report the tunnel PID even if the proxy is not detected.'
    Assert-True ($null -eq $NoProxyResult.ProxyPid) 'Start must report a null proxy PID when discovery times out.'
    Assert-True ($null -eq (Read-LazyPidFile -Path $NoProxyPaths.ProxyPidPath)) 'Start must not write a proxy PID file when discovery times out.'

    Write-Host 'Checking Start-LazyControlStack fails clearly when the launcher does not return a process...'
    $FailDirectory = New-TrackedLazyTestDirectory
    $FailDestination = Join-Path $FailDirectory 'rendered.yaml'
    $FailConfig = New-FakeRuntimeConfig -Directory $FailDirectory -DestinationPath $FailDestination
    $FailPaths = New-FakeControlPaths $FailDirectory
    $LaunchFailed = $false
    try {
        Start-LazyControlStack -RepoRoot $RepoRoot -Paths $FailPaths `
            -ConfigProvider { param($RepoRootArg) $FailConfig }.GetNewClosure() `
            -ProcessLauncher { param($FilePath, $ArgumentList, $WorkingDirectory) $null }.GetNewClosure() `
            -ProcessEnumerator { , @() }.GetNewClosure() `
            -Sleeper { param($Milliseconds) } `
            -NowProvider { Get-Date } | Out-Null
    }
    catch { $LaunchFailed = $true }
    Assert-True $LaunchFailed 'Start must throw when the supervisor process fails to launch.'
    Assert-True ($null -eq (Read-LazyPidFile -Path $FailPaths.TunnelPidPath)) 'Start must not write a tunnel PID file when the launch failed.'

    Write-Host 'Checking Get-LazyControlStatus reports tunnel/proxy PIDs, status URL, Serena state and idle deadline without secrets...'
    $StatusDirectory = New-TrackedLazyTestDirectory
    $StatusDestination = Join-Path $StatusDirectory 'rendered.yaml'
    $StatusConfig = New-FakeRuntimeConfig -Directory $StatusDirectory -DestinationPath $StatusDestination
    $StatusPaths = New-FakeControlPaths $StatusDirectory
    New-Item -ItemType Directory -Force -Path $StatusPaths.BaseDirectory | Out-Null
    Set-Content -LiteralPath $StatusPaths.TunnelPidPath -Value '7001' -NoNewline
    Set-Content -LiteralPath $StatusPaths.ProxyPidPath -Value '7002' -NoNewline
    $TunnelInfo = [pscustomobject]@{ Id = 7001; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'; CommandLine = "-File `"$FakeSupervisorPath`"" }
    $ProxyInfo = [pscustomobject]@{ Id = 7002; ExecutablePath = $StatusConfig.NodePath; CommandLine = $StatusConfig.ProxyCommand }
    $InspectorMap = @{ 7001 = $TunnelInfo; 7002 = $ProxyInfo }
    $FakeInspector = { param($ProcessId) if ($InspectorMap.ContainsKey($ProcessId)) { $InspectorMap[$ProcessId] } else { $null } }.GetNewClosure()
    $FakeStatusJson = [pscustomobject]@{
        proxy = 'ready'; serena = 'idle'; pid = $null; inFlight = 0; queued = 0
        lastActivityAt = '2026-08-21T09:59:00Z'; idleDeadline = '2026-08-21T10:14:00Z'
        manifestVersion = 'v1'; manifestCompatible = $true; lastError = $null
    }
    $StatusResult = Get-LazyControlStatus -RepoRoot $RepoRoot -Paths $StatusPaths `
        -ConfigProvider { param($RepoRootArg) $StatusConfig }.GetNewClosure() `
        -ProcessInspector $FakeInspector `
        -StatusHttpGetter { param($Url) $FakeStatusJson }.GetNewClosure()

    Assert-Equal 7001 $StatusResult.TunnelPid 'Status must report the tunnel PID from its PID file.'
    Assert-True $StatusResult.TunnelVerified 'Status must report the tunnel PID as verified when it matches.'
    Assert-Equal 7002 $StatusResult.ProxyPid 'Status must report the proxy PID from its PID file.'
    Assert-True $StatusResult.ProxyVerified 'Status must report the proxy PID as verified when it matches.'
    Assert-Equal 'http://127.0.0.1:18012/status' $StatusResult.StatusUrl 'Status must expose the exact proxy status URL.'
    Assert-Equal 'idle' $StatusResult.SerenaState 'Status must surface the Serena state from the status endpoint.'
    Assert-Equal '2026-08-21T10:14:00Z' $StatusResult.IdleDeadline 'Status must surface the idle deadline from the status endpoint.'
    Assert-Equal 'v1' $StatusResult.ManifestVersion 'Status must surface the manifest version.'
    $StatusDump = ($StatusResult | Format-List | Out-String) + (Format-LazyControlStatus -Status $StatusResult)
    Assert-True (-not $StatusDump.Contains('api-key')) 'Status output must never reference the API key file.'
    Assert-True (-not $StatusDump.ToLowerInvariant().Contains('dpapi')) 'Status output must never reference DPAPI secret material.'

    Write-Host 'Checking Get-LazyControlStatus never decrypts the DPAPI secret (status must work even if the secret path is bogus)...'
    Assert-True (-not (Test-Path -LiteralPath $StatusConfig.DpapiSecretPath)) 'Test precondition: the fake DPAPI secret path must not exist.'
    # Get-DpapiApiKey throws "DPAPI secret file not found" for a missing path; Get-LazyControlStatus
    # completing without throwing proves it never calls Get-DpapiApiKey.
    Write-Host '  (implicitly proven above: Get-LazyControlStatus succeeded without a real DPAPI secret file)'

    Write-Host 'Checking Get-LazyControlStatus handles missing PID files without crashing...'
    $EmptyStatusDirectory = New-TrackedLazyTestDirectory
    $EmptyStatusDestination = Join-Path $EmptyStatusDirectory 'rendered.yaml'
    $EmptyStatusConfig = New-FakeRuntimeConfig -Directory $EmptyStatusDirectory -DestinationPath $EmptyStatusDestination
    $EmptyStatusPaths = New-FakeControlPaths $EmptyStatusDirectory
    $InspectorCalls = @{ Count = 0 }
    $EmptyInspector = { param($ProcessId) $InspectorCalls.Count += 1; $null }.GetNewClosure()
    $EmptyStatusResult = Get-LazyControlStatus -RepoRoot $RepoRoot -Paths $EmptyStatusPaths `
        -ConfigProvider { param($RepoRootArg) $EmptyStatusConfig }.GetNewClosure() `
        -ProcessInspector $EmptyInspector `
        -StatusHttpGetter { param($Url) throw 'connection refused' }.GetNewClosure()
    Assert-True ($null -eq $EmptyStatusResult.TunnelPid) 'Status must report a null tunnel PID when no PID file exists.'
    Assert-True (-not $EmptyStatusResult.TunnelVerified) 'Status must report the tunnel as not verified when no PID file exists.'
    Assert-Equal 0 $InspectorCalls.Count 'Status must never call the process inspector for a PID that was never on disk.'
    Assert-True ($null -ne $EmptyStatusResult.LastError) 'Status must surface the status-endpoint error rather than crashing.'

    Write-Host 'Checking Stop-LazyControlStack: missing PID files never trigger a stop...'
    $StopMissingDirectory = New-TrackedLazyTestDirectory
    $StopMissingDestination = Join-Path $StopMissingDirectory 'rendered.yaml'
    $StopMissingConfig = New-FakeRuntimeConfig -Directory $StopMissingDirectory -DestinationPath $StopMissingDestination
    $StopMissingPaths = New-FakeControlPaths $StopMissingDirectory
    $StopCalls = @{ Graceful = 0; Force = 0 }
    $NeverCalledGraceful = { param($ProcessId) $StopCalls.Graceful += 1 }.GetNewClosure()
    $NeverCalledForce = { param($ProcessId) $StopCalls.Force += 1 }.GetNewClosure()
    $MissingResult = Stop-LazyControlStack -RepoRoot $RepoRoot -Paths $StopMissingPaths `
        -ConfigProvider { param($RepoRootArg) $StopMissingConfig }.GetNewClosure() `
        -ProcessInspector { param($ProcessId) $null }.GetNewClosure() `
        -GracefulStopper $NeverCalledGraceful -ForceStopper $NeverCalledForce `
        -Sleeper { param($Milliseconds) } -NowProvider { Get-Date }
    Assert-Equal 0 $StopCalls.Graceful 'A missing PID file must never trigger a graceful stop attempt.'
    Assert-Equal 0 $StopCalls.Force 'A missing PID file must never trigger a forced stop attempt.'
    Assert-True (-not $MissingResult.TunnelStopped) 'With no PID file, TunnelStopped must be false.'
    Assert-True (-not $MissingResult.ProxyStopped) 'With no PID file, ProxyStopped must be false.'
    Assert-True ($MissingResult.SkippedStale.Count -eq 2) 'Both missing PID files must be recorded as skipped.'

    Write-Host 'Checking Stop-LazyControlStack: a stale PID whose process no longer exists is never force-killed...'
    $StopGoneDirectory = New-TrackedLazyTestDirectory
    $StopGoneDestination = Join-Path $StopGoneDirectory 'rendered.yaml'
    $StopGoneConfig = New-FakeRuntimeConfig -Directory $StopGoneDirectory -DestinationPath $StopGoneDestination
    $StopGonePaths = New-FakeControlPaths $StopGoneDirectory
    New-Item -ItemType Directory -Force -Path $StopGonePaths.BaseDirectory | Out-Null
    Set-Content -LiteralPath $StopGonePaths.TunnelPidPath -Value '5001' -NoNewline
    $GoneStopCalls = @{ Graceful = 0; Force = 0 }
    $GoneResult = Stop-LazyControlStack -RepoRoot $RepoRoot -Paths $StopGonePaths `
        -ConfigProvider { param($RepoRootArg) $StopGoneConfig }.GetNewClosure() `
        -ProcessInspector { param($ProcessId) $null }.GetNewClosure() `
        -GracefulStopper { param($ProcessId) $GoneStopCalls.Graceful += 1 }.GetNewClosure() `
        -ForceStopper { param($ProcessId) $GoneStopCalls.Force += 1 }.GetNewClosure() `
        -Sleeper { param($Milliseconds) } -NowProvider { Get-Date }
    Assert-Equal 0 $GoneStopCalls.Graceful 'A PID file pointing at a process that no longer exists must never trigger a graceful stop.'
    Assert-Equal 0 $GoneStopCalls.Force 'A PID file pointing at a process that no longer exists must never be force-killed.'

    Write-Host 'Checking Stop-LazyControlStack: a PID file whose process identity does not match is never stopped (unrelated-process safety)...'
    $StopWrongDirectory = New-TrackedLazyTestDirectory
    $StopWrongDestination = Join-Path $StopWrongDirectory 'rendered.yaml'
    $StopWrongConfig = New-FakeRuntimeConfig -Directory $StopWrongDirectory -DestinationPath $StopWrongDestination
    $StopWrongPaths = New-FakeControlPaths $StopWrongDirectory
    New-Item -ItemType Directory -Force -Path $StopWrongPaths.BaseDirectory | Out-Null
    Set-Content -LiteralPath $StopWrongPaths.TunnelPidPath -Value '6001' -NoNewline
    $UnrelatedProcess = [pscustomobject]@{ Id = 6001; ExecutablePath = 'C:\Windows\explorer.exe'; CommandLine = 'explorer.exe' }
    $WrongStopCalls = @{ Graceful = 0; Force = 0 }
    $WrongResult = Stop-LazyControlStack -RepoRoot $RepoRoot -Paths $StopWrongPaths `
        -ConfigProvider { param($RepoRootArg) $StopWrongConfig }.GetNewClosure() `
        -ProcessInspector { param($ProcessId) $UnrelatedProcess }.GetNewClosure() `
        -GracefulStopper { param($ProcessId) $WrongStopCalls.Graceful += 1 }.GetNewClosure() `
        -ForceStopper { param($ProcessId) $WrongStopCalls.Force += 1 }.GetNewClosure() `
        -Sleeper { param($Milliseconds) } -NowProvider { Get-Date }
    Assert-Equal 0 $WrongStopCalls.Graceful 'An unrelated process occupying the recorded PID must never receive a graceful stop signal.'
    Assert-Equal 0 $WrongStopCalls.Force 'An unrelated process occupying the recorded PID must never be force-killed.'
    Assert-True ($WrongResult.SkippedStale.Count -ge 1) 'A mismatched PID must be recorded as skipped for operator visibility.'
    Assert-True (Test-Path -LiteralPath $StopWrongPaths.TunnelPidPath) 'A mismatched/stale PID file must be left in place, not silently deleted.'

    Write-Host 'Checking Stop-LazyControlStack: a verified process that exits gracefully is not force-killed...'
    $StopGracefulDirectory = New-TrackedLazyTestDirectory
    $StopGracefulDestination = Join-Path $StopGracefulDirectory 'rendered.yaml'
    $StopGracefulConfig = New-FakeRuntimeConfig -Directory $StopGracefulDirectory -DestinationPath $StopGracefulDestination
    $StopGracefulPaths = New-FakeControlPaths $StopGracefulDirectory
    New-Item -ItemType Directory -Force -Path $StopGracefulPaths.BaseDirectory | Out-Null
    Set-Content -LiteralPath $StopGracefulPaths.TunnelPidPath -Value '5501' -NoNewline
    $GracefulRealInfo = [pscustomobject]@{ Id = 5501; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'; CommandLine = "-File `"$FakeSupervisorPath`"" }
    $GracefulState = @{ GracefulCalls = 0; ForceCalls = 0; InspectCalls = 0 }
    $GracefulInspector = {
        param($ProcessId)
        $GracefulState.InspectCalls += 1
        if ($GracefulState.InspectCalls -eq 1) { return $GracefulRealInfo }  # initial verify: alive
        return $null                                                        # every recheck afterward: process exited
    }.GetNewClosure()
    $GracefulResult = Stop-LazyControlStack -RepoRoot $RepoRoot -Paths $StopGracefulPaths `
        -ConfigProvider { param($RepoRootArg) $StopGracefulConfig }.GetNewClosure() `
        -ProcessInspector $GracefulInspector `
        -GracefulStopper { param($ProcessId) $GracefulState.GracefulCalls += 1; $GracefulState.GracefulPid = $ProcessId }.GetNewClosure() `
        -ForceStopper { param($ProcessId) $GracefulState.ForceCalls += 1 }.GetNewClosure() `
        -GracefulTimeoutMs 2000 -PollIntervalMs 100 `
        -Sleeper { param($Milliseconds) } -NowProvider { Get-Date }
    Assert-Equal 1 $GracefulState.GracefulCalls 'A verified process must receive exactly one graceful stop request.'
    Assert-Equal 5501 $GracefulState.GracefulPid 'The graceful stop must target the exact verified PID.'
    Assert-Equal 0 $GracefulState.ForceCalls 'A process that exits gracefully must never be force-killed.'
    Assert-True $GracefulResult.TunnelStopped 'The tunnel must be reported as stopped once it exits gracefully.'
    Assert-True (-not (Test-Path -LiteralPath $StopGracefulPaths.TunnelPidPath)) 'The PID file must be removed once the verified process is confirmed gone.'

    Write-Host 'Checking Stop-LazyControlStack: a verified process that ignores graceful shutdown is force-killed after the timeout...'
    $StopForceDirectory = New-TrackedLazyTestDirectory
    $StopForceDestination = Join-Path $StopForceDirectory 'rendered.yaml'
    $StopForceConfig = New-FakeRuntimeConfig -Directory $StopForceDirectory -DestinationPath $StopForceDestination
    $StopForcePaths = New-FakeControlPaths $StopForceDirectory
    New-Item -ItemType Directory -Force -Path $StopForcePaths.BaseDirectory | Out-Null
    Set-Content -LiteralPath $StopForcePaths.ProxyPidPath -Value '5601' -NoNewline
    $StubbornInfo = [pscustomobject]@{ Id = 5601; ExecutablePath = $StopForceConfig.NodePath; CommandLine = $StopForceConfig.ProxyCommand }
    $ForceState = @{ GracefulCalls = 0; ForceCalls = 0 }
    # NowProvider queue: initial check, then several polls still inside the window, then one past the deadline.
    $ForceTimeQueue = New-Object System.Collections.Generic.Queue[datetime]
    $ForceBase = Get-Date '2026-08-21T09:00:00'
    foreach ($OffsetMs in @(0, 100, 500, 1000, 1500, 2100, 2100)) { $ForceTimeQueue.Enqueue($ForceBase.AddMilliseconds($OffsetMs)) }
    $ForceNowProvider = { if ($ForceTimeQueue.Count -gt 0) { $ForceTimeQueue.Dequeue() } else { $ForceBase.AddMilliseconds(999999) } }.GetNewClosure()
    $ForceResult = Stop-LazyControlStack -RepoRoot $RepoRoot -Paths $StopForcePaths `
        -ConfigProvider { param($RepoRootArg) $StopForceConfig }.GetNewClosure() `
        -ProcessInspector { param($ProcessId) $StubbornInfo }.GetNewClosure() `
        -GracefulStopper { param($ProcessId) $ForceState.GracefulCalls += 1 }.GetNewClosure() `
        -ForceStopper { param($ProcessId) $ForceState.ForceCalls += 1; $ForceState.ForcePid = $ProcessId }.GetNewClosure() `
        -GracefulTimeoutMs 2000 -PollIntervalMs 100 `
        -Sleeper { param($Milliseconds) } -NowProvider $ForceNowProvider
    Assert-Equal 1 $ForceState.GracefulCalls 'A stubborn process must still receive exactly one graceful stop request first.'
    Assert-Equal 1 $ForceState.ForceCalls 'A process that never exits within the timeout must be force-killed exactly once.'
    Assert-Equal 5601 $ForceState.ForcePid 'The force-kill must target the exact verified PID.'
    Assert-True $ForceResult.ProxyStopped 'The proxy must be reported as stopped once force-killed.'

    Write-Host 'Checking Stop-LazyControlStack: a PID reused by an unrelated process at the moment of the force decision is never force-killed...'
    $StopRaceDirectory = New-TrackedLazyTestDirectory
    $StopRaceDestination = Join-Path $StopRaceDirectory 'rendered.yaml'
    $StopRaceConfig = New-FakeRuntimeConfig -Directory $StopRaceDirectory -DestinationPath $StopRaceDestination
    $StopRacePaths = New-FakeControlPaths $StopRaceDirectory
    New-Item -ItemType Directory -Force -Path $StopRacePaths.BaseDirectory | Out-Null
    Set-Content -LiteralPath $StopRacePaths.TunnelPidPath -Value '5701' -NoNewline
    $OriginalTunnelInfo = [pscustomobject]@{ Id = 5701; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'; CommandLine = "-File `"$FakeSupervisorPath`"" }
    $ReusedUnrelatedInfo = [pscustomobject]@{ Id = 5701; ExecutablePath = 'C:\Windows\System32\calc.exe'; CommandLine = 'calc.exe' }
    # Trace of NowProvider/ProcessInspector calls (GracefulTimeoutMs=2000, PollIntervalMs=100):
    #   inspector call #1 = initial verify (before graceful send)                -> OriginalTunnelInfo (match)
    #   NowProvider call #1 (index0=0ms)    -> Deadline = base + 2000ms
    #   NowProvider call #2 (index1=100ms)  -> 100  < 2000 -> loop body -> inspector call #2 -> OriginalTunnelInfo (match, still running)
    #   NowProvider call #3 (index2=500ms)  -> 500  < 2000 -> loop body -> inspector call #3 -> OriginalTunnelInfo (match, still running)
    #   NowProvider call #4 (index3=1000ms) -> 1000 < 2000 -> loop body -> inspector call #4 -> OriginalTunnelInfo (match, still running)
    #   NowProvider call #5 (index4=2100ms) -> 2100 >= 2000 -> loop exits WITHOUT another inspector call
    #   -> Stop-LazyControlStack now performs its mandatory final re-verify immediately before
    #      force-killing: inspector call #5 -> this is where we simulate the PID having been
    #      reused by an unrelated process in the gap after the last poll.
    $RaceState = @{ InspectCalls = 0; GracefulCalls = 0; ForceCalls = 0 }
    $RaceInspector = {
        param($ProcessId)
        $RaceState.InspectCalls += 1
        if ($RaceState.InspectCalls -le 4) { return $OriginalTunnelInfo }   # initial verify + 3 in-loop polls: still our process
        return $ReusedUnrelatedInfo                                        # the mandatory pre-force-kill re-verify: PID reused by something else
    }.GetNewClosure()
    $RaceTimeQueue = New-Object System.Collections.Generic.Queue[datetime]
    $RaceBase = Get-Date '2026-08-21T09:00:00'
    foreach ($OffsetMs in @(0, 100, 500, 1000, 2100)) { $RaceTimeQueue.Enqueue($RaceBase.AddMilliseconds($OffsetMs)) }
    $RaceNowProvider = { if ($RaceTimeQueue.Count -gt 0) { $RaceTimeQueue.Dequeue() } else { $RaceBase.AddMilliseconds(999999) } }.GetNewClosure()
    $RaceResult = Stop-LazyControlStack -RepoRoot $RepoRoot -Paths $StopRacePaths `
        -ConfigProvider { param($RepoRootArg) $StopRaceConfig }.GetNewClosure() `
        -ProcessInspector $RaceInspector `
        -GracefulStopper { param($ProcessId) $RaceState.GracefulCalls += 1 }.GetNewClosure() `
        -ForceStopper { param($ProcessId) $RaceState.ForceCalls += 1 }.GetNewClosure() `
        -GracefulTimeoutMs 2000 -PollIntervalMs 100 `
        -Sleeper { param($Milliseconds) } -NowProvider $RaceNowProvider
    Assert-Equal 1 $RaceState.GracefulCalls 'The genuinely-verified process must still receive one graceful stop request.'
    Assert-Equal 0 $RaceState.ForceCalls 'If the PID is occupied by a different, unverified process by the time a force-kill would be issued, it must never be force-killed.'
    Assert-True (-not $RaceResult.TunnelStopped) 'Stop-LazyControlStack must not claim success when the final pre-force-kill re-verify fails to confirm identity.'
    Assert-True (Test-Path -LiteralPath $StopRacePaths.TunnelPidPath) 'The PID file must be left in place when the final re-verify could not confirm the process was ours.'

    Write-Host 'Checking Stop-LazyControlStack: tunnel and proxy PIDs are stopped independently and never swapped...'
    $StopBothDirectory = New-TrackedLazyTestDirectory
    $StopBothDestination = Join-Path $StopBothDirectory 'rendered.yaml'
    $StopBothConfig = New-FakeRuntimeConfig -Directory $StopBothDirectory -DestinationPath $StopBothDestination
    $StopBothPaths = New-FakeControlPaths $StopBothDirectory
    New-Item -ItemType Directory -Force -Path $StopBothPaths.BaseDirectory | Out-Null
    Set-Content -LiteralPath $StopBothPaths.TunnelPidPath -Value '5801' -NoNewline
    Set-Content -LiteralPath $StopBothPaths.ProxyPidPath -Value '5802' -NoNewline
    $BothTunnelInfo = [pscustomobject]@{ Id = 5801; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'; CommandLine = "-File `"$FakeSupervisorPath`"" }
    $BothProxyInfo = [pscustomobject]@{ Id = 5802; ExecutablePath = $StopBothConfig.NodePath; CommandLine = $StopBothConfig.ProxyCommand }
    $BothMap = @{ 5801 = $BothTunnelInfo; 5802 = $BothProxyInfo }
    $BothInspector = { param($ProcessId) if ($BothMap.ContainsKey($ProcessId)) { $BothMap[$ProcessId] } else { $null } }.GetNewClosure()
    $BothGracefulPids = New-Object System.Collections.Generic.List[int]
    $BothResult = Stop-LazyControlStack -RepoRoot $RepoRoot -Paths $StopBothPaths `
        -ConfigProvider { param($RepoRootArg) $StopBothConfig }.GetNewClosure() `
        -ProcessInspector $BothInspector `
        -GracefulStopper { param($ProcessId) $BothGracefulPids.Add($ProcessId); $BothMap.Remove($ProcessId) }.GetNewClosure() `
        -ForceStopper { param($ProcessId) throw "Force stop should not be needed in this test for PID $ProcessId" }.GetNewClosure() `
        -GracefulTimeoutMs 2000 -PollIntervalMs 100 `
        -Sleeper { param($Milliseconds) } -NowProvider { Get-Date }
    Assert-Equal 2 $BothGracefulPids.Count 'Both the tunnel and the proxy must each receive their own graceful stop request.'
    Assert-True ($BothGracefulPids.Contains(5801)) 'The tunnel PID must be among the graceful-stop targets.'
    Assert-True ($BothGracefulPids.Contains(5802)) 'The proxy PID must be among the graceful-stop targets.'
    Assert-True $BothResult.TunnelStopped 'Both must report the tunnel as stopped.'
    Assert-True $BothResult.ProxyStopped 'Both must report the proxy as stopped.'

    Write-Host 'Checking Uninstall-LazyControlStack removes only the named task...'
    $UninstallDirectory = New-TrackedLazyTestDirectory
    $UninstallDestination = Join-Path $UninstallDirectory 'rendered.yaml'
    $UninstallConfig = New-FakeRuntimeConfig -Directory $UninstallDirectory -DestinationPath $UninstallDestination
    $UninstallPaths = New-FakeControlPaths $UninstallDirectory
    New-Item -ItemType Directory -Force -Path $UninstallPaths.BaseDirectory | Out-Null

    $RemoveCalls = @{ Count = 0 }
    $ExistenceCalls = @{ Count = 0 }
    $ExistingTaskChecker = { param($TaskName) $ExistenceCalls.Count += 1; $true }.GetNewClosure()
    $TaskRemover = { param($TaskName) $RemoveCalls.Count += 1; $RemoveCalls.TaskName = $TaskName }.GetNewClosure()
    $UninstallResult1 = Uninstall-LazyControlStack -RepoRoot $RepoRoot -Paths $UninstallPaths `
        -ConfigProvider { param($RepoRootArg) $UninstallConfig }.GetNewClosure() `
        -TaskExistenceChecker $ExistingTaskChecker -TaskRemover $TaskRemover `
        -ProcessInspector { param($ProcessId) $null }.GetNewClosure() `
        -GracefulStopper { param($ProcessId) }.GetNewClosure() -ForceStopper { param($ProcessId) }.GetNewClosure() `
        -Sleeper { param($Milliseconds) } -NowProvider { Get-Date }
    Assert-Equal 1 $RemoveCalls.Count 'Uninstall must remove the task exactly once when it exists.'
    Assert-Equal 'DWB Serena Lazy Tunnel' $RemoveCalls.TaskName 'Uninstall must remove the exact expected task name.'
    Assert-True $UninstallResult1.TaskRemoved 'Uninstall must report that the task was removed.'

    Write-Host 'Checking Uninstall-LazyControlStack does not attempt removal when the task does not exist...'
    $NoTaskChecker = { param($TaskName) $false }.GetNewClosure()
    $NoTaskRemoveCalls = @{ Count = 0 }
    $NoTaskRemover = { param($TaskName) $NoTaskRemoveCalls.Count += 1 }.GetNewClosure()
    $UninstallResult2 = Uninstall-LazyControlStack -RepoRoot $RepoRoot -Paths $UninstallPaths `
        -ConfigProvider { param($RepoRootArg) $UninstallConfig }.GetNewClosure() `
        -TaskExistenceChecker $NoTaskChecker -TaskRemover $NoTaskRemover `
        -ProcessInspector { param($ProcessId) $null }.GetNewClosure() `
        -GracefulStopper { param($ProcessId) }.GetNewClosure() -ForceStopper { param($ProcessId) }.GetNewClosure() `
        -Sleeper { param($Milliseconds) } -NowProvider { Get-Date }
    Assert-Equal 0 $NoTaskRemoveCalls.Count 'Uninstall must never call the task remover when the task does not exist.'
    Assert-True (-not $UninstallResult2.TaskRemoved) 'Uninstall must report the task as not removed when it never existed.'

    Write-Host 'Checking Uninstall-LazyControlStack stops the stack using the same PID-verification safety path...'
    $UninstallStopDirectory = New-TrackedLazyTestDirectory
    $UninstallStopDestination = Join-Path $UninstallStopDirectory 'rendered.yaml'
    $UninstallStopConfig = New-FakeRuntimeConfig -Directory $UninstallStopDirectory -DestinationPath $UninstallStopDestination
    $UninstallStopPaths = New-FakeControlPaths $UninstallStopDirectory
    New-Item -ItemType Directory -Force -Path $UninstallStopPaths.BaseDirectory | Out-Null
    Set-Content -LiteralPath $UninstallStopPaths.TunnelPidPath -Value '5901' -NoNewline
    $UnrelatedAtUninstall = [pscustomobject]@{ Id = 5901; ExecutablePath = 'C:\Windows\notepad.exe'; CommandLine = 'notepad.exe' }
    $UninstallStopCalls = @{ Graceful = 0; Force = 0 }
    $UninstallResult3 = Uninstall-LazyControlStack -RepoRoot $RepoRoot -Paths $UninstallStopPaths `
        -ConfigProvider { param($RepoRootArg) $UninstallStopConfig }.GetNewClosure() `
        -TaskExistenceChecker { param($TaskName) $false }.GetNewClosure() -TaskRemover { param($TaskName) }.GetNewClosure() `
        -ProcessInspector { param($ProcessId) $UnrelatedAtUninstall }.GetNewClosure() `
        -GracefulStopper { param($ProcessId) $UninstallStopCalls.Graceful += 1 }.GetNewClosure() `
        -ForceStopper { param($ProcessId) $UninstallStopCalls.Force += 1 }.GetNewClosure() `
        -Sleeper { param($Milliseconds) } -NowProvider { Get-Date }
    Assert-Equal 0 $UninstallStopCalls.Graceful 'Uninstall must inherit the same unrelated-process safety check as Stop.'
    Assert-Equal 0 $UninstallStopCalls.Force 'Uninstall must never force-kill an unrelated process found under a stale PID file.'

    Write-Host 'Checking Uninstall-LazyControlStack restores the latest valid backup...'
    $RestoreDirectory = New-TrackedLazyTestDirectory
    $RestoreDestination = Join-Path $RestoreDirectory 'rendered.yaml'
    $RestoreConfig = New-FakeRuntimeConfig -Directory $RestoreDirectory -DestinationPath $RestoreDestination
    $RestorePaths = New-FakeControlPaths $RestoreDirectory
    New-Item -ItemType Directory -Force -Path $RestorePaths.BackupDirectory | Out-Null
    Set-Content -LiteralPath (Join-Path $RestorePaths.BackupDirectory 'dwb-serena.20260821T090000Z.yaml') -Value "control_plane:`n  tunnel_id: `"OLDER-BACKUP`"`n" -NoNewline
    Set-Content -LiteralPath (Join-Path $RestorePaths.BackupDirectory 'dwb-serena.20260821T110000Z.yaml') -Value "control_plane:`n  tunnel_id: `"NEWEST-VALID-BACKUP`"`n" -NoNewline
    $RestoreResult = Uninstall-LazyControlStack -RepoRoot $RepoRoot -Paths $RestorePaths `
        -ConfigProvider { param($RepoRootArg) $RestoreConfig }.GetNewClosure() `
        -TaskExistenceChecker { param($TaskName) $false }.GetNewClosure() -TaskRemover { param($TaskName) }.GetNewClosure() `
        -ProcessInspector { param($ProcessId) $null }.GetNewClosure() `
        -GracefulStopper { param($ProcessId) }.GetNewClosure() -ForceStopper { param($ProcessId) }.GetNewClosure() `
        -Sleeper { param($Milliseconds) } -NowProvider { Get-Date }
    Assert-True ($null -ne $RestoreResult.RestoredFrom) 'Uninstall must report which backup it restored from.'
    Assert-True ($RestoreResult.RestoredFrom -match '20260821T110000Z') 'Uninstall must restore the most recent (newest timestamp) backup.'
    $RestoredContent = Get-Content -Raw -LiteralPath $RestoreDestination
    Assert-True ($RestoredContent.Contains('NEWEST-VALID-BACKUP')) 'The active profile must be replaced with the newest backup content, byte for byte.'

    Write-Host 'Checking Uninstall-LazyControlStack skips a corrupt/empty latest backup and falls back to the newest valid one...'
    $SkipDirectory = New-TrackedLazyTestDirectory
    $SkipDestination = Join-Path $SkipDirectory 'rendered.yaml'
    $SkipConfig = New-FakeRuntimeConfig -Directory $SkipDirectory -DestinationPath $SkipDestination
    $SkipPaths = New-FakeControlPaths $SkipDirectory
    New-Item -ItemType Directory -Force -Path $SkipPaths.BackupDirectory | Out-Null
    Set-Content -LiteralPath (Join-Path $SkipPaths.BackupDirectory 'dwb-serena.20260821T090000Z.yaml') -Value "control_plane:`n  tunnel_id: `"OLDER-VALID-BACKUP`"`n" -NoNewline
    Set-Content -LiteralPath (Join-Path $SkipPaths.BackupDirectory 'dwb-serena.20260821T120000Z.yaml') -Value '' -NoNewline
    $SkipResult = Uninstall-LazyControlStack -RepoRoot $RepoRoot -Paths $SkipPaths `
        -ConfigProvider { param($RepoRootArg) $SkipConfig }.GetNewClosure() `
        -TaskExistenceChecker { param($TaskName) $false }.GetNewClosure() -TaskRemover { param($TaskName) }.GetNewClosure() `
        -ProcessInspector { param($ProcessId) $null }.GetNewClosure() `
        -GracefulStopper { param($ProcessId) }.GetNewClosure() -ForceStopper { param($ProcessId) }.GetNewClosure() `
        -Sleeper { param($Milliseconds) } -NowProvider { Get-Date }
    Assert-True ($SkipResult.RestoredFrom -match '20260821T090000Z') 'An empty/corrupt latest backup must be skipped in favor of the newest valid one.'
    $SkipRestoredContent = Get-Content -Raw -LiteralPath $SkipDestination
    Assert-True ($SkipRestoredContent.Contains('OLDER-VALID-BACKUP')) 'The profile must be restored from the newest VALID backup, not the corrupt latest file.'

    Write-Host 'Checking Uninstall-LazyControlStack tolerates having no backups at all...'
    $NoBackupDirectory = New-TrackedLazyTestDirectory
    $NoBackupDestination = Join-Path $NoBackupDirectory 'rendered.yaml'
    $NoBackupConfig = New-FakeRuntimeConfig -Directory $NoBackupDirectory -DestinationPath $NoBackupDestination
    $NoBackupPaths = New-FakeControlPaths $NoBackupDirectory
    $NoBackupResult = Uninstall-LazyControlStack -RepoRoot $RepoRoot -Paths $NoBackupPaths `
        -ConfigProvider { param($RepoRootArg) $NoBackupConfig }.GetNewClosure() `
        -TaskExistenceChecker { param($TaskName) $false }.GetNewClosure() -TaskRemover { param($TaskName) }.GetNewClosure() `
        -ProcessInspector { param($ProcessId) $null }.GetNewClosure() `
        -GracefulStopper { param($ProcessId) }.GetNewClosure() -ForceStopper { param($ProcessId) }.GetNewClosure() `
        -Sleeper { param($Milliseconds) } -NowProvider { Get-Date }
    Assert-True ($null -eq $NoBackupResult.RestoredFrom) 'With no backups present, uninstall must not report a restore.'
    Assert-True (-not (Test-Path -LiteralPath $NoBackupDestination)) 'With no backups present and no prior profile, uninstall must not fabricate a profile file.'

    Write-Host 'Checking Lazy-Control.cmd exists and delegates exactly as specified...'
    $CmdPath = Join-Path $RepoRoot 'Lazy-Control.cmd'
    Assert-True (Test-Path -LiteralPath $CmdPath) 'Lazy-Control.cmd must exist.'
    $CmdContent = Get-Content -Raw -LiteralPath $CmdPath
    Assert-True ($CmdContent.Contains('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\lazy-control.ps1" -Action "%~1"')) 'Lazy-Control.cmd must delegate using the exact specified command line.'

    Write-Host 'All lazy control checks passed.' -ForegroundColor Green
}
finally {
    foreach ($Directory in $TestDirectories) {
        try { Remove-Item -LiteralPath $Directory -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}
