function Get-PlaybackPreset([string]$name) {
    if ($name -eq 'movie') { return [pscustomobject]@{ Video = 150; Audio = 150 } }
    return [pscustomobject]@{ Video = 0; Audio = 80 }
}

function Get-SwipeCoordinates([int]$width, [int]$height, [string]$action) {
    if ($width -lt 100 -or $height -lt 100) { throw (Get-Text 'gestureSizeUnknown') }
    $x1 = 0.5; $x2 = 0.5; $y1 = 0.75; $y2 = 0.25
    switch ($action) {
        'next' { }
        'previous' { $y1 = 0.25; $y2 = 0.75 }
        'left' { $x1 = 0.8; $x2 = 0.2; $y1 = 0.5; $y2 = 0.5 }
        'right' { $x1 = 0.2; $x2 = 0.8; $y1 = 0.5; $y2 = 0.5 }
        default { throw 'Unknown gesture' }
    }
    return @([int]($width * $x1), [int]($height * $y1), [int]($width * $x2), [int]($height * $y2), 300)
}

function Get-DisplayInputSize([string]$dump, [int]$displayId) {
    $size = $null
    foreach ($line in ($dump -split '\r?\n')) {
        if ($line -match "\bdisplayId[ =]+$displayId\b" -and
            $line -match '\breal\s+(\d+)\s*x\s*(\d+)') {
            $size = [pscustomobject]@{ Width = [int]$Matches[1]; Height = [int]$Matches[2] }
            if ($line -match '^\s*mOverrideDisplayInfo=') { return $size }
        }
    }
    return $size
}

function Get-GestureArguments([psobject]$session, [string]$action) {
    if ($session.Mode -ne 'mirror' -and ($null -eq $session.DisplayId -or $session.DisplayId -le 0)) {
        throw (Get-Text 'gestureDisplayUnknown')
    }
    $width = $session.InputWidth; $height = $session.InputHeight
    if ($session.Mode -in @('mirror', 'app') -and $session.TextureWidth -gt 0 -and
        (($width -gt $height) -ne ($session.TextureWidth -gt $session.TextureHeight))) {
        $width = $session.InputHeight; $height = $session.InputWidth
    }
    $arguments = @('-s', $session.Serial, 'shell', 'input')
    # Older Android versions have no -d option; the primary display is implicit.
    if ($session.Sdk -ge 29) { $arguments += @('-d', [string]$session.DisplayId) }
    elseif ($session.Mode -ne 'mirror') { throw (Get-Text 'gestureOldAndroid') }
    $arguments += 'swipe'
    $arguments += @(Get-SwipeCoordinates $width $height $action | ForEach-Object { [string]$_ })
    return $arguments
}

function Initialize-SessionInput([psobject]$session) {
    try {
        $sdkText = (Invoke-DiscoveryAdb @('-s', $session.Serial, 'shell', 'getprop', 'ro.build.version.sdk') 2000) -join ''
        $sdkNumber = 0
        if ([int]::TryParse($sdkText.Trim(), [ref]$sdkNumber)) { $session.Sdk = $sdkNumber }
        if ($null -eq $session.DisplayId) { return }
        $dump = (Invoke-DiscoveryAdb @('-s', $session.Serial, 'shell', 'dumpsys', 'display') 2500) -join "`n"
        $size = Get-DisplayInputSize $dump $session.DisplayId
        if ($size) { $session.InputWidth = $size.Width; $session.InputHeight = $size.Height; return }
        if ($session.Mode -eq 'mirror') {
            $wm = (Invoke-DiscoveryAdb @('-s', $session.Serial, 'shell', 'wm', 'size') 2000) -join "`n"
            $sizes = [regex]::Matches($wm, '(?:Physical|Override) size:\s*(\d+)x(\d+)')
            if ($sizes.Count -gt 0) {
                $session.InputWidth = [int]$sizes[$sizes.Count - 1].Groups[1].Value
                $session.InputHeight = [int]$sizes[$sizes.Count - 1].Groups[2].Value
            }
        }
    } catch { Add-Log (Get-Text 'gestureInitFailed' @($_.Exception.Message)) }
}

