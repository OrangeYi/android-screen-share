# Passive, bounded diagnostics. All completion work runs on the GUI timer.
function New-SessionDiagnostics {
    return [pscustomobject]@{
        LastStarted = [DateTime]::MinValue
        AdbProcess = $null
        AdbOutput = $null
        AdbError = $null
        Ping = $null
        PingTask = $null
        Stopwatch = $null
        PingSamples = (New-Object System.Collections.ArrayList)
        LastCounters = $null
    }
}

function Get-NetworkCounters([string]$text) {
    $candidates = @(foreach ($line in ($text -split '\r?\n')) {
        if ($line -match '^\s*(wlan\d*|wifi\d*|eth\d*):\s*(.+)$') {
            $interface = $Matches[1]
            $values = @($Matches[2].Trim() -split '\s+')
            if ($values.Count -ge 16) {
                try {
                    [pscustomobject]@{
                        Interface = $interface
                        Received = [Int64]$values[0]
                        Sent = [Int64]$values[8]
                    }
                } catch {}
            }
        }
    })
    return $candidates | Sort-Object @{Expression={
        if ($_.Sent -gt 0 -or $_.Received -gt 0) { 0 } else { 1 }
    }}, @{Expression={
        if ($_.Interface -match '^(wlan|wifi)') { 0 } else { 1 }
    }} | Select-Object -First 1
}

function Get-SessionTransport([string]$serial) {
    if ($serial -match '^\d{1,3}(?:\.\d{1,3}){3}:\d+$') { return 'Wi-Fi (IP)' }
    if ($serial -match '^adb-') { return 'Wi-Fi (mDNS)' }
    return 'USB'
}

function Get-AdbDiagnosticMilliseconds([Diagnostics.Process]$process) {
    # ExitTime excludes time spent waiting for Ping and the next GUI tick.
    return [Math]::Max(0, [Math]::Round(($process.ExitTime - $process.StartTime).TotalMilliseconds))
}

function Stop-SessionDiagnostics([psobject]$session) {
    $diagnostics = $session.Diagnostics
    if (-not $diagnostics) { return }
    try {
        if ($diagnostics.AdbProcess -and -not $diagnostics.AdbProcess.HasExited) {
            $diagnostics.AdbProcess.Kill()
        }
    } catch {}
    try { if ($diagnostics.AdbProcess) { $diagnostics.AdbProcess.Dispose() } } catch {}
    try { if ($diagnostics.Ping) { $diagnostics.Ping.Dispose() } } catch {}
    if ($diagnostics.Stopwatch) { $diagnostics.Stopwatch.Stop() }
    $diagnostics.AdbProcess = $null
    $diagnostics.AdbOutput = $null
    $diagnostics.AdbError = $null
    $diagnostics.Ping = $null
    $diagnostics.PingTask = $null
    $diagnostics.Stopwatch = $null
}

function Start-SessionDiagnostics([psobject]$session) {
    $diagnostics = $session.Diagnostics
    if ($diagnostics.AdbProcess) { return }
    if (((Get-Date) - $diagnostics.LastStarted).TotalSeconds -lt 5) { return }
    $diagnostics.LastStarted = Get-Date
    $diagnostics.Stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $script:adbPath
        $serialArgument = '"' + ($session.Serial -replace '"', '\"') + '"'
        $info.Arguments = "-s $serialArgument shell cat /proc/net/dev"
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $diagnostics.AdbProcess = $process
        $process.StartInfo = $info
        [void]$process.Start()
        $diagnostics.AdbOutput = $process.StandardOutput.ReadToEndAsync()
        $diagnostics.AdbError = $process.StandardError.ReadToEndAsync()
        if ($session.Serial -match '^(\d{1,3}(?:\.\d{1,3}){3}):\d+$') {
            $diagnostics.Ping = New-Object Net.NetworkInformation.Ping
            $diagnostics.PingTask = $diagnostics.Ping.SendPingAsync($Matches[1], 900)
        }
    } catch {
        Add-Log (Get-Text 'diagnosticStartFailed' @($_.Exception.Message))
        Stop-SessionDiagnostics $session
    }
}

