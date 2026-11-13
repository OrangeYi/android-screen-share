param(
    [Parameter(Mandatory=$true)][string]$AdbPath,
    [Parameter(Mandatory=$true)][string]$Serial,
    [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$DisplayId,
    [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$PlayerPid,
    [switch]$RequireFocus,
    [switch]$AlignAfterScroll,
    [switch]$CheckAdPage,
    [string]$SwipeAdPage
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
    if (-not $command.Process.WaitForExit($remaining)) { throw 'Android playback query timed out.' }
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
    $offsetLimit = if ($AllowOffset) { [int]([Math]::Min($width,$height) * 0.15) } else { 0 }
    # The selected episode fills the viewport, with only a small offset after wheel scrolling.
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

function Get-PlayerCenter([psobject]$layout) {
    $x = [int]($layout.Width / 2); $y = [int]($layout.Height / 2)
    if (@($layout.Nodes | Where-Object {
        $_.Visible -and $_.Clickable -and $_.Id -ne 'dd' -and
        $_.X -le $x -and ($_.X+$_.W) -gt $x -and
        $_.Y -le $y -and ($_.Y+$_.H) -gt $y
    }).Count) { throw 'A different control occupies the center of the player.' }
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
    $center = Get-PlayerCenter $layout
    $shortSide = [Math]::Min($layout.Width,$layout.Height)
    # Move opposite the offset and allow for Android's initial touch slop.
    # A slow release lets the pager settle on this episode.
    $distance = [Math]::Abs($layout.OffsetY) + [int]($shortSide * 0.035)
    $endY = $center.Y - [Math]::Sign($layout.OffsetY) * $distance
    $duration = [int][Math]::Max(420, $distance * 1000 / ($shortSide * 0.07))
    return @('swipe', [string]$center.X, [string]$center.Y, [string]$center.X, [string]$endY, [string]$duration)
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
    $activities = Start-PlaybackAdb @('dumpsys','activity','activities')
    if (-not $AlignAfterScroll -and -not $CheckAdPage -and -not $SwipeAdPage) {
        $audio = Start-PlaybackAdb @('dumpsys','audio')
    }
    $queryTimeout = if ($CheckAdPage) { 650 } else { 2200 }
    $activity = Get-HongguoActivity (Read-PlaybackAdb $activities $queryTimeout)
    $top = Start-PlaybackAdb @('dumpsys','activity',$activity.Record)
    if ($CheckAdPage) { return Read-HongguoLayout (Read-PlaybackAdb $top $queryTimeout) $activity -CheckAdPage }
    if ($SwipeAdPage) {
        $card = Read-HongguoLayout (Read-PlaybackAdb $top 1800) $activity -CheckAdPage
        if ($card -and $card.Key -ceq $SwipeAdPage) {
            $x = [string][int]($card.Width * 0.5)
            $start = [string][int]($card.Height * 0.75)
            $end = [string][int]($card.Height * 0.25)
            Send-PlayerInput @('swipe',$x,$start,$x,$end,'300')
            return $true
        }
        return
    }
    $layout = Read-HongguoLayout (Read-PlaybackAdb $top 2800) $activity -AllowOffset:$AlignAfterScroll
    if ($AlignAfterScroll) {
        $swipe = Get-HongguoAlignmentSwipe $layout
        if (-not $swipe) { return }
        # The wheel animation may still be settling. Recheck the page and offset before dragging.
        $active = Start-PlaybackAdb @('dumpsys','activity','activities')
        $top = Start-PlaybackAdb @('dumpsys','activity',$activity.Record)
        if ((Get-HongguoActivity (Read-PlaybackAdb $active 2200)).Record -ne $activity.Record) { return }
        $current = Read-HongguoLayout (Read-PlaybackAdb $top 2800) $activity -AllowOffset
        if ($current.Page -ne $layout.Page -or $current.OffsetY -ne $layout.OffsetY -or
            $current.Width -ne $layout.Width -or $current.Height -ne $layout.Height) { return }
        $checkedSwipe = Get-HongguoAlignmentSwipe $current
        Send-PlayerInput $checkedSwipe (1700 + [int]$checkedSwipe[-1])
        Start-Sleep -Milliseconds 350
        $top = Start-PlaybackAdb @('dumpsys','activity',$activity.Record)
        $aligned = Read-HongguoLayout (Read-PlaybackAdb $top 2800) $activity -AllowOffset
        if ($aligned.Page -eq $layout.Page -and [Math]::Abs($aligned.OffsetY) -le 2) { return $true }
        return
    }
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
