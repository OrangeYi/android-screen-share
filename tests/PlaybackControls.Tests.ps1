$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $PSScriptRoot '..\app\DesktopIntegration.cs') -ReferencedAssemblies @(
    'System.dll', 'System.Core.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll')
. (Join-Path $PSScriptRoot '..\app\PlaybackControls.ps1')
. (Join-Path $PSScriptRoot '..\app\IndependentApps.ps1')
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Get-Text([string]$key, [object[]]$values) { $key }

Assert ((Get-PlaybackPreset 'movie').Video -eq 150) 'Movie mode lost jitter buffering'
Assert ((Get-PlaybackPreset 'control').Video -eq 0) 'Control mode acquired latency'
$session = [pscustomobject]@{
    Mode='desktop'; Serial='DESKTOP_DEVICE'; DisplayId=7; Sdk=36
    InputWidth=2560; InputHeight=1440; TextureWidth=1920; TextureHeight=1080
    Process=[pscustomobject]@{HasExited=$false}
}
$arguments = Get-GestureArguments $session 'next'
Assert (($arguments -join ' ') -eq '-s DESKTOP_DEVICE shell input -d 7 swipe 1280 1080 1280 360 300') 'Desktop swipe used the wrong device, display or scale'
$session.DisplayId = $null
$blocked = $false
try { Get-GestureArguments $session 'next' | Out-Null } catch { $blocked = $true }
Assert $blocked 'Unknown virtual display fell back to the phone screen'
$session.DisplayId = 7; $session.Sdk = 28
$blocked = $false
try { Get-GestureArguments $session 'next' | Out-Null } catch { $blocked = $true }
Assert $blocked 'Legacy Android silently targeted the wrong display'

$mirror = [pscustomobject]@{
    Mode='mirror'; Serial='MIRROR_DEVICE'; DisplayId=0; Sdk=28
    InputWidth=1080; InputHeight=2400; TextureWidth=1920; TextureHeight=864
    Process=[pscustomobject]@{HasExited=$false}
}
$arguments = Get-GestureArguments $mirror 'next'
Assert (($arguments -join ' ') -eq '-s MIRROR_DEVICE shell input swipe 1200 810 1200 270 300') 'Rotated legacy primary screen dimensions were incorrect'
$script:modeCombo = [pscustomobject]@{SelectedIndex=0}
$script:sessions = @{mirror=$mirror; desktop=$session}
Assert ((Get-ControlSession).Serial -eq 'MIRROR_DEVICE') 'Mirror controls targeted another session'
$script:modeCombo.SelectedIndex=1
Assert ((Get-ControlSession).Serial -eq 'DESKTOP_DEVICE') 'Desktop controls targeted the mirror'
$script:sessions.Remove('desktop')
$blocked=$false
try { Get-ControlSession | Out-Null } catch { $blocked=$true }
Assert $blocked 'Missing selected session silently targeted another session'

$script:modeCombo.SelectedIndex=2
$session.Mode='app'; $session.DisplayId=11; $session.Sdk=31
$script:sessions.app=$session
Assert ((Get-ControlSession).DisplayId -eq 11) 'App controls did not select their own display'
Assert (((Get-GestureArguments $session 'next') -join ' ') -match '-d 11 swipe') 'App gesture did not target the app display'
$session.InputWidth = 1440; $session.InputHeight = 2560
$arguments = Get-GestureArguments $session 'next'
Assert (($arguments -join ' ') -eq '-s DESKTOP_DEVICE shell input -d 11 swipe 1280 1080 1280 360 300') 'App swipe kept portrait coordinates after the video rotated'
$session.DisplayId=0
$blocked=$false
try { Get-GestureArguments $session 'next' | Out-Null } catch { $blocked=$true }
Assert $blocked 'App gesture incorrectly accepted display zero'