function Complete-SessionDiagnostics([psobject]$session) {
    $diagnostics = $session.Diagnostics
    if (-not $diagnostics.AdbProcess) { return }
    if (-not $diagnostics.AdbProcess.HasExited -or
        -not $diagnostics.AdbOutput.IsCompleted -or
        -not $diagnostics.AdbError.IsCompleted -or
        ($diagnostics.PingTask -and -not $diagnostics.PingTask.IsCompleted)) {
        if ($diagnostics.Stopwatch.ElapsedMilliseconds -lt 3000) { return }
        Add-Log (Get-Text 'diagnosticTimeout' @($session.Mode))
        Stop-SessionDiagnostics $session
        return
    }

    try {
        $parts = @(
            (Get-Text 'diagnosticPrefix' @($session.Mode, (Get-SessionTransport $session.Serial))),
            (Get-Text 'diagnosticEncoding' @($session.Fps, $session.Bitrate))
        )
        if ($diagnostics.PingTask) {
            $success = $false
            $pingLatency = '-'
            try {
                $reply = $diagnostics.PingTask.GetAwaiter().GetResult()
                $success = $reply.Status -eq [Net.NetworkInformation.IPStatus]::Success
                if ($success) { $pingLatency = "$($reply.RoundtripTime) ms" }
            } catch {}
            [void]$diagnostics.PingSamples.Add($success)
            while ($diagnostics.PingSamples.Count -gt 12) { $diagnostics.PingSamples.RemoveAt(0) }
            $lost = @($diagnostics.PingSamples | Where-Object { -not $_ }).Count
            $loss = [Math]::Round(($lost * 100.0) / $diagnostics.PingSamples.Count)
            $state = if ($success) { Get-Text 'diagnosticPingOk' } else { Get-Text 'diagnosticPingTimeout' }
            $parts += Get-Text 'diagnosticPing' @($state, $pingLatency, $loss, $diagnostics.PingSamples.Count)
        } else {
            $parts += Get-Text 'diagnosticPingUnavailable'
        }

        $output = $diagnostics.AdbOutput.GetAwaiter().GetResult()
        if ($diagnostics.AdbProcess.ExitCode -ne 0) {
            $adbError = $diagnostics.AdbError.GetAwaiter().GetResult().Trim()
            if (-not $adbError) { $adbError = "exit $($diagnostics.AdbProcess.ExitCode)" }
            $parts += Get-Text 'diagnosticAdbFailed' @($adbError)
        } else {
            $parts += Get-Text 'diagnosticAdbRtt' @((Get-AdbDiagnosticMilliseconds $diagnostics.AdbProcess))
            $counters = Get-NetworkCounters $output
            $now = $diagnostics.AdbProcess.ExitTime
            $traffic = Get-Text 'diagnosticTrafficUnavailable'
            if ($counters) {
                $traffic = Get-Text 'diagnosticTrafficPriming' @($counters.Interface)
                if ($diagnostics.LastCounters -and
                    $counters.Interface -eq $diagnostics.LastCounters.Interface) {
                    $seconds = ($now - $diagnostics.LastCounters.Time).TotalSeconds
                    $sent = $counters.Sent - $diagnostics.LastCounters.Sent
                    $received = $counters.Received - $diagnostics.LastCounters.Received
                    if ($seconds -gt 0 -and $sent -ge 0 -and $received -ge 0) {
                        $upMbps = [Math]::Round((($sent * 8) / $seconds) / 1000000, 2)
                        $downMbps = [Math]::Round((($received * 8) / $seconds) / 1000000, 2)
                        $traffic = Get-Text 'diagnosticTraffic' @($counters.Interface, $upMbps, $downMbps)
                    }
                }
                $diagnostics.LastCounters = [pscustomobject]@{
                    Time = $now; Interface = $counters.Interface
                    Sent = $counters.Sent; Received = $counters.Received
                }
            }
            $parts += $traffic
        }
        Add-Log ($parts -join ' | ')
    } catch {
        Add-Log (Get-Text 'diagnosticAdbFailed' @($_.Exception.Message))
    } finally {
        Stop-SessionDiagnostics $session
    }
}
