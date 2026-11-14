$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Load only the worker functions so the cases send no real ADB or wheel input.
$scriptPath = Join-Path $PSScriptRoot '..\app\HongguoPlayback.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors -join '; ') }
. ([scriptblock]::Create(($ast.EndBlock.Statements |
    Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] } |
    ForEach-Object { $_.Extent.Text }) -join "`n"))

function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
$activity = [pscustomobject]@{
    Record='a1'; Component='com.phoenix.read/com.dragon.read.component.shortvideo.impl.fullscreen.ShortSeriesLandActivity'
}
$DisplayId = 14
$VideoWidth = 2560; $VideoHeight = 1440; $PlayerPid = 1
$NextSwipe = @(1280,1080,1280,360,300)

function New-LandscapeDump([int]$offset, [string]$page = 'e64') {
    @"
ACTIVITY $($activity.Component) a1 pid=100
  View Hierarchy:
    com.example.DecorView{1 V........ ........ 0,0-2560,1440}
      androidx.viewpager2.widget.ViewPager2{2 V.E...... ........ 0,0-2560,1440 app:id/f7_}
        androidx.viewpager2.widget.ViewPager2`$k{3 VFED..... ......I. 0,0-2560,1440}
          n43.s{6ce V.E...... ......I. 0,$($offset-1440)-2560,$offset}
            com.bytedance.ies.android.loki_lynx.d{4 V.E...... ........ 0,0-2559,1439}
          com.example.SingleTouchFrameLayout{$page V.E...... ......I. 0,$offset-2560,$($offset+1440) app:id/e54}
            com.example.FrameLayout{5 V.E...... ........ 0,0-2560,1440 app:id/hxk}
            um4.b{9 V.E...C.. ........ 0,0-2560,1440}
              com.example.ShortSeriesScaleImageView{6 V.E...... ........ 0,0-2560,1440 app:id/aqv}
          com.example.SingleTouchFrameLayout{b67 V.E...... ......I. 0,$($offset+1440)-2560,$($offset+2880) app:id/e54}
            com.example.FrameLayout{7 V.E...... ........ 0,0-2560,1440 app:id/hxk}
            com.example.ShortSeriesScaleImageView{8 V.E...... ........ 0,0-2560,1440 app:id/aqv}
"@
}

function Start-Sleep([int]$Milliseconds) {}
function Start-PlaybackAdb([string[]]$Arguments) { @{ Query=$Arguments[-1] } }
function Read-PlaybackAdb([hashtable]$command, [int]$timeoutMs) {
    if ($command.Query -eq 'activities') {
        return "Display #14 (activities from top to bottom):`n mResumedActivity: ActivityRecord{a1 u0 $($script:activity.Component) t1}"
    }
    if ($script:snapshots.Count -eq 0) { throw 'Unexpected extra player query' }
    $snapshot = $script:snapshots.Dequeue()
    if ($snapshot -eq '<timeout>') { throw 'Android playback query timed out.' }
    $snapshot
}
function Send-HongguoWheelDown { [void]$script:inputEvents.Add('wheel'); return $true }
function Send-PlayerInput([string[]]$gesture, [int]$timeoutMs) { [void]$script:inputEvents.Add($gesture -join ' ') }
function Get-HongguoAdCountdown([int]$playerProcessId, [int]$width, [int]$height, [switch]$KnownAd) {
    $script:ocrCalls++
    $script:countdown
}

function Reset-PlaybackTest([string[]]$snapshots, [int]$countdown) {
    $script:inputEvents = [Collections.Generic.List[string]]::new()
    $script:snapshots = [Collections.Generic.Queue[string]]::new()
    foreach ($snapshot in $snapshots) { $script:snapshots.Enqueue($snapshot) }
    $script:ocrCalls = 0
    $script:countdown = $countdown
}

$ad = New-LandscapeDump 1440
$mostlyAd = New-LandscapeDump 950
$split = New-LandscapeDump 600
$full = New-LandscapeDump 0

# This is the geometry of the reported incident: the ad remains at the top,
# and the next episode starts 600 px into a 1440 px viewport.
Reset-PlaybackTest @($ad, $mostlyAd, $split, $split, $full) 8
$messages = @(Invoke-HongguoNextEpisode)
Assert (($messages -join ' ') -eq 'adScrollSent adScrollAligned') 'Timed ad did not confirm the original episode was aligned'
Assert (($inputEvents -join ';') -eq 'wheel;wheel;swipe 1280 1020 1280 388 700') 'Timed ad kept scrolling into the episode or adjusted the wrong distance'