function Get-ControlSession {
    $mode = Get-SelectedShareMode
    if (-not $script:sessions.ContainsKey($mode) -or $script:sessions[$mode].Process.HasExited) {
        throw (Get-Text 'gestureNoSession')
    }
    return $script:sessions[$mode]
}

function Send-ShareGesture([string]$action, [psobject]$session = $null) {
    try {
        if (-not $session) { $session = Get-ControlSession }
        Update-ShareProcessLog $session
        if ($session.Mode -eq 'app') {
            Complete-HongguoPlayback
            if ($script:playbackInvocation) { return }
        }
        if ($session.GestureProcess -or ((Get-Date) - $session.LastGesture).TotalMilliseconds -lt 650) { return }
        $arguments = Get-GestureArguments $session $action
        $session.GestureProcess = [AndroidScreenShare.CapturedProcess]::new($script:adbPath, [string[]]$arguments, $script:scrcpyDir)
        $session.GestureStarted = [Diagnostics.Stopwatch]::StartNew()
        $session.LastGesture = Get-Date
        Add-Log (Get-Text 'gestureSent' @((Get-Text "gesture_$action"), $session.Mode, $session.DisplayId))
    } catch { Add-Log (Get-Text 'gestureFailed' @($_.Exception.Message)) }
}

function Update-ShareGesture([psobject]$session) {
    if (-not $session.GestureProcess) { return }
    if (-not $session.GestureProcess.Process.HasExited -and $session.GestureStarted.ElapsedMilliseconds -lt 3000) { return }
    try {
        if (-not $session.GestureProcess.Process.HasExited) { throw (Get-Text 'gestureTimeout') }
        if ($session.GestureProcess.Process.ExitCode -ne 0) {
            $line = ''; $messages = @()
            while ($session.GestureProcess.TryReadLine([ref]$line)) { $messages += $line }
            throw ($messages -join ' ')
        }
    } catch {
        Add-Log (Get-Text 'gestureFailed' @($_.Exception.Message))
    }
    finally { $session.GestureProcess.Dispose(); $session.GestureProcess = $null }
}

function Update-ShareHotkeys {
    if (-not $script:hotkeys) { return }
    Update-HongguoShortcuts
    $profile = 'Off'
    if ($script:sessions.Count -gt 0) {
        $profile = @('CtrlAlt', 'CtrlShift', 'Off')[$script:hotkeyCombo.SelectedIndex]
    }
    $failed = @($script:hotkeys.Configure($profile))
    if ($failed.Count -gt 0) { Add-Log (Get-Text 'hotkeyConflict' @($failed -join ', ')) }
}

function Stop-HongguoShortcuts {
    if ($script:playerHotkeys) {
        $script:playerHotkeys.Dispose()
        $script:playerHotkeys = $null
    }
    if ($script:playbackWorker) {
        $script:playbackWorker.Dispose()
        $script:playbackWorker = $null
        $script:playbackInvocation = $null
        $script:playbackAction = ''
    }
}

function Update-HongguoShortcuts {
    $player = $null
    $space = $script:spacePlaybackCheck.Checked
    $arrows = $script:hotkeyCombo.SelectedIndex -ne 2
    if (($space -or $arrows) -and $script:sessions.ContainsKey('app')) {
        $session = $script:sessions.app
        if ($session.AppPackage -eq 'com.phoenix.read' -and $session.DisplayId -gt 0 -and -not $session.Process.HasExited) {
            $player = $session.Process.Id
        }
    }
    if ($script:playerHotkeys -and $script:playerHotkeys.TargetProcessId -eq $player -and
        $script:playerHotkeys.SpaceEnabled -eq $space -and $script:playerHotkeys.ArrowsEnabled -eq $arrows) { return }
    Stop-HongguoShortcuts
    if ($player) {
        try {
            $script:playbackWorker = [PowerShell]::Create()
            $script:playbackWorker.Runspace.ThreadOptions = 'ReuseThread'
            $script:playerHotkeys = [AndroidScreenShare.FocusedPlayerHotkeys]::new($player, $script:hotkeys.Handle, $space, $arrows)
        } catch {
            Stop-HongguoShortcuts
            Add-Log (Get-Text 'spacePlaybackFailed' @($_.Exception.Message))
        }
    }
}

