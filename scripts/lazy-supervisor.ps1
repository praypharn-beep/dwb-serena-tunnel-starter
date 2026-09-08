param(
    [switch]$Once
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lazy-common.ps1')

$StatePaths = Get-LazyRuntimeStatePaths
New-Item -ItemType Directory -Force -Path $StatePaths.BaseDirectory | Out-Null
Set-LazyPidFile -Path $StatePaths.TunnelPidPath -ProcessId $PID

$RunState = @{ TunnelClientPid = $null; ProxyPid = $null }
$EventLogger = {
    param($Message)
    Write-LazySupervisorEvent -Path $StatePaths.SupervisorLogPath -Message $Message
}.GetNewClosure()

$ProcessStarted = {
    param($Process, $Config)
    $RunState.TunnelClientPid = $Process.Id
    Set-LazyPidFile -Path $StatePaths.TunnelClientPidPath -ProcessId $Process.Id

    $Deadline = (Get-Date).AddMilliseconds($Config.StartupTimeoutMs)
    $ProxyPid = $null
    while ((Get-Date) -lt $Deadline) {
        try {
            $Process.Refresh()
            if ($Process.HasExited) { break }
        }
        catch { break }

        $Proxy = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ParentProcessId -eq $Process.Id -and
                $_.ExecutablePath -and $_.CommandLine -and
                ($_.ExecutablePath -ieq $Config.NodePath) -and
                $_.CommandLine.Contains('cli.mjs') -and
                $_.CommandLine.Contains($Config.ManifestPath.Replace('\', '/'))
            } |
            Select-Object -First 1

        if ($Proxy) {
            $ProxyPid = [int]$Proxy.ProcessId
            break
        }
        Start-Sleep -Milliseconds 250
    }

    if ($ProxyPid) {
        $RunState.ProxyPid = $ProxyPid
        Set-LazyPidFile -Path $StatePaths.ProxyPidPath -ProcessId $ProxyPid
        & $EventLogger "lazy-proxy-discovered pid=$ProxyPid parent=$($Process.Id)"
    }
    else {
        & $EventLogger "lazy-proxy-discovery-timeout parent=$($Process.Id)"
    }
}.GetNewClosure()

$ProcessExited = {
    param($Process, $ExitCode, $Config)
    Remove-LazyPidFileIfOwned -Path $StatePaths.TunnelClientPidPath -ProcessId $Process.Id
    if ($RunState.ProxyPid) {
        $ProxyStillRunning = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($RunState.ProxyPid)" -ErrorAction SilentlyContinue
        if (-not $ProxyStillRunning) {
            Remove-LazyPidFileIfOwned -Path $StatePaths.ProxyPidPath -ProcessId $RunState.ProxyPid
            $RunState.ProxyPid = $null
        }
    }
    $RunState.TunnelClientPid = $null
}.GetNewClosure()

try {
    & $EventLogger "supervisor-started pid=$PID"
    $ExitCode = Start-LazyTunnel -RepoRoot $RepoRoot -MaxRestarts 3 -RestartWindowMinutes 10 `
        -InitialRestartDelaySeconds 5 -MaxRestartDelaySeconds 60 -Once:$Once `
        -ProcessStarted $ProcessStarted -ProcessExited $ProcessExited -EventLogger $EventLogger
    & $EventLogger "supervisor-exiting pid=$PID code=$ExitCode"
    exit $ExitCode
}
catch {
    try { & $EventLogger "supervisor-failed pid=$PID message=$($_.Exception.Message)" } catch { }
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    exit 1
}
finally {
    Remove-LazyPidFileIfOwned -Path $StatePaths.TunnelPidPath -ProcessId $PID
    try { & $EventLogger "supervisor-stopped pid=$PID" } catch { }
}
