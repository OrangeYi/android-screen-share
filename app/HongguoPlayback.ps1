param(
    [Parameter(Mandatory=$true)][string]$AdbPath,
    [Parameter(Mandatory=$true)][string]$Serial,
    [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$DisplayId,
    [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$PlayerPid,
    [switch]$RequireFocus
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($Serial -match '["\r\n]' -or $Serial -match '\\$') { throw 'Invalid ADB identifier' }
$device = @('-s', ('"' + $Serial + '"'))
$activity = 'com.phoenix.read/com.dragon.read.component.shortvideo.impl.fullscreen.ShortSeriesLandActivity'

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
    $targets = @(foreach ($line in ($dump -split '\r?\n')) {
        if ($line -match '^\s*Display #(\d+)\s+\(activities') { $display = [int]$Matches[1] }
        elseif ($line -match '^\s*mResumedActivity:.*\scom\.phoenix\.read/') {
            if ($display -eq $DisplayId -and
                $line -match ('ActivityRecord\{([0-9a-f]+)\s+u\d+\s+' + [regex]::Escape($activity) + ' ')) {
                $Matches[1]
            } else { '' }
        }
    })
    if ($targets.Count -ne 1 -or -not $targets[0]) {
        throw 'The supported Hongguo player is not the only active Hongguo window on the target display.'
    }
    return $targets[0]
}

function Read-HongguoLayout([string]$dump, [string]$activityRecord) {
    $nodes = New-Object 'Collections.Generic.List[object]'
    $stack = New-Object Collections.ArrayList
    $active = $false
    $viewTree = $false
    $appProcessId = ''
    $activityPattern = '^\s*ACTIVITY ' + [regex]::Escape($activity) + ' ' + $activityRecord + '\s+pid=(\d+)\b'
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
        $page = ''; $inPager = $id -eq 'f7_'
        if ($parent) {
            $x += $parent.X; $y += $parent.Y
            $visible = $visible -and $parent.Visible
            $page = $parent.Page
            $inPager = $inPager -or $parent.InPager
        }
        if ($id -eq 'e54' -and $class -match '\.SingleTouchFrameLayout$' -and $inPager) { $page = $key }
        $node = [pscustomobject]@{
            Indent=$indent; Class=$class; Key=$key; Id=$id; X=$x; Y=$y; W=$w; H=$h
            Page=$page; InPager=$inPager; Visible=$visible; Clickable=($flags.Length -gt 6 -and $flags[6] -eq 'C')
            ParentKey=$(if ($parent) { $parent.Key } else { '' })
        }
        $nodes.Add($node)
        [void]$stack.Add($node)
    }
    $pager = @($nodes | Where-Object { $_.Id -eq 'f7_' -and $_.Visible -and $_.X -eq 0 -and $_.Y -eq 0 })
    if ($pager.Count -ne 1 -or $pager[0].W -le $pager[0].H -or $pager[0].H -lt 360) { throw 'Unrecognized landscape player.' }
    $width=$pager[0].W; $height=$pager[0].H
    # Adjacent preloaded episodes have bounds above or below this viewport.
    $pages=@($nodes | Where-Object {
        $_.Id -eq 'e54' -and $_.Page -eq $_.Key -and $_.Visible -and
        $_.X -eq 0 -and $_.Y -eq 0 -and $_.W -eq $width -and $_.H -eq $height
    })
    if ($pages.Count -ne 1) { throw 'The current episode could not be identified.' }
    $pageNodes=@($nodes | Where-Object Page -eq $pages[0].Key)
    if (-not @($pageNodes | Where-Object Id -eq 'hxk').Count) { throw 'Unrecognized episode layout.' }
    if (@($pageNodes | Where-Object {
        $_.Id -eq 'aqv' -and $_.Class -match '\.ShortSeriesScaleImageView$'
    }).Count -ne 1) { throw 'The standard episode player could not be confirmed.' }
    return [pscustomobject]@{ Page=$pages[0].Key; Nodes=$pageNodes; Width=$width; Height=$height; ProcessId=$appProcessId }
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

function Send-PlayerTap([int]$x,[int]$y) {
    $owner = Get-Process -Id $PlayerPid -ErrorAction SilentlyContinue
    if (-not $owner -or $owner.ProcessName -ne 'scrcpy') { throw 'The sharing process has closed.' }
    if ($RequireFocus -and -not [AndroidScreenShare.FocusedSpaceHotkey]::HasFocus($PlayerPid)) {
        throw 'The sharing window lost focus.'
    }
    $tap = Start-PlaybackAdb @('input','-d',[string]$DisplayId,'tap',[string]$x,[string]$y)
    $result = Read-PlaybackAdb $tap 1800
    if ($result -match '(?i)error:|exception|denied') { throw 'Android rejected the targeted input.' }
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
    # Read the active display, view hierarchy and playback state concurrently.
    $top = Start-PlaybackAdb @('dumpsys','activity','top')
    $activities = Start-PlaybackAdb @('dumpsys','activity','activities')
    $audio = Start-PlaybackAdb @('dumpsys','audio')
    $record = Get-HongguoActivity (Read-PlaybackAdb $activities 2200)
    $layout = Read-HongguoLayout (Read-PlaybackAdb $top 3200) $record
    $center = Get-PlayerCenter $layout
    $before = Read-HongguoAudioState $audio $layout.ProcessId
    Send-PlayerTap $center.X $center.Y
    # One center tap can reveal the controls without changing playback.
    # Check the real state before a second tap; do not send a double-click.
    if ($before -ne 'unknown') {
        $tapGap = [Diagnostics.Stopwatch]::StartNew()
        # Read the new layout while the app settles after the first tap.
        $top = Start-PlaybackAdb @('dumpsys','activity','top')
        $activities = Start-PlaybackAdb @('dumpsys','activity','activities')
        $settle = 180 - [int]$tapGap.ElapsedMilliseconds
        if ($settle -gt 0) { Start-Sleep -Milliseconds $settle }
        $audio = Start-PlaybackAdb @('dumpsys','audio')
        if ((Read-HongguoAudioState $audio $layout.ProcessId) -eq $before -and
            (Get-HongguoActivity (Read-PlaybackAdb $activities 2200)) -eq $record) {
            $current = Read-HongguoLayout (Read-PlaybackAdb $top 3200) $record
            if ($current.Page -eq $layout.Page -and $current.ProcessId -eq $layout.ProcessId) {
                $center = Get-PlayerCenter $current
                $remaining = 350 - [int]$tapGap.ElapsedMilliseconds
                if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
                Send-PlayerTap $center.X $center.Y
            }
        }
    }
} finally {
    foreach ($command in $commands) {
        try { if (-not $command.HasExited) { $command.Kill() } } catch {}
        $command.Dispose()
    }
}
