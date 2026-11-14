# Session lifecycle is independent from GUI construction.

function Ensure-Companion([string]$serial) {
    try {
        $installed = Invoke-Adb $serial @('shell', '--', 'pm', 'path', $script:companionPackage) -allowFailure
        $installedVersionCode = 0
        if (($installed -join '') -match '^package:') {
            $packageInfo = Invoke-Adb $serial @(
                'shell', '--', 'dumpsys', 'package', $script:companionPackage) -allowFailure
            foreach ($line in $packageInfo) {
                if ($line -match '\bversionCode=(\d+)') {
                    $installedVersionCode = [int]$Matches[1]
                    break
                }
            }
        }
        if ($installedVersionCode -lt $script:companionVersionCode) {
            if (-not (Test-Path -LiteralPath $script:companionApk)) {
                Add-Log (Get-Text 'companionUnavailable' @((Get-Text 'companionMissing')))
                return $false
            }
            if ($installedVersionCode -eq 0) {
                $answer = [System.Windows.Forms.MessageBox]::Show(
                    (Get-Text 'installPrompt'),
                    (Get-Text 'installTitle'),
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                    Add-Log (Get-Text 'companionSkipped')
                    return $false
                }
            }
            Add-Log (Get-Text 'installing')
            $result = Invoke-Adb $serial @('install', '-r', $script:companionApk) -allowFailure
            if (($result -join "`n") -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
                # Version 1 used a one-off signing key. The helper stores no user data,
                # so replace that legacy package once and keep future upgrades seamless.
                Invoke-Adb $serial @('uninstall', $script:companionPackage) -allowFailure | Out-Null
                $result = Invoke-Adb $serial @('install', $script:companionApk) -allowFailure
            }
            if (($result -join "`n") -notmatch 'Success') {
                Add-Log (Get-Text 'companionUnavailable' @(
                    (Get-Text 'installFailed' @(($result -join ' ')))))
                return $false
            }
        }
        Invoke-Adb $serial @(
            'shell', '--', 'pm', 'grant', $script:companionPackage,
            'android.permission.POST_NOTIFICATIONS') -allowFailure | Out-Null
        return $true
    } catch {
        Add-Log (Get-Text 'companionUnavailable' @($_.Exception.Message))
        return $false
    }
}

function Get-VirtualDisplayIds([string]$serial) {
    $ids = @()
    $lines = Invoke-Adb $serial @(
        'shell', '--', 'cmd', 'display', 'get-displays', '-i', '--type', 'virtual') -allowFailure
    foreach ($line in $lines) {
        if ([string]$line -match '^\s*(\d+)\s*$') { $ids += [int]$Matches[1] }
    }

    # Android 12 and some vendor builds do not implement
    # `cmd display get-displays`. Fall back to dumpsys and select only
    # virtual displays created by scrcpy, so physical/DeX display ids are not
    # mistaken for the session we just started.
    if ($ids.Count -eq 0) {
        $dump = Invoke-Adb $serial @('shell', '--', 'dumpsys', 'display') -allowFailure
        $dumpText = $dump -join "`n"
        foreach ($match in [regex]::Matches(
            $dumpText,
            'DisplayInfo\{"scrcpy",\s*displayId\s+(\d+)')) {
            $ids += [int]$match.Groups[1].Value
        }
    }
    return @($ids | Sort-Object -Unique)
}

