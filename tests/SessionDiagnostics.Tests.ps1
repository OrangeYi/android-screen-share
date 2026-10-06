$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\app\SessionDiagnostics.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

# Counters are 64-bit and prefer the active Wi-Fi interface over idle interfaces.
$sample = @'
Inter-| Receive | Transmit
 eth0: 100 1 0 0 0 0 0 0 100 1 0 0 0 0 0 0
 wlan1: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
 wlan0: 6000000000 1 0 0 0 0 0 0 7000000000 1 0 0 0 0 0 0
'@
$counter = Get-NetworkCounters $sample
Assert ($counter.Interface -eq 'wlan0') 'The active Wi-Fi interface was not selected'
Assert ($counter.Received -eq 6000000000 -and $counter.Sent -eq 7000000000) 'Large byte counters were truncated'
Assert ($null -eq (Get-NetworkCounters 'Permission denied')) 'Unavailable counters were accepted'

# Late GUI collection must not inflate the ADB query duration.
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = Join-Path $env:WINDIR 'System32\cmd.exe'
$info.Arguments = '/d /c exit 0'
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$process = New-Object Diagnostics.Process
$process.StartInfo = $info
try {
    [void]$process.Start()
    Assert ($process.WaitForExit(2000)) 'The harmless timing probe did not exit'
    $first = Get-AdbDiagnosticMilliseconds $process
    Start-Sleep -Milliseconds 250
    $late = Get-AdbDiagnosticMilliseconds $process
    Assert ($first -eq $late) 'GUI polling delay inflated the ADB duration'
} finally { $process.Dispose() }

# Locale-independent ICMP uses .NET replies, and asynchronous resources are released.
$session = [pscustomobject]@{ Diagnostics = (New-SessionDiagnostics) }
$session.Diagnostics.Ping = New-Object Net.NetworkInformation.Ping
$session.Diagnostics.PingTask = $session.Diagnostics.Ping.SendPingAsync('127.0.0.1', 900)
Assert ($session.Diagnostics.PingTask.Wait(2000)) 'The loopback Ping did not complete'
Assert ($session.Diagnostics.PingTask.Result.Status -eq [Net.NetworkInformation.IPStatus]::Success) 'The loopback Ping failed'
Stop-SessionDiagnostics $session
Assert ($null -eq $session.Diagnostics.Ping -and $null -eq $session.Diagnostics.PingTask) 'Ping resources were retained'

# Start failures are bounded by the same five-second cooldown as successful probes.
function Get-Text([string]$Key, [object[]]$Values) { $Key }
function Add-Log([string]$Message) { $script:lastLog = $Message }
$script:adbPath = Join-Path $PSScriptRoot 'nonexistent-diagnostic-adb.exe'
$session = [pscustomobject]@{ Serial='TEST_DEVICE'; Diagnostics=(New-SessionDiagnostics) }
Start-SessionDiagnostics $session
Assert ($script:lastLog -eq 'diagnosticStartFailed') 'Start failure was not reported'
Assert ($null -eq $session.Diagnostics.AdbProcess) 'Failed process was retained'
$started = $session.Diagnostics.LastStarted
Start-SessionDiagnostics $session
Assert ($session.Diagnostics.LastStarted -eq $started) 'Start failure bypassed the cooldown'

Write-Output 'PASS: large counters, interface selection, accurate elapsed time, async Ping cleanup, failure cooldown'