function Complete-HongguoPlayback {
    if (-not $script:playbackInvocation -or -not $script:playbackInvocation.IsCompleted) { return }
    try {
        $messages = $script:playbackWorker.EndInvoke($script:playbackInvocation)
        if ($script:playbackAction -eq 'toggle') { Add-Log (Get-Text 'spacePlaybackSent') }
        else { foreach ($key in $messages) { Add-Log (Get-Text ([string]$key)) } }
    } catch {
        $key = if ($script:playbackAction -eq 'toggle') { 'spacePlaybackFailed' } else { 'hongguoNextFailed' }
        Add-Log (Get-Text $key @($_.Exception.GetBaseException().Message))
    } finally {
        $script:playbackInvocation = $null
        $script:playbackAction = ''
    }
}

function Send-HongguoPlayback([string]$action) {
    if (-not $script:playbackWorker -or -not $script:sessions.ContainsKey('app')) { return }
    Complete-HongguoPlayback
    $session = $script:sessions.app
    Update-ShareGesture $session
    if ($session.AppPackage -ne 'com.phoenix.read' -or $session.Process.HasExited -or
        $script:playbackInvocation -or $session.GestureProcess -or $session.DisplayId -le 0 -or
        -not [AndroidScreenShare.FocusedPlayerHotkeys]::HasFocus($session.Process.Id)) { return }
    try {
        $worker = Join-Path $script:root 'app\HongguoPlayback.ps1'
        $script:playbackWorker.Commands.Clear()
        $script:playbackWorker.Streams.ClearStreams()
        $parameters = @{
            AdbPath=$script:adbPath; Serial=$session.Serial; DisplayId=$session.DisplayId
            PlayerPid=$session.Process.Id; RequireFocus=$true
        }
        if ($action -eq 'next') {
            Update-ShareProcessLog $session
            $parameters.NextEpisode = $true
            $parameters.VideoWidth = $session.TextureWidth
            $parameters.VideoHeight = $session.TextureHeight
            $parameters.NextSwipe = [int[]]((Get-GestureArguments $session 'next') | Select-Object -Last 5)
        }
        [void]$script:playbackWorker.AddCommand($worker).AddParameters($parameters)
        $script:playbackAction = $action
        $script:playbackInvocation = $script:playbackWorker.BeginInvoke()
    } catch {
        $script:playbackAction = ''
        $key = if ($action -eq 'toggle') { 'spacePlaybackFailed' } else { 'hongguoNextFailed' }
        Add-Log (Get-Text $key @($_.Exception.GetBaseException().Message))
    }
}

function Set-PlaybackPreset {
    if ($script:loadingSettings) { return }
    $name = @('control', 'movie', 'custom')[$script:presetCombo.SelectedIndex]
    if ($name -ne 'custom') {
        $script:applyingPreset = $true
        try { $script:bufferInput.Value = (Get-PlaybackPreset $name).Video }
        finally { $script:applyingPreset = $false }
    }
    Save-Settings
    Add-Log (Get-Text 'presetNextSession')
}

function Get-ShareWindowPlacement([string]$mode, [bool]$mini) {
    $screen = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position)
    $area = $screen.WorkingArea
    $result = [pscustomobject]@{ X=$area.Left+24; Y=$area.Top+24; Width=0; Height=0 }
    if ($mini) { $result.Width = if ($mode -eq 'desktop') { 640 } else { 360 } }
    $key = $mode + $(if ($mini) { '.mini' } else { '.normal' })
    if ($script:rememberWindowCheck.Checked -and $script:windowLayouts.ContainsKey($key)) {
        $saved = $script:windowLayouts[$key]
        $result.Width = [Math]::Max(160, [Math]::Min([int]$saved.Width, $area.Width - 24))
        $result.Height = [Math]::Max(120, [Math]::Min([int]$saved.Height, $area.Height - 48))
        $result.X = $area.Left + [Math]::Max(0, [Math]::Min([int]$saved.OffsetX, $area.Width - $result.Width - 16))
        $result.Y = $area.Top + [Math]::Max(0, [Math]::Min([int]$saved.OffsetY, $area.Height - $result.Height - 40))
    }
    return $result
}