function Stop-ShareSession([string]$mode, [bool]$killProcess = $true, [switch]$graceful) {
    if (-not $script:sessions.ContainsKey($mode)) { return }
    $session = $script:sessions[$mode]
    Save-SessionWindow $session
    Update-ShareProcessLog $session
    $script:sessions.Remove($mode)
    Stop-SessionDiagnostics $session
    if ($session.GestureProcess) { $session.GestureProcess.Dispose() }

    if ($killProcess -and -not $session.Process.HasExited) {
        if (-not ($graceful -and $session.Process.CloseMainWindow() -and $session.Process.WaitForExit(1500))) {
            Stop-Process -Id $session.Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    if ($session.CompanionActive) {
        try { $session.Listener.Stop() } catch {}
        $stopService = @('shell', '--', 'am', 'stopservice', '-n', $session.Component)
        $removeReverse = @('reverse', '--remove', "tcp:$($session.Port)")
        if ($graceful) {
            $device = @('-s', [AndroidScreenShare.CapturedProcess]::Quote($session.Serial))
            Invoke-DiscoveryAdb ($device + $stopService) 1200 | Out-Null
            Invoke-DiscoveryAdb ($device + $removeReverse) 1200 | Out-Null
        } else {
            Invoke-Adb $session.Serial $stopService -allowFailure | Out-Null
            Invoke-Adb $session.Serial $removeReverse -allowFailure | Out-Null
        }
    }
    $session.Capture.Dispose()
    Update-ShareHotkeys
    Save-Settings
    Add-Log (Get-Text 'sharingStopped' @($mode))
}

function Start-ShareSession {
    try {
        if (-not (Test-Path -LiteralPath $script:scrcpyPath)) {
            throw (Get-Text 'scrcpyMissing')
        }

        $mode = Get-SelectedShareMode
        if ($script:sessions.ContainsKey($mode)) {
            Add-Log (Get-Text 'alreadyRunning' @($mode))
            return
        }

        if (($mode -eq 'app' -and $script:sessions.ContainsKey('desktop')) -or
            ($mode -eq 'desktop' -and $script:sessions.ContainsKey('app'))) {
            throw (Get-Text 'appDesktopConflict')
        }

        $preferredSerial = Get-SelectedSerial
        $identity = [string]$script:deviceCombo.SelectedItem.Identity
        $device = Select-PreferredAdbDevice @(Get-DiscoveryDevices | Where-Object Identity -ceq $identity) $preferredSerial
        if (-not $device) { throw (Get-Text 'shareDeviceOffline') }
        $serial = $device.Serial
        Save-Settings

        $appPackage = ''
        $appDisplay = $null
        if ($mode -eq 'app') {
            $appPackage = Get-SelectedAppPackage
            $installed = @(Invoke-Adb $serial @('shell', '--', 'pm', 'path', $appPackage) -allowFailure)
            if (-not ($installed -match '^package:')) { throw (Get-Text 'appNotInstalled' @($appPackage)) }
        }

        $companionReady = Ensure-Companion $serial
        $quality = [string]$script:resolutionCombo.SelectedItem
        $fps = [string]$script:fpsCombo.SelectedItem
        $bitrate = [string]$script:bitrateCombo.SelectedItem
        $placement = Get-ShareWindowPlacement $mode $script:miniCheck.Checked
        $preset = Get-PlaybackPreset (@('control', 'movie', 'custom')[$script:presetCombo.SelectedIndex])
        $videoBuffer = [int]$script:bufferInput.Value
        $audioBuffer = [Math]::Max($preset.Audio, $videoBuffer)
        $scrcpyArguments = @(
            '-s', $serial,
            '--video-codec=h264',
            "--max-fps=$fps",
            "--video-bit-rate=$bitrate",
            "--video-buffer=$videoBuffer",
            "--audio-buffer=$audioBuffer",
            '--print-fps',
            "--window-x=$($placement.X)",
            "--window-y=$($placement.Y)"
        )
        if ($placement.Width -gt 0) { $scrcpyArguments += "--window-width=$($placement.Width)" }
        if ($placement.Height -gt 0) { $scrcpyArguments += "--window-height=$($placement.Height)" }
        if ($script:topmostCheck.Checked -or $script:miniCheck.Checked) { $scrcpyArguments += '--always-on-top' }
        if ($script:audioCheck.Checked) {
            $scrcpyArguments += @('--audio-source=output', '--audio-codec=aac')
        } else {
            $scrcpyArguments += '--no-audio'
        }

        if ($mode -ne 'mirror') {
            $displaySpec = if ($mode -eq 'app') {
                $appDisplay = Get-IndependentAppDisplay $quality ($script:appOrientationCombo.SelectedIndex -eq 1)
                $appDisplay.Spec
            } elseif ($quality -eq '1440p') {
                '2560x1440/213'
            } else {
                '1920x1080/160'
            }
            $scrcpyArguments += "--new-display=$displaySpec"
            if ($mode -eq 'app') {
                $scrcpyArguments += @("--start-app=$appPackage", '--no-vd-system-decorations',
                    '--no-power-on', '--window-title=AndroidScreenShare-App')
                if ($script:appScreenOffCheck.Checked) { $scrcpyArguments += '--turn-screen-off' }
                Add-Log (Get-Text 'appStarting' @($appPackage))
            } else { $scrcpyArguments += '--window-title=AndroidScreenShare-Desktop' }
            $port = 27284
            $component = 'dev.androidscreenshare.companion/.DesktopShareService'
        } else {
            $maxSize = if ($quality -eq '1440p') { '2560' } else { '1920' }
            $scrcpyArguments += @(
                "--max-size=$maxSize",
                '--window-title=AndroidScreenShare-Mirror')
            if ($script:screenOffCheck.Checked) {
                $scrcpyArguments += '--turn-screen-off'
            }
            $port = 27285
            $component = 'dev.androidscreenshare.companion/.MirrorShareService'
        }

        $launch = @{
            Mode = $mode
            Identity = $identity
            Arguments = [string[]]$scrcpyArguments
            AppPackage = $appPackage
            Fps = $fps
            Bitrate = $bitrate
            VideoBuffer = $videoBuffer
            Mini = $script:miniCheck.Checked
            Topmost = $script:topmostCheck.Checked
            InputWidth = $(if ($appDisplay) { $appDisplay.Width } elseif ($mode -eq 'desktop') { if ($quality -eq '1440p') { 2560 } else { 1920 } } else { 0 })
            InputHeight = $(if ($appDisplay) { $appDisplay.Height } elseif ($mode -eq 'desktop') { if ($quality -eq '1440p') { 1440 } else { 1080 } } else { 0 })
            Port = $port
            Component = $component
            CompanionReady = $companionReady
        }
        Open-ShareSession $launch $serial $device.IsUsb
    } catch {
        Add-Log (Get-Text 'startFailed' @($_.Exception.Message))
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            (Get-Text 'startFailedTitle'),
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
}

function Open-ShareSession([hashtable]$launch, [string]$serial, [bool]$isUsb) {
    $mode = $launch.Mode
    $port = $launch.Port
    $component = $launch.Component
    $appPackage = $launch.AppPackage
    $beforeIds = @()
    if ($mode -eq 'desktop') { $beforeIds = @(Get-VirtualDisplayIds $serial) }

    $capture = $null
    try {
        $arguments = [string[]]$launch.Arguments.Clone()
        $arguments[1] = $serial
        Add-Log (Get-Text 'starting' @($serial, $mode))
        $capture = [AndroidScreenShare.CapturedProcess]::new($script:scrcpyPath, $arguments, $script:scrcpyDir)
        $process = $capture.Process
        Start-Sleep -Milliseconds 900
        if ($process.HasExited) {
            $line = ''
            while ($capture.TryReadLine([ref]$line)) { Add-Log $line }
            throw (Get-Text 'startupExit')
        }

        $listener = $null
        $companionActive = $false
        if ($launch.CompanionReady) {
            try {
                $listener = [System.Net.Sockets.TcpListener]::new(
                    [System.Net.IPAddress]::Loopback,
                    $port)
                $listener.Start()
                Invoke-Adb $serial @('reverse', "tcp:$port", "tcp:$port") | Out-Null
                Invoke-Adb $serial @(
                    'shell', '--', 'am', 'start-foreground-service', '-n', $component,
                    '--ei', 'port', [string]$port) | Out-Null
                $companionActive = $true
            } catch {
                try { $listener.Stop() } catch {}
                $listener = $null
                Invoke-Adb $serial @(
                    'reverse', '--remove', "tcp:$port") -allowFailure | Out-Null
                Add-Log (Get-Text 'companionUnavailable' @($_.Exception.Message))
            }
        }

        $script:sessions[$mode] = [pscustomobject]@{
            Mode = $mode
            Serial = $serial
            IsUsb = $isUsb
            Launch = $launch
            FailedUsb = ''
            AppPackage = $appPackage
            Fps = $launch.Fps
            Bitrate = $launch.Bitrate
            Diagnostics = (New-SessionDiagnostics)
            Capture = $capture
            Mini = $launch.Mini
            Topmost = $launch.Topmost
            DisplayId = $(if ($mode -eq 'mirror') { 0 } else { $null })
            InputWidth = $launch.InputWidth
            InputHeight = $launch.InputHeight
            Sdk = 0
            TextureWidth = 0
            TextureHeight = 0
            ActualFps = $null
            LastFpsAt = [DateTime]::MinValue
            LastWindowSample = [DateTime]::MinValue
            GestureProcess = $null
            GestureStarted = $null
            LastGesture = [DateTime]::MinValue
            Port = $port
            Component = $component
            Process = $process
            Listener = $listener
            CompanionActive = $companionActive
        }

        if ($mode -eq 'app') {
            $session = $script:sessions[$mode]
            $timer = [Diagnostics.Stopwatch]::StartNew()
            while ($timer.ElapsedMilliseconds -lt 6000 -and -not $process.HasExited -and $null -eq $session.DisplayId) {
                Update-ShareProcessLog $session
                if ($null -eq $session.DisplayId) { Start-Sleep -Milliseconds 100 }
            }
            if ($process.HasExited -or $null -eq $session.DisplayId) { throw (Get-Text 'appDisplayMissing') }
            # A successful start message does not prove where Android placed the task.
            # Confirm against the activity list without launching on display 0.
            $dump = Invoke-DiscoveryAdb @('-s', ([AndroidScreenShare.CapturedProcess]::Quote($serial)), 'shell', 'dumpsys', 'activity', 'activities') 2500
            if (Test-AppOnDisplay $dump $session.DisplayId $appPackage) {
                Add-Log (Get-Text 'appOnDisplay' @($appPackage, $session.DisplayId))
            } else { Add-Log (Get-Text 'appPlacementUnconfirmed' @($appPackage)) }
        }

        if ($mode -eq 'desktop') {
            $displayId = $null
            $timer = [Diagnostics.Stopwatch]::StartNew()
            while ($timer.ElapsedMilliseconds -lt 6000 -and -not $process.HasExited) {
                Start-Sleep -Milliseconds 250
                $currentIds = @(Get-VirtualDisplayIds $serial)
                $displayId = $currentIds |
                    Where-Object { $beforeIds -notcontains $_ } |
                    Select-Object -First 1
                if ($null -ne $displayId) { break }
            }
            if ($null -ne $displayId) {
                $script:sessions[$mode].DisplayId = [int]$displayId
                Invoke-Adb $serial @(
                    'shell', '--', 'input', '-d', [string]$displayId,
                    'keyevent', 'KEYCODE_HOME') -allowFailure | Out-Null
            }
        }

        Initialize-SessionInput $script:sessions[$mode]
        Update-ShareProcessLog $script:sessions[$mode]
        if ($process.HasExited) { throw (Get-Text 'startupExit') }
        Update-ShareHotkeys
        Add-Log (Get-Text 'playbackStarted' @($launch.VideoBuffer, $launch.Mini))
        if ($companionActive) {
            Add-Log (Get-Text 'sharingActiveWithCompanion' @($mode))
        } else {
            Add-Log (Get-Text 'sharingActive' @($mode))
        }
        Add-Log (Get-Text 'diagnosticEnabled')
    } catch {
        if ($script:sessions.ContainsKey($mode)) { Stop-ShareSession $mode }
        elseif ($capture) { $capture.Dispose() }
        throw
    }
}

function Switch-ShareSessionToUsb([psobject]$session, [string]$usbSerial) {
    $mode = $session.Mode
    $launch = $session.Launch.Clone()
    $launch.Mini = $session.Mini
    $launch.Topmost = $session.Topmost
    $window = [AndroidScreenShare.DesktopWindows]::Find($session.Process.Id)
    $snapshot = [AndroidScreenShare.DesktopWindows]::Snapshot($window)
    $launch.Arguments = @($launch.Arguments | Where-Object { $_ -ne '--always-on-top' })
    if ($launch.Topmost -or $launch.Mini) { $launch.Arguments += '--always-on-top' }
    if ($snapshot -and -not $snapshot.Minimized -and -not $snapshot.Maximized -and -not $snapshot.Fullscreen) {
        $launch.Arguments = @($launch.Arguments | Where-Object { $_ -notmatch '^--window-(x|y|width|height)=' })
        $launch.Arguments += @("--window-x=$($snapshot.X)", "--window-y=$($snapshot.Y)",
            "--window-width=$($snapshot.Width)", "--window-height=$($snapshot.Height)")
    }

    Add-Log (Get-Text 'usbSwitchStarting' @($mode))
    try {
        Stop-ShareSession $mode -graceful
        Open-ShareSession $launch $usbSerial $true
        Add-Log (Get-Text 'usbSwitchCompleted' @($mode))
    } catch {
        Add-Log (Get-Text 'usbSwitchFailed' @($mode, $_.Exception.Message))
        if ($script:sessions.ContainsKey($mode)) {
            $session.FailedUsb = $usbSerial
            return
        }
        try {
            Open-ShareSession $launch $session.Serial $false
            $script:sessions[$mode].FailedUsb = $usbSerial
        } catch {
            Add-Log (Get-Text 'startFailed' @($_.Exception.Message))
        }
        return
    }
    Refresh-Devices -ListOnly
}

function Update-ShareUsbConnections {
    $wireless = @($script:sessions.Values | Where-Object { -not $_.IsUsb })
    if ($script:usbPoll) {
        $poll = $script:usbPoll
        if (-not $poll.OutputComplete -or -not $poll.Process.HasExited) {
            if (((Get-Date) - $script:usbPollAt).TotalSeconds -ge 3) {
                $poll.Dispose()
                $script:usbPoll = $null
            }
            return
        }
        $lines = @()
        $line = ''
        $exitCode = $poll.Process.ExitCode
        while ($poll.TryReadLine([ref]$line)) { $lines += $line }
        $poll.Dispose()
        $script:usbPoll = $null
        if ($exitCode -ne 0 -or -not $wireless.Count) { return }

        $usbDevices = @(ConvertFrom-AdbDeviceList $lines | Where-Object IsUsb)
        $usbSerials = @($usbDevices | ForEach-Object Serial)
        foreach ($serial in @($script:usbDeviceIdentities.Keys)) {
            if ($serial -cnotin $usbSerials) { $script:usbDeviceIdentities.Remove($serial) }
        }
        foreach ($device in $usbDevices) {
            if (-not $script:usbDeviceIdentities.ContainsKey($device.Serial)) {
                $identity = Get-AdbDeviceIdentity $device.Serial
                if ($identity) { $script:usbDeviceIdentities[$device.Serial] = $identity }
            }
        }
        foreach ($session in $wireless) {
            if ($session.FailedUsb -cnotin $usbSerials) { $session.FailedUsb = '' }
            $usb = $usbDevices | Where-Object {
                $_.Serial -cne $session.FailedUsb -and
                $script:usbDeviceIdentities[$_.Serial] -ceq $session.Launch.Identity
            } | Select-Object -First 1
            if ($usb) { Switch-ShareSessionToUsb $session $usb.Serial }
        }
        return
    }
    if (-not $wireless.Count) { $script:usbDeviceIdentities.Clear(); return }
    if (((Get-Date) - $script:usbPollAt).TotalSeconds -lt 2) { return }
    $script:usbPollAt = Get-Date
    $script:usbPoll = [AndroidScreenShare.CapturedProcess]::new($script:adbPath, [string[]]@('devices','-l'), $script:scrcpyDir)
}