Reset-PlaybackTest @($ad, $ad, $split, $split, $full) 0
$messages = @(Invoke-HongguoNextEpisode)
Assert (($messages -join ' ') -eq 'adWheelFallback adScrollAligned') 'Swipe fallback did not recover the same split screen'
Assert ($inputEvents.Count -eq 3 -and $inputEvents[1] -eq 'wheel') 'Swipe fallback used extra input'

# After the first wheel, the view can still be rebuilding. A failed or
# incomplete snapshot must not leave the user needing another keypress.
$rebuilding = $split -replace 'app:id/aqv','app:id/placeholder'
Reset-PlaybackTest @($ad, $ad, '<timeout>', $rebuilding, '<timeout>', $split, $split, $full) 0
$messages = @(Invoke-HongguoNextEpisode)
Assert (($messages -join ' ') -eq 'adWheelFallback adScrollAligned') 'A transient missing player view required a second keypress'
Assert (($inputEvents -join ';') -eq 'swipe 1280 1080 1280 360 300;wheel;swipe 1280 1020 1280 388 700') 'Recovery issued more wheel events after the ad moved away'

$reboundPage = New-LandscapeDump 600 'abc'
$reboundFull = New-LandscapeDump 0 'abc'
Reset-PlaybackTest @($ad, $split, $reboundPage, $reboundPage, '<timeout>', $reboundFull) 8
$messages = @(Invoke-HongguoNextEpisode)
Assert (($messages -join ' ') -eq 'adScrollSent adScrollAligned') 'A rebound episode view was not recovered after the timed ad'
Assert ($inputEvents.Count -eq 2 -and $inputEvents[0] -eq 'wheel') 'The rebound episode received extra input'

Reset-PlaybackTest @($ad, $split, $split, $split, $split, $full) 8
$messages = @(Invoke-HongguoNextEpisode)
Assert ($messages -contains 'adScrollAligned' -and $inputEvents.Count -eq 3) 'A drag that did not take effect was not retried on the same episode'

Reset-PlaybackTest @($split, $split, $full) 8
$messages = @(Invoke-HongguoNextEpisode)
Assert ($messages -contains 'adScrollAligned' -and $ocrCalls -eq 0 -and $inputEvents.Count -eq 1) 'Retry on a split screen changed episodes or waited for OCR'

Reset-PlaybackTest @($split, (New-LandscapeDump 220), $full) 0
$messages = @(Invoke-HongguoNextEpisode)
Assert ($messages -contains 'adScrollAligned' -and $inputEvents.Count -eq 0) 'An episode already snapping into place received extra input'

Reset-PlaybackTest @($split, (New-LandscapeDump 600 'abc')) 0
$messages = @(Invoke-HongguoNextEpisode)
Assert ($messages -contains 'adAlignIncomplete' -and $inputEvents.Count -eq 0) 'A page that changed during the check received stale input'

Reset-PlaybackTest @($ad, $full) 0
$messages = @(Invoke-HongguoNextEpisode)
Assert (($messages -join ' ') -eq 'adSwipeSent' -and $inputEvents.Count -eq 1) 'An untimed ad that swiped away was sent extra input'

Reset-PlaybackTest (@($ad) * 9) 8
$messages = @(Invoke-HongguoNextEpisode)
Assert ($messages -contains 'adWheelIncomplete' -and $inputEvents.Count -eq 8) 'Persistent ad exceeded the wheel limit or reported success'

Reset-PlaybackTest @($full) 0
$messages = @(Invoke-HongguoNextEpisode)
Assert (($messages -join ' ') -eq 'hongguoNextSent' -and $inputEvents.Count -eq 1) 'A normal episode did not advance with one swipe'

$negativeOffset = Read-HongguoLayout (New-LandscapeDump -600) $activity -AllowOffset
$adjust = @(Get-HongguoAlignmentSwipe $negativeOffset)
Assert ([int]$adjust[2] -lt [int]$adjust[4] -and [int]$adjust[4] -lt 1440) 'An episode offset toward the top did not adjust down within its display'

$withButton = $split -replace ' {12}um4.b\{9', ('            com.example.Button{a4 V.E...C.. ........ 1200,350-1450,600}' + "`n" + '            um4.b{9')
Reset-PlaybackTest @($withButton, $withButton) 0
$blocked = $false
try { Invoke-HongguoNextEpisode } catch { $blocked = $_.Exception.Message -like 'A different control*' }
Assert ($blocked -and $inputEvents.Count -eq 0) 'Recovery touched a clickable control over the video'

'PASS: ad recovery through timeouts, view rebuilds and missed drags, split-screen retry, wheel limit, and normal navigation'
