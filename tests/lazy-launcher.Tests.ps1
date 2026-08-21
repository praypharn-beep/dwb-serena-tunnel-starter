$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'scripts\lazy-common.ps1')

$FakeTunnelId = 'tunnel_0123456789abcdef0123456789abcdef'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

function New-LazyTestDirectory {
    $Directory = Join-Path ([System.IO.Path]::GetTempPath()) ("lazy-launcher-test-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $Directory | Out-Null
    return $Directory
}

$TestDirectories = New-Object System.Collections.Generic.List[string]
function New-TrackedLazyTestDirectory {
    $Directory = New-LazyTestDirectory
    $TestDirectories.Add($Directory)
    return $Directory
}

try {
    Write-Host 'Checking profile rendering...'
    $TemplateDirectory = New-TrackedLazyTestDirectory
    $TemplatePath = Join-Path $TemplateDirectory 'serena-team.yaml'
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
    $DestinationPath = Join-Path $TemplateDirectory 'rendered.yaml'
    $FakeProxyCommand = '"C:\node.exe" "C:\repo\lazy-proxy\cli.mjs" --manifest "C:\repo\lazy-proxy\serena-tools.json" --command "C:\serena.exe" --status 127.0.0.1:18012'
    $Rendered = Write-LazyTunnelProfile -TemplatePath $TemplatePath -DestinationPath $DestinationPath -TunnelId $FakeTunnelId -ProxyCommand $FakeProxyCommand

    Assert-True ($Rendered.Contains("tunnel_id: `"$FakeTunnelId`"")) 'Rendered profile must replace the tunnel ID placeholder.'
    Assert-True (-not $Rendered.Contains('__TUNNEL_ID__')) 'Rendered profile must not retain the tunnel ID placeholder.'
    Assert-True ($Rendered.Contains("command: '$FakeProxyCommand'")) 'Rendered profile must replace the proxy command placeholder inside the YAML single-quoted scalar.'
    Assert-True (-not $Rendered.Contains('__LAZY_PROXY_COMMAND__')) 'Rendered profile must not retain the proxy command placeholder.'
    Assert-True ($Rendered.Contains('listen_addr: 127.0.0.1:18010')) 'Rendered profile must preserve the loopback health listener.'
    Assert-True ((Get-Content -Raw -LiteralPath $DestinationPath) -eq $Rendered) 'Write-LazyTunnelProfile must persist exactly what it returns.'
    Assert-True (-not (Test-Path "$DestinationPath.tmp")) 'Write-LazyTunnelProfile must not leave a temporary file behind.'

    Write-Host 'Checking the rendered YAML round-trips for a Windows executable path containing spaces...'
    function ConvertFrom-LazyYamlSingleQuotedScalar {
        # A standalone, independent decoder for a YAML single-quoted scalar - written from the
        # YAML spec's escaping rule (a doubled '' represents one literal '), not by reusing or
        # inverting Write-LazyTunnelProfile's own Replace("'", "''") logic. Scans character by
        # character so this test exercises a genuinely separate implementation of the same rule.
        param([Parameter(Mandatory)] [string]$Line, [Parameter(Mandatory)] [string]$Prefix)
        $StartIndex = $Line.IndexOf($Prefix)
        if ($StartIndex -lt 0) { throw "Prefix not found in line: $Prefix" }
        $Cursor = $StartIndex + $Prefix.Length
        if ($Cursor -ge $Line.Length -or $Line[$Cursor] -ne "'") {
            throw "Expected an opening single quote immediately after '$Prefix'."
        }
        $Cursor += 1
        $Decoded = New-Object System.Text.StringBuilder
        $Closed = $false
        while ($Cursor -lt $Line.Length) {
            $Char = $Line[$Cursor]
            if ($Char -eq "'") {
                if (($Cursor + 1) -lt $Line.Length -and $Line[$Cursor + 1] -eq "'") {
                    [void]$Decoded.Append("'")
                    $Cursor += 2
                    continue
                }
                $Closed = $true
                break
            }
            [void]$Decoded.Append($Char)
            $Cursor += 1
        }
        if (-not $Closed) { throw 'Unterminated single-quoted scalar: no closing quote found.' }
        return $Decoded.ToString()
    }

    $SpacedNodePath = 'C:\Program Files\nodejs\node.exe'
    $SpacedSerenaPath = 'C:\Program Files\Serena\serena.exe'
    $SpacedProxyCommand = @(
        (ConvertTo-LazyQuotedArgument $SpacedNodePath),
        (ConvertTo-LazyQuotedArgument 'D:\repo\lazy-proxy\cli.mjs'),
        '--manifest', (ConvertTo-LazyQuotedArgument 'D:\repo\lazy-proxy\serena-tools.json'),
        '--command', (ConvertTo-LazyQuotedArgument $SpacedSerenaPath),
        '--status', '127.0.0.1:18012'
    ) -join ' '
    Assert-True ($SpacedProxyCommand.StartsWith('"')) 'Test setup sanity: a spaced-path command must start with a double quote - this is exactly the shape that broke YAML parsing before the single-quote fix.'

    $SpacedDestinationPath = Join-Path $TemplateDirectory 'rendered-spaced.yaml'
    $SpacedRendered = Write-LazyTunnelProfile -TemplatePath $TemplatePath -DestinationPath $SpacedDestinationPath -TunnelId $FakeTunnelId -ProxyCommand $SpacedProxyCommand
    $SpacedCommandLine = ($SpacedRendered -split "`r?`n") | Where-Object { $_ -match 'command:' } | Select-Object -First 1
    Assert-True ($null -ne $SpacedCommandLine) 'The rendered profile must contain a command: line.'
    $DecodedSpacedCommand = ConvertFrom-LazyYamlSingleQuotedScalar -Line $SpacedCommandLine -Prefix 'command: '
    Assert-True ($DecodedSpacedCommand -eq $SpacedProxyCommand) "An independent YAML decoder must recover the exact proxy command for a spaced executable path. Decoded: [$DecodedSpacedCommand] Expected: [$SpacedProxyCommand]"
    $OtherLines = ($SpacedRendered -split "`r?`n") | Where-Object { $_ -notmatch 'command:' }
    Assert-True (-not ($OtherLines -match "'")) 'No unrelated line should have gained a stray single quote from the escaping logic.'

    Write-Host 'Checking argument quoting safety...'
    $QuotedPlain = ConvertTo-LazyQuotedArgument -Value 'C:\no-spaces\cli.mjs'
    Assert-True ($QuotedPlain -eq 'C:\no-spaces\cli.mjs') 'A value with no special characters must be returned unquoted.'
    $QuotedSpaced = ConvertTo-LazyQuotedArgument -Value 'C:\Program Files\node.exe'
    Assert-True ($QuotedSpaced -eq '"C:\Program Files\node.exe"') 'A value containing spaces must be wrapped in double quotes.'
    $ThrewOnQuote = $false
    try { ConvertTo-LazyQuotedArgument -Value 'has"quote' | Out-Null } catch { $ThrewOnQuote = $true }
    Assert-True $ThrewOnQuote 'A value containing a double quote must be rejected rather than unsafely embedded.'
    $ThrewOnNewline = $false
    try { ConvertTo-LazyQuotedArgument -Value "line1`nline2" | Out-Null } catch { $ThrewOnNewline = $true }
    Assert-True $ThrewOnNewline 'A value containing a newline must be rejected rather than unsafely embedded.'

    Write-Host 'Checking the runtime config and rendered command...'
    $Config = Get-LazyRuntimeConfig -RepoRoot $RepoRoot -TunnelIdOverride $FakeTunnelId
    Assert-True ($Config.TunnelId -eq $FakeTunnelId) 'Get-LazyRuntimeConfig must honor an explicit tunnel ID override.'
    Assert-True ($Config.ManifestPath -eq (Join-Path $RepoRoot 'lazy-proxy\serena-tools.json')) 'Get-LazyRuntimeConfig must resolve the Task 4 manifest path exactly.'
    Assert-True (Test-Path $Config.ManifestPath) 'The resolved manifest path must exist.'
    Assert-True ($Config.IdleTimeoutMs -eq 900000) 'The approved idle timeout is 900000 ms.'
    Assert-True ($Config.StartupTimeoutMs -eq 30000) 'The approved startup timeout is 30000 ms.'
    Assert-True ($Config.StatusAddress -eq '127.0.0.1:18012') 'The approved status address is 127.0.0.1:18012.'

    $Command = $Config.ProxyCommand
    Assert-True ($Command.Contains('node')) 'The rendered command must invoke node.'
    Assert-True ($Command.Contains('cli.mjs')) 'The rendered command must invoke lazy-proxy/cli.mjs.'
    Assert-True ($Command.Contains($Config.ManifestPath)) 'The rendered command must reference the manifest path.'
    Assert-True ($Command.Contains('serena')) 'The rendered command must invoke serena.'
    Assert-True ($Command.Contains('127.0.0.1:18012')) 'The rendered command must expose status on 127.0.0.1:18012.'
    Assert-True (-not $Command.Contains("`n")) 'The rendered command must be a single line, safe to embed in YAML.'

    Write-Host 'Checking API key handling never leaks plaintext...'
    $PlaintextSecret = 'super-secret-control-plane-key-value'
    $SecretDirectory = New-TrackedLazyTestDirectory
    $SecretPath = Join-Path $SecretDirectory 'api-key.dpapi'
    (ConvertTo-SecureString -String $PlaintextSecret -AsPlainText -Force | ConvertFrom-SecureString) | Set-Content -LiteralPath $SecretPath -Encoding ascii

    $DecryptedSecret = Get-DpapiApiKey -SecretPath $SecretPath
    Assert-True ($DecryptedSecret -eq $PlaintextSecret) 'Get-DpapiApiKey must decrypt the exact plaintext that was encrypted.'

    $ConfigDump = ($Config | Format-List | Out-String)
    Assert-True (-not $ConfigDump.Contains($PlaintextSecret)) 'Get-LazyRuntimeConfig output must never contain decrypted API key plaintext.'

    Write-Host 'Checking the bounded restart policy...'
    $FakeConfig = [pscustomobject]@{
        RepoRoot               = $RepoRoot
        TunnelClientPath       = Join-Path $RepoRoot 'tunnel-client\tunnel-client.exe'
        DpapiSecretPath        = $SecretPath
        ProfileTemplatePath    = $TemplatePath
        ProfileDestinationPath = Join-Path (New-TrackedLazyTestDirectory) 'rendered-supervisor.yaml'
        TunnelId                = $FakeTunnelId
        ProxyCommand            = $FakeProxyCommand
        IdleTimeoutMs           = 900000
        StartupTimeoutMs        = 30000
        StatusAddress           = '127.0.0.1:18012'
    }
    # A Hashtable is used (rather than plain scalar variables) because Windows PowerShell 5.1's
    # GetNewClosure() detaches a scriptblock into its own private variable snapshot: writes made
    # to a $script:-scoped scalar from inside a closure do not propagate back to the caller. A
    # Hashtable is a reference type, so the captured reference still points at the same shared
    # object and mutations to its entries are visible everywhere.
    $RestartState = @{ LaunchCount = 0; FakeNow = Get-Date '2026-08-21T09:00:00' }
    $NowProvider = { $RestartState.FakeNow }.GetNewClosure()
    $ProcessLauncher = {
        param($FilePath, $ArgumentList, $WorkingDirectory)
        $RestartState.LaunchCount += 1
        $RestartState.FakeNow = $RestartState.FakeNow.AddMinutes(1)
        [pscustomobject]@{
            ExitCode = 1
        } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { } -PassThru
    }.GetNewClosure()

    $BoundExceeded = $false
    try {
        Start-LazyTunnel -RepoRoot $RepoRoot -MaxRestarts 3 -RestartWindowMinutes 10 `
            -ConfigProvider { param($RepoRootArg) $FakeConfig }.GetNewClosure() `
            -ProcessLauncher $ProcessLauncher `
            -NowProvider $NowProvider | Out-Null
    }
    catch {
        $BoundExceeded = $true
    }
    Assert-True $BoundExceeded 'Start-LazyTunnel must stop supervising once the restart bound is exceeded.'
    Assert-True ($RestartState.LaunchCount -eq 3) "Start-LazyTunnel must allow exactly 3 starts within the 10 minute window before stopping, launched $($RestartState.LaunchCount) times."

    Write-Host 'Checking -Once disables restart...'
    $RestartState.LaunchCount = 0
    $RestartState.FakeNow = Get-Date '2026-08-21T09:00:00'
    Start-LazyTunnel -RepoRoot $RepoRoot -MaxRestarts 3 -RestartWindowMinutes 10 -Once `
        -ConfigProvider { param($RepoRootArg) $FakeConfig }.GetNewClosure() `
        -ProcessLauncher $ProcessLauncher `
        -NowProvider $NowProvider | Out-Null
    Assert-True ($RestartState.LaunchCount -eq 1) '-Once must make exactly one start attempt and then return.'

    Write-Host 'Checking the sliding restart window expires old events...'
    $RestartState.LaunchCount = 0
    # A driven queue of exact timestamps (rather than "advance by 1 minute per launch") gives
    # precise control: two launches close together, then a jump of 15 minutes (past the 10
    # minute window, expiring both prior events), then three more launches close together. If
    # expiry were broken (old timestamps never removed), the 4th launch would already sit at
    # Count=3 heading into the window check and the bound would trip after only 3 total
    # launches instead of 5.
    $WindowEvents = New-Object System.Collections.Generic.Queue[datetime]
    $WindowBase = Get-Date '2026-08-21T09:00:00'
    foreach ($OffsetMinutes in @(0, 1, 15, 16, 17, 17.5)) {
        $WindowEvents.Enqueue($WindowBase.AddMinutes($OffsetMinutes))
    }
    $WindowNowProvider = { $WindowEvents.Dequeue() }.GetNewClosure()
    $WindowLauncher = {
        param($FilePath, $ArgumentList, $WorkingDirectory)
        $RestartState.LaunchCount += 1
        [pscustomobject]@{ ExitCode = 1 } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { } -PassThru
    }.GetNewClosure()

    $WindowBoundExceeded = $false
    try {
        Start-LazyTunnel -RepoRoot $RepoRoot -MaxRestarts 3 -RestartWindowMinutes 10 `
            -ConfigProvider { param($RepoRootArg) $FakeConfig }.GetNewClosure() `
            -ProcessLauncher $WindowLauncher `
            -NowProvider $WindowNowProvider | Out-Null
    }
    catch {
        $WindowBoundExceeded = $true
    }
    Assert-True $WindowBoundExceeded 'The restart bound must still trip once enough recent events accumulate after the window resets.'
    Assert-True ($RestartState.LaunchCount -eq 5) "Expiry must free up budget after the 15 minute jump: expected 2 launches in the first window plus 3 more in the fresh post-jump window (5 total) before the bound trips, got $($RestartState.LaunchCount)."

    Write-Host 'Checking a native child writing to stderr does not terminate the supervisor...'
    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        $NativeStderrConfig = $FakeConfig.PSObject.Copy()
        $NativeStderrConfig.TunnelClientPath = (Get-Command cmd.exe).Source
        $NativeStderrThrew = $false
        try {
            Start-LazyTunnel -RepoRoot $RepoRoot -MaxRestarts 3 -RestartWindowMinutes 10 -Once `
                -ConfigProvider { param($RepoRootArg) $NativeStderrConfig }.GetNewClosure() `
                -ProcessLauncher {
                    param($FilePath, $ArgumentList, $WorkingDirectory)
                    Start-Process -FilePath $FilePath -ArgumentList @('/c', 'echo native-stderr-line 1>&2') -WindowStyle Hidden -PassThru
                } `
                -NowProvider { Get-Date } | Out-Null
        }
        catch {
            $NativeStderrThrew = $true
        }
        Assert-True (-not $NativeStderrThrew) 'A native child writing to stderr must not raise a terminating PowerShell error.'
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }

    Write-Host 'Checking the real default process launcher path...'
    # No -ProcessLauncher override here: this exercises Start-LazyTunnel's actual production
    # default (Start-Process -PassThru -WindowStyle Hidden), not a mock. node.exe is guaranteed
    # present (Get-LazyRuntimeConfig already depends on it) and, given the fixed downstream
    # args Start-LazyTunnel always passes ('run', '--profile', 'dwb-serena'), reliably fails
    # fast and non-interactively: Node treats the first positional argument as a module/script
    # path, "run" is not one, so it exits quickly with a nonzero code rather than hanging on
    # stdin the way an interactively-invoked cmd.exe could.
    $DefaultLauncherConfig = $FakeConfig.PSObject.Copy()
    $DefaultLauncherConfig.TunnelClientPath = $Config.NodePath
    $DefaultLauncherExitCode = Start-LazyTunnel -RepoRoot $RepoRoot -MaxRestarts 3 -RestartWindowMinutes 10 -Once `
        -ConfigProvider { param($RepoRootArg) $DefaultLauncherConfig }.GetNewClosure() `
        -NowProvider { Get-Date }
    Assert-True ($DefaultLauncherExitCode -is [int]) "The real default launcher must return a concrete process exit code, got: $DefaultLauncherExitCode"
    Assert-True ($DefaultLauncherExitCode -ne 0) 'node.exe run --profile dwb-serena must fail (no such module) - a nonzero code proves a real process actually launched and was waited on, not a mock.'

    Write-Host 'Checking CONTROL_PLANE_API_KEY is populated during launch and cleared afterward...'
    Assert-True ([string]::IsNullOrEmpty($env:CONTROL_PLANE_API_KEY)) 'Test precondition failed: CONTROL_PLANE_API_KEY must not already be set in this process before this check runs.'

    $ObservedApiKey = @{ WasSet = $false; Value = $null }
    $ApiKeyObservingLauncher = {
        param($FilePath, $ArgumentList, $WorkingDirectory)
        $ObservedApiKey.WasSet = -not [string]::IsNullOrEmpty($env:CONTROL_PLANE_API_KEY)
        $ObservedApiKey.Value = $env:CONTROL_PLANE_API_KEY
        [pscustomobject]@{ ExitCode = 1 } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { } -PassThru
    }.GetNewClosure()
    Start-LazyTunnel -RepoRoot $RepoRoot -MaxRestarts 1 -RestartWindowMinutes 10 -Once `
        -ConfigProvider { param($RepoRootArg) $FakeConfig }.GetNewClosure() `
        -ProcessLauncher $ApiKeyObservingLauncher `
        -NowProvider { Get-Date } | Out-Null

    # This assertion must not be able to pass merely because the key was never populated: it
    # checks a flag captured live, from inside the launcher callback, at the exact moment the
    # tunnel process would have been started - not an assumption about prior state.
    Assert-True $ObservedApiKey.WasSet 'CONTROL_PLANE_API_KEY must actually be populated in the environment at the moment the tunnel process is launched.'
    Assert-True ($ObservedApiKey.Value -eq $DecryptedSecret) 'The environment variable observed during launch must equal the real decrypted API key, not a placeholder.'
    Assert-True ([string]::IsNullOrEmpty($env:CONTROL_PLANE_API_KEY)) 'CONTROL_PLANE_API_KEY must be cleared from the environment after Start-LazyTunnel returns on the success path.'

    Write-Host 'Checking CONTROL_PLANE_API_KEY is cleared even when the launcher throws...'
    $ThrowingLauncher = {
        param($FilePath, $ArgumentList, $WorkingDirectory)
        throw 'Simulated launch failure for cleanup coverage.'
    }.GetNewClosure()
    Start-LazyTunnel -RepoRoot $RepoRoot -MaxRestarts 1 -RestartWindowMinutes 10 -Once `
        -ConfigProvider { param($RepoRootArg) $FakeConfig }.GetNewClosure() `
        -ProcessLauncher $ThrowingLauncher `
        -NowProvider { Get-Date } | Out-Null
    Assert-True ([string]::IsNullOrEmpty($env:CONTROL_PLANE_API_KEY)) 'CONTROL_PLANE_API_KEY must be cleared from the environment even when the launcher throws.'

    Write-Host 'All lazy launcher checks passed.' -ForegroundColor Green
}
finally {
    foreach ($Directory in $TestDirectories) {
        try { Remove-Item -LiteralPath $Directory -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}