$portrait=Get-IndependentAppDisplay '1080p' $false
$landscape=Get-IndependentAppDisplay '1440p' $true
Assert ($portrait.Spec -eq '1080x1920/320' -and $landscape.Spec -eq '2560x1440/420') 'App window orientation or resolution was lost'
$apps=@(ConvertFrom-ScrcpyAppList @(' [server] INFO: List of apps:', ' - Example App    org.example.player', ' * Settings     com.android.settings', ' - Example App    org.example.player'))
Assert ($apps.Count -eq 2 -and $apps.Package -contains 'org.example.player') 'Launchable apps were not extracted or deduplicated'
Assert (-not (Test-AndroidAppPackage '+org.example.player')) 'App package permitted a force-stop prefix'
Assert ((Get-ScrcpyCreatedDisplayId '[server] INFO: New display: 1080x1920/320 (id=11)') -eq 11) 'New display id was not identified from its own process'
$appDump="Display #0 (activities from top to bottom):`n  mResumedActivity: ActivityRecord{a u0 org.example.player/.Main t1}`nDisplay #11 (activities from top to bottom):`n  mResumedActivity: ActivityRecord{b u0 com.android.settings/.Settings t2}"
Assert (-not (Test-AppOnDisplay $appDump 11 'org.example.player')) 'An app on the phone was mistaken for an app on the virtual screen'
Assert (Test-AppOnDisplay $appDump 11 'com.android.settings') 'App on the virtual display was not detected'

$dump = 'DisplayInfo{"phone", displayId 0, real 1080 x 2400, rotation 0}' + "`n" +
    'DisplayInfo{"scrcpy", displayId 7, real 2560 x 1440, rotation 0}'
$size = Get-DisplayInputSize $dump 7
Assert ($size.Width -eq 2560 -and $size.Height -eq 1440) 'Display dimensions came from another display'
Assert ($null -eq (Get-DisplayInputSize $dump 3)) 'Missing display returned unrelated dimensions'
$rotatedDump = 'mBaseDisplayInfo=DisplayInfo{"scrcpy", displayId 11, real 1440 x 2560, rotation 0}' + "`n" +
    'mOverrideDisplayInfo=DisplayInfo{"scrcpy", displayId 11, real 2560 x 1440, rotation 1}'
$size = Get-DisplayInputSize $rotatedDump 11
Assert ($size.Width -eq 2560 -and $size.Height -eq 1440) 'Display lookup ignored the rotation override'

# Restore on the cursor monitor and clamp layouts after a monitor is unplugged.
$script:rememberWindowCheck=[pscustomobject]@{Checked=$true}
$script:windowLayouts=@{'mirror.normal'=[pscustomobject]@{OffsetX=100000;OffsetY=-10000;Width=100000;Height=100000}}
$area=[Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
$placement=Get-ShareWindowPlacement 'mirror' $false
Assert ($placement.X -ge $area.Left -and $placement.Y -ge $area.Top) 'Window restored off the cursor monitor'
Assert ($placement.X + $placement.Width -le $area.Right -and $placement.Y + $placement.Height -le $area.Bottom) 'Oversized saved layout was not clamped'

# Exercise real asynchronous stdout/stderr capture without a phone or app input.
$program="[Console]::WriteLine('INFO: Texture: 1080x2400'); [Console]::WriteLine('INFO: 42 fps (+3 skipped)'); [Console]::Error.WriteLine('WARN: test decoder message')"
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program))
$exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$capture=[AndroidScreenShare.CapturedProcess]::new($exe, [string[]]@('-NoProfile','-EncodedCommand',$encoded), $PSScriptRoot)
try {
    Assert ($capture.Process.WaitForExit(5000)) 'Output capture hung'
    $capture.Process.WaitForExit()
    $script:capturedLogs=New-Object Collections.ArrayList
    function Add-Log([string]$message) { [void]$script:capturedLogs.Add($message) }
    function Write-RunLog([string]$message) { [void]$script:capturedLogs.Add($message) }
    $outputSession=[pscustomobject]@{Capture=$capture;Mode='mirror';ActualFps=$null;LastFpsAt=[DateTime]::MinValue;TextureWidth=0;TextureHeight=0}
    Update-ShareProcessLog $outputSession
    Assert ($outputSession.ActualFps -eq '42') 'Actual FPS was not parsed'
    Assert ($outputSession.TextureWidth -eq 1080 -and $outputSession.TextureHeight -eq 2400) 'Texture orientation was not captured'
    Assert (($script:capturedLogs -join '|') -match 'test decoder message') 'stderr diagnostics were lost'
    Assert ([AndroidScreenShare.CapturedProcess]::Quote('C:\with spaces\') -eq '"C:\with spaces\\"') 'Trailing-backslash argument escaping failed'
} finally { $capture.Dispose() }
Write-Output 'PASS: presets, display-specific swipes, app enumeration and placement, rotation, legacy Android, session routing, layout recovery, real FPS and stderr capture'