function Save-SessionWindow([psobject]$session) {
    if (-not $script:rememberWindowCheck.Checked) { return }
    $handle = [AndroidScreenShare.DesktopWindows]::Find($session.Process.Id)
    $snapshot = [AndroidScreenShare.DesktopWindows]::Snapshot($handle)
    if (-not $snapshot -or $snapshot.Minimized -or $snapshot.Maximized -or $snapshot.Fullscreen -or $snapshot.Width -lt 100 -or $snapshot.Height -lt 100) { return }
    $area = [Windows.Forms.Screen]::FromHandle($handle).WorkingArea
    $key = $session.Mode + $(if ($session.Mini) { '.mini' } else { '.normal' })
    $script:windowLayouts[$key] = [pscustomobject]@{
        OffsetX = $snapshot.X - $area.Left; OffsetY = $snapshot.Y - $area.Top
        Width = $snapshot.Width; Height = $snapshot.Height
    }
}

function Set-ShareWindowOptions {
    if ($script:loadingSettings) { return }
    try {
        $session = Get-ControlSession
        $handle = [AndroidScreenShare.DesktopWindows]::Find($session.Process.Id)
        $snapshot = [AndroidScreenShare.DesktopWindows]::Snapshot($handle)
        if (-not $snapshot) { return }
        $mini = $script:miniCheck.Checked
        $session.Topmost = $script:topmostCheck.Checked
        if ($session.Mini -ne $mini -and -not $snapshot.Fullscreen -and -not $snapshot.Maximized) {
            Save-SessionWindow $session
            $placement = Get-ShareWindowPlacement $session.Mode $mini
            if ($placement.Width -eq 0) { $placement.Width = if ($session.Mode -eq 'desktop') { 1100 } else { 480 } }
            $placement.Height = [int]($placement.Width * $snapshot.Height / $snapshot.Width)
            $area = [Windows.Forms.Screen]::FromHandle($handle).WorkingArea
            if ($placement.Height -gt ($area.Height - 64)) {
                $placement.Height = $area.Height - 64
                $placement.Width = [int]($placement.Height * $snapshot.Width / $snapshot.Height)
            }
            $session.Mini = $mini
            [void][AndroidScreenShare.DesktopWindows]::Place($handle, $placement.X, $placement.Y, $placement.Width, $placement.Height, ($mini -or $script:topmostCheck.Checked))
        }
        [AndroidScreenShare.DesktopWindows]::SetTopmost($handle, ($session.Mini -or $script:topmostCheck.Checked))
    } catch {}
    Save-Settings
}

function Sync-ControlSessionOptions {
    if ($script:loadingSettings) { return }
    try {
        $session = Get-ControlSession
        $script:loadingSettings = $true
        $script:miniCheck.Checked = $session.Mini
        $script:topmostCheck.Checked = $session.Topmost
    } catch {} finally { $script:loadingSettings = $false }
}

function Write-RunLog([string]$message) {
    try {
        if (-not $script:runLogPath) {
            $directory = Join-Path $script:root 'data\logs'
            [void](New-Item -ItemType Directory -Path $directory -Force)
            $script:runLogPath = Join-Path $directory ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.log')
        }
        [IO.File]::AppendAllText($script:runLogPath, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $message`r`n", [Text.UTF8Encoding]::new($false))
    } catch {}
}

function Update-ShareProcessLog([psobject]$session) {
    $line = ''
    while ($session.Capture.TryReadLine([ref]$line)) {
        if ($session.Mode -eq 'app' -and $null -eq $session.DisplayId) {
            $createdId = Get-ScrcpyCreatedDisplayId $line
            if ($null -ne $createdId) { $session.DisplayId = $createdId }
        }
        if ($line -match '\b(\d+(?:\.\d+)?)\s+fps\b') {
            $session.ActualFps = $Matches[1]
            $session.LastFpsAt = Get-Date
            Write-RunLog "[$($session.Mode)] $line"
        } else {
            if ($line -match '(?:Texture|size):\s*(\d+)x(\d+)') {
                $session.TextureWidth = [int]$Matches[1]; $session.TextureHeight = [int]$Matches[2]
            }
            if ($line.Trim()) { Add-Log "[$($session.Mode)] $line" }
        }
    }
}
