param(
    [Parameter(Mandatory=$true)][string]$AdbPath,
    [Parameter(Mandatory=$true)][string]$Serial,
    [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$DisplayId,
    [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$PlayerPid,
    [switch]$RequireFocus,
    [switch]$NextEpisode,
    [int]$VideoWidth,
    [int]$VideoHeight,
    [int[]]$NextSwipe
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($Serial -match '["\r\n]' -or $Serial -match '\\$') { throw 'Invalid ADB identifier' }
$device = @('-s', ('"' + $Serial + '"'))
function Start-PlaybackAdb([string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new($AdbPath)
    $info.Arguments = ($device + @('shell') + $Arguments) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $commands.Add($process)
    return @{
        Process = $process
        Output = $process.StandardOutput.ReadToEndAsync()
        Error = $process.StandardError.ReadToEndAsync()
        Clock = [Diagnostics.Stopwatch]::StartNew()
    }
}

function Read-PlaybackAdb([hashtable]$command, [int]$timeoutMs) {
    $remaining = [Math]::Max(0, $timeoutMs - [int]$command.Clock.ElapsedMilliseconds)
    if (-not $command.Process.WaitForExit($remaining)) {
        try { $command.Process.Kill() } catch { }
        throw 'Android playback query timed out.'
    }
    if ($command.Process.ExitCode -ne 0) { throw 'Android playback command failed.' }
    return ($command.Output.GetAwaiter().GetResult() + "`n" + $command.Error.GetAwaiter().GetResult())
}

function Get-HongguoActivity([string]$dump) {
    $display = -1
    $resumed = foreach ($line in ($dump -split '\r?\n')) {
        if ($line -match '^\s*Display #(\d+)\s+\(activities') { $display = [int]$Matches[1] }
        elseif ($display -eq $DisplayId -and
            $line -match '^\s*(?:mResumedActivity:|ResumedActivity:|topResumedActivity=)\s*ActivityRecord\{([0-9a-f]+)\s+u\d+\s+(com\.phoenix\.read/com\.dragon\.read\.component\.shortvideo\.impl\.(?:ShortSeriesActivity|fullscreen\.ShortSeriesLandActivity))\s') {
            [pscustomobject]@{ Record=$Matches[1]; Component=$Matches[2] }
        }
    }
    $targets = @($resumed | Select-Object -Unique Record,Component)
    if ($targets.Count -ne 1) {
        throw 'No active Hongguo episode on the sharing display.'
    }
    return $targets[0]
}

function Read-HongguoLayout([string]$dump, [psobject]$activity, [switch]$AllowOffset, [switch]$CheckAdPage) {
    $nodes = New-Object 'Collections.Generic.List[object]'
    $stack = New-Object Collections.ArrayList
    $active = $false
    $viewTree = $false
    $appProcessId = ''
    $landscape = $activity.Component.EndsWith('.ShortSeriesLandActivity')
    $pagerId = if ($landscape) { 'f7_' } else { 'l0' }
    $activityPattern = '^\s*ACTIVITY ' + [regex]::Escape($activity.Component) + ' ' + $activity.Record + '\s+pid=(\d+)\b'
    $viewPattern = '^(\s*)([\w.$]+)\{([0-9a-f]+)\s+(\S+)\s+\S+\s+(-?\d+),(-?\d+)-(-?\d+),(-?\d+)'
    foreach ($line in ($dump -split '\r?\n')) {
        if ($line -match '^\s*ACTIVITY ') {
            $active = $line -match $activityPattern
            if ($active) { $appProcessId = $Matches[1] }
            $viewTree = $false
            $stack.Clear()
        }
        if (-not $active) { continue }
        if ($line -match '^\s*View Hierarchy:\s*$') { $viewTree = $true; continue }
        if (-not $viewTree -or $line -notmatch $viewPattern) { continue }
        $indent = $Matches[1].Length
        $class = $Matches[2]; $key = $Matches[3]; $flags = $Matches[4]
        $x = [int]$Matches[5]; $y = [int]$Matches[6]
        $w = [int]$Matches[7] - $x; $h = [int]$Matches[8] - $y
        $id = if ($line -match '\bapp:id/([A-Za-z0-9_]+)\b') { $Matches[1] } else { '' }
        while ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Indent -ge $indent) {
            $stack.RemoveAt($stack.Count - 1)
        }
        $parent = if ($stack.Count -gt 0) { $stack[$stack.Count - 1] } else { $null }
        $visible = $flags.StartsWith('V') -and $w -gt 0 -and $h -gt 0
        $page = ''; $inPager = $id -eq $pagerId
        if ($parent) {
            $x += $parent.X; $y += $parent.Y
            $visible = $visible -and $parent.Visible
            $page = $parent.Page
            $inPager = $inPager -or $parent.InPager
        }
        if ($inPager -and (($landscape -and $id -eq 'e54' -and $class -match '\.SingleTouchFrameLayout$') -or
            (-not $landscape -and $class -match '\.ExpandSeekBarDragFrameLayout$'))) { $page = $key }
        $node = [pscustomobject]@{
            Indent=$indent; Class=$class; Key=$key; Id=$id; X=$x; Y=$y; W=$w; H=$h
            Page=$page; InPager=$inPager; Visible=$visible; Clickable=($flags.Length -gt 6 -and $flags[6] -eq 'C')
            ParentKey=$(if ($parent) { $parent.Key } else { '' })
        }
        $nodes.Add($node)
        [void]$stack.Add($node)
    }
    $pager = @($nodes | Where-Object { $_.Id -eq $pagerId -and $_.Visible -and $_.X -eq 0 -and $_.Y -eq 0 })
    if ($pager.Count -ne 1 -or $pager[0].W -lt 360 -or $pager[0].H -lt 360) { throw 'Unrecognized Hongguo player.' }
    $width=$pager[0].W; $height=$pager[0].H
    if ($CheckAdPage) {
        # Only inspect the card covering the middle of the pager, never its preloaded neighbors.
        $recycler = $nodes | Where-Object {
            $_.ParentKey -eq $pager[0].Key -and $_.Class -like 'androidx.viewpager2.widget.ViewPager2$*'
        } | Select-Object -First 1
        if (-not $recycler) { return }
        $card = @($nodes | Where-Object {
            $_.ParentKey -eq $recycler.Key -and $_.Visible -and $_.W -eq $width -and $_.H -eq $height -and
            [Math]::Abs($_.Y) -lt $height / 2
        })
        if ($card.Count -ne 1 -or $card[0].Page) { return }
        $cardIndex = $nodes.IndexOf($card[0])
        for ($i = $cardIndex + 1; $i -lt $nodes.Count -and $nodes[$i].Indent -gt $card[0].Indent; $i++) {
            $node = $nodes[$i]
            if ($node.Visible -and $node.Class -like 'com.bytedance.ies.android.loki_lynx.*' -and
                $node.W -ge $width * 0.95 -and $node.H -ge $height * 0.95) {
                return [pscustomobject]@{ Key=$card[0].Key; Width=$width; Height=$height }
            }
        }
        return
    }
    # A wheel event can leave the next episode only half visible. Select it
    # only when it occupies at least half the pager and is unambiguous.
    $offsetLimit = if ($AllowOffset) { $height / 2 } else { 0 }
    $pages=@($nodes | Where-Object {
        $_.Page -eq $_.Key -and $_.Visible -and
        $_.X -eq 0 -and [Math]::Abs($_.Y) -le $offsetLimit -and $_.W -eq $width -and $_.H -eq $height
    })
    if ($pages.Count -ne 1) { throw 'The current episode could not be identified.' }
    $pageNodes=@($nodes | Where-Object Page -eq $pages[0].Key)
    if (-not @($pageNodes | Where-Object Id -eq 'hxk').Count) { throw 'Unrecognized episode layout.' }
    $playbackId = if ($landscape) { 'aqv' } else { 'b1' }
    if (@($pageNodes | Where-Object {
        $_.Id -eq $playbackId -and $_.Class -match '\.ShortSeriesScaleImageView$'
    }).Count -ne 1) { throw 'The standard episode player could not be confirmed.' }
    return [pscustomobject]@{
        Page=$pages[0].Key; Nodes=$pageNodes; Width=$width; Height=$height; OffsetY=$pages[0].Y
        ProcessId=$appProcessId; Landscape=$landscape
    }
}

function Test-PlayerPoint([psobject]$layout, [int]$x, [int]$y, [switch]$ForSwipe) {
    if (@($layout.Nodes | Where-Object {
        $_.Visible -and $_.Clickable -and $_.Id -ne 'dd' -and
        # This full-page video touch layer is where the pager receives a drag.
        (-not ($ForSwipe -and $_.Class -eq 'um4.b' -and $_.X -eq 0 -and
            $_.Y -eq $layout.OffsetY -and $_.W -eq $layout.Width -and $_.H -eq $layout.Height)) -and
        $_.X -le $x -and ($_.X+$_.W) -gt $x -and
        $_.Y -le $y -and ($_.Y+$_.H) -gt $y
    }).Count) { throw 'A different control occupies the player input point.' }
}

function Get-PlayerCenter([psobject]$layout) {
    $x = [int]($layout.Width / 2); $y = [int]($layout.Height / 2)
    Test-PlayerPoint $layout $x $y
    return [pscustomobject]@{ X=$x; Y=$y }
}

function Send-PlayerInput([string[]]$gesture, [int]$timeoutMs = 1800) {
    $owner = Get-Process -Id $PlayerPid -ErrorAction SilentlyContinue
    if (-not $owner -or $owner.ProcessName -ne 'scrcpy') { throw 'The sharing process has closed.' }
    if ($RequireFocus -and -not [AndroidScreenShare.FocusedPlayerHotkeys]::HasFocus($PlayerPid)) {
        throw 'The sharing window lost focus.'
    }
    $inputCommand = Start-PlaybackAdb (@('input','-d',[string]$DisplayId) + $gesture)
    $result = Read-PlaybackAdb $inputCommand $timeoutMs
    if ($result -match '(?i)error:|exception|denied') { throw 'Android rejected the targeted input.' }
}

function Get-HongguoAlignmentSwipe([psobject]$layout) {
    if ([Math]::Abs($layout.OffsetY) -le 2) { return }
    $x = [int]($layout.Width / 2)
    $shortSide = [Math]::Min($layout.Width,$layout.Height)
    # Start within the visible episode and keep both ends away from the
    # edges. Move only the remaining distance, allowing for touch slop.
    $distance = [Math]::Abs($layout.OffsetY) + [Math]::Max(12, [int]($shortSide * 0.022))
    $direction = [Math]::Sign($layout.OffsetY)
    $startY = [int]($layout.Height / 2 + $direction * ($distance / 2 - $layout.Height * 0.011))
    $endY = $startY - $direction * $distance
    Test-PlayerPoint $layout $x $startY -ForSwipe
    $duration = [int]([Math]::Max(7, [Math]::Ceiling($distance * 20 / ($layout.Height * 0.63))) * 50)
    return @('swipe', [string]$x, [string]$startY, [string]$x, [string]$endY, [string]$duration)
}

function Get-HongguoEpisodeForAlignment([psobject]$activity, [string]$dump) {
    try { Read-HongguoLayout $dump $activity -AllowOffset }
    catch { }
}

function Align-HongguoEpisode([psobject]$activity, [psobject]$layout, [switch]$AfterAd) {
    if ($layout -and [Math]::Abs($layout.OffsetY) -le 2) { return }
    $started = [Diagnostics.Stopwatch]::StartNew()
    $previous = $layout
    $target = if (-not $AfterAd) { $layout } else { $null }
    $gestures = 0
    $quickCheckMs = 75
    $settleCheckMs = 220
    $checkDelayMs = $quickCheckMs
    for ($sample = 0; $sample -lt 9 -and $started.ElapsedMilliseconds -lt 4000; $sample++) {
        Start-Sleep -Milliseconds $checkDelayMs
        # Check promptly after the wheel or a drag. If that snapshot still
        # shows movement or a partial layout, keep the normal settling delay.
        $checkDelayMs = $settleCheckMs
        $top = Start-PlaybackAdb @('dumpsys','activity',$activity.Record)
        try {
            $current = Read-HongguoLayout (Read-PlaybackAdb $top 900) $activity -AllowOffset
        }
        catch {
            # A dump taken while the pager rebinds can be incomplete. Require
            # two usable readings again before sending a drag.
            $previous = $null
            continue
        }
        if ($target -and ($current.Page -ne $target.Page -or $current.ProcessId -ne $target.ProcessId -or
            $current.Width -ne $target.Width -or $current.Height -ne $target.Height)) {
            $previous = $null
            continue
        }
        if ([Math]::Abs($current.OffsetY) -le 2) { 'adScrollAligned'; return }
        if ($previous -and $current.Page -eq $previous.Page -and $current.ProcessId -eq $previous.ProcessId -and
            $current.Width -eq $previous.Width -and $current.Height -eq $previous.Height -and
            $current.OffsetY -eq $previous.OffsetY -and $gestures -lt 2 -and $sample -lt 8) {
            # Verify the activity on the exact display immediately before
            # input. Avoid running two activity dumps at the same time.
            $active = Start-PlaybackAdb @('dumpsys','activity','activities')
            try { $resumed = Get-HongguoActivity (Read-PlaybackAdb $active 900) }
            catch {
                $previous = $null
                continue
            }
            if ($resumed.Record -ne $activity.Record) { break }
            $swipe = Get-HongguoAlignmentSwipe $current
            Send-PlayerInput $swipe (1700 + [int]$swipe[-1])
            $target = $current
            $gestures++
            $previous = $null
            $checkDelayMs = $quickCheckMs
            continue
        }
        $previous = $current
    }
    'adAlignIncomplete'
}

function Read-HongguoAfterAdInput([psobject]$activity) {
    # Try again if the first view dump is unavailable while the ad moves.
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $top = Start-PlaybackAdb @('dumpsys','activity',$activity.Record)
        try {
            $dump = Read-PlaybackAdb $top 900
            $card = Read-HongguoLayout $dump $activity -CheckAdPage
            return @{ Dump=$dump; Ad=$card }
        } catch { }
    }
}

function Send-HongguoWheelDown {
    [AndroidScreenShare.DesktopWindows]::WheelDown($PlayerPid)
}

function Invoke-HongguoAdWheel([psobject]$activity, [psobject]$card, [string]$logKey) {
    for ($step = 0; $step -lt 8; $step++) {
        if (-not (Send-HongguoWheelDown)) { return }
        if ($step -eq 0) { $logKey }
        Start-Sleep -Milliseconds 105

        if ($activity) {
            $view = Read-HongguoAfterAdInput $activity
            if (-not $view) {
                if ($card) { Align-HongguoEpisode $activity $null -AfterAd; return }
                break
            }
            $visibleAd = $view.Ad
            if ($visibleAd) {
                if ($card -and $visibleAd.Key -cne $card.Key) { break }
                $card = $visibleAd
                continue
            }
            $layout = Get-HongguoEpisodeForAlignment $activity $view.Dump
            if ($layout -or $card) {
                Align-HongguoEpisode $activity $layout -AfterAd
                return
            }
        }
        if ($card) { break }
        # A countdown may be recognized only by OCR on an unfamiliar ad.
        try { $countdown = Get-HongguoAdCountdown $PlayerPid $VideoWidth $VideoHeight }
        catch { break }
        if ($countdown -le 0) { break }
    }
    'adWheelIncomplete'
}

function Invoke-HongguoNextEpisode {
    if ($NextSwipe.Count -ne 5) { throw 'Next episode coordinates are unavailable.' }
    $activity = $null
    $card = $null
    $layout = $null
    try {
        $activities = Start-PlaybackAdb @('dumpsys','activity','activities')
        $activity = Get-HongguoActivity (Read-PlaybackAdb $activities 650)
        $top = Start-PlaybackAdb @('dumpsys','activity',$activity.Record)
        $dump = Read-PlaybackAdb $top 650
        $card = Read-HongguoLayout $dump $activity -CheckAdPage
        if (-not $card) { $layout = Get-HongguoEpisodeForAlignment $activity $dump }
    } catch {
        # The next-episode gesture also works in other Hongguo views.
    }
    if ($layout -and [Math]::Abs($layout.OffsetY) -gt 2) {
        # A second press on a split page is a recovery, not another episode change.
        Align-HongguoEpisode $activity $layout
        return
    }

    $countdown = $null
    if ($VideoWidth -gt 0 -and $VideoHeight -gt 0) {
        try { $countdown = Get-HongguoAdCountdown $PlayerPid $VideoWidth $VideoHeight -KnownAd:([bool]$card) }
        catch { }
    }
    if ($countdown -gt 0) {
        Invoke-HongguoAdWheel $activity $card 'adScrollSent'
        return
    }

    if (-not $card) {
        Send-PlayerInput (@('swipe') + $NextSwipe)
        'hongguoNextSent'
        return
    }

    $x = [int]($card.Width * 0.5)
    $start = [int]($card.Height * 0.75)
    $end = [int]($card.Height * 0.25)
    Send-PlayerInput @('swipe',$x,$start,$x,$end,'300')
    Start-Sleep -Milliseconds 160
    $view = Read-HongguoAfterAdInput $activity
    if (-not $view) { Align-HongguoEpisode $activity $null -AfterAd; return }
    $visibleAd = $view.Ad
    if ($visibleAd) {
        if ($visibleAd.Key -ceq $card.Key) {
            Invoke-HongguoAdWheel $activity $visibleAd 'adWheelFallback'
        }
        return
    }
    $layout = Get-HongguoEpisodeForAlignment $activity $view.Dump
    'adSwipeSent'
    Align-HongguoEpisode $activity $layout -AfterAd
}

function Read-HongguoAudioState([hashtable]$command, [string]$appProcessId) {
    try { $audio = Read-PlaybackAdb $command 1600 }
    catch { return 'unknown' }
    $pattern = '(?m)^\s*AudioPlaybackConfiguration.*\btype:android\.media\.AudioTrack\s+u/pid:\d+/' + $appProcessId + '\s+state:'
    if ($audio -match ($pattern + 'started\b.*\busage=USAGE_MEDIA\b')) { return 'playing' }
    if ($audio -match ($pattern + 'paused\b.*\busage=USAGE_MEDIA\b')) { return 'paused' }
    return 'unknown'
}

$commands = [Collections.Generic.List[Diagnostics.Process]]::new()
try {
    if ($NextEpisode) {
        . (Join-Path $PSScriptRoot 'HongguoAdScan.ps1')
        Invoke-HongguoNextEpisode
        return
    }
    $activities = Start-PlaybackAdb @('dumpsys','activity','activities')
    $audio = Start-PlaybackAdb @('dumpsys','audio')
    $activity = Get-HongguoActivity (Read-PlaybackAdb $activities 2200)
    $top = Start-PlaybackAdb @('dumpsys','activity',$activity.Record)
    $layout = Read-HongguoLayout (Read-PlaybackAdb $top 2800) $activity
    $center = Get-PlayerCenter $layout
    $before = Read-HongguoAudioState $audio $layout.ProcessId
    Send-PlayerInput @('tap',[string]$center.X,[string]$center.Y)
    # One center tap can reveal the controls without changing playback.
    # Check the real state before a second tap; do not send a double-click.
    if ($layout.Landscape -and $before -ne 'unknown') {
        $tapGap = [Diagnostics.Stopwatch]::StartNew()
        # Read the new layout while the app settles after the first tap.
        $top = Start-PlaybackAdb @('dumpsys','activity',$activity.Record)
        $activities = Start-PlaybackAdb @('dumpsys','activity','activities')
        $settle = 180 - [int]$tapGap.ElapsedMilliseconds
        if ($settle -gt 0) { Start-Sleep -Milliseconds $settle }
        $audio = Start-PlaybackAdb @('dumpsys','audio')
        if ((Read-HongguoAudioState $audio $layout.ProcessId) -eq $before -and
            (Get-HongguoActivity (Read-PlaybackAdb $activities 2200)).Record -eq $activity.Record) {
            $current = Read-HongguoLayout (Read-PlaybackAdb $top 2800) $activity
            if ($current.Page -eq $layout.Page -and $current.ProcessId -eq $layout.ProcessId) {
                $center = Get-PlayerCenter $current
                $remaining = 350 - [int]$tapGap.ElapsedMilliseconds
                if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
                Send-PlayerInput @('tap',[string]$center.X,[string]$center.Y)
            }
        }
    }
} finally {
    foreach ($command in $commands) {
        try { if (-not $command.HasExited) { $command.Kill() } } catch {}
        $command.Dispose()
    }
}
