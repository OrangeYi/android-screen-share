param(
    [string]$AutoStartMode = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('AndroidScreenShare.CapturedProcess' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'DesktopIntegration.cs') -ReferencedAssemblies @(
        'System.dll', 'System.Core.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll')
}

$script:root = Split-Path $PSScriptRoot -Parent
$localePath = Join-Path $script:root 'locales\zh-CN.json'
$script:T = ([IO.File]::ReadAllText($localePath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
$script:scrcpyDir = Join-Path $script:root 'tools\scrcpy'
$script:adbPath = Join-Path $script:scrcpyDir 'adb.exe'
$script:scrcpyPath = Join-Path $script:scrcpyDir 'scrcpy.exe'
# scrcpy honors the ADB environment variable before searching PATH/current
# directory. Override stale or malformed system/user values so that both this
# app and scrcpy always use the adb.exe downloaded alongside scrcpy.
$env:ADB = $script:adbPath
$script:versionPath = Join-Path $script:root 'VERSION'
$script:updateScript = Join-Path $script:root 'Update.ps1'
$script:settingsPath = Join-Path $script:root 'data\settings.json'
$script:currentVersion = if (Test-Path -LiteralPath $script:versionPath) {
    ([IO.File]::ReadAllText($script:versionPath, [Text.Encoding]::UTF8)).Trim()
} else {
    '0.0.0'
}
$script:lastDeviceSerial = ''
$script:lastDeviceIdentity = ''
$script:refreshingDevices = $false
. (Join-Path $PSScriptRoot 'WirelessDiscovery.ps1')
$script:companionApk = Join-Path $script:root 'assets\companion.apk'
$script:companionPackage = 'dev.androidscreenshare.companion'
$script:companionVersionCode = 2
$script:sessions = @{}
$script:logBox = $null
$script:deviceCombo = $null
$script:modeCombo = $null
$script:resolutionCombo = $null
$script:fpsCombo = $null
$script:bitrateCombo = $null
$script:audioCheck = $null
$script:screenOffCheck = $null
$script:addressBox = $null
$script:pairCodeBox = $null
$script:loadingSettings = $true
$script:applyingPreset = $false
$script:windowLayouts = @{}
$script:runLogPath = $null
$script:hotkeys = $null
$script:appListProbe = $null
$script:spacePlaybackHook = $null
$script:spacePlaybackCheck = $null
$script:playbackWorker = $null
$script:playbackInvocation = $null

function Get-Text([string]$key, [object[]]$values = @()) {
    $value = [string]$script:T.$key
    if ($values.Count -gt 0) {
        return [string]::Format($value, $values)
    }
    return $value
}

function Add-Log([string]$message) {
    Write-RunLog $message
    if (-not $script:logBox) { return }
    if ($script:logBox.TextLength -gt 100000) {
        $script:logBox.Text = $script:logBox.Text.Substring($script:logBox.TextLength - 60000)
    }
    $timestamp = (Get-Date).ToString('HH:mm:ss')
    $script:logBox.AppendText("[$timestamp] $message`r`n")
    $script:logBox.SelectionStart = $script:logBox.TextLength
    $script:logBox.ScrollToCaret()
}

. (Join-Path $PSScriptRoot 'SessionDiagnostics.ps1')
. (Join-Path $PSScriptRoot 'IndependentApps.ps1')
. (Join-Path $PSScriptRoot 'PlaybackControls.ps1')
. (Join-Path $PSScriptRoot 'ShareSessions.ps1')

function Invoke-Adb(
    [string]$serial,
    [string[]]$adbArguments,
    [switch]$allowFailure
) {
    $arguments = @()
    if ($serial) {
        $arguments += @('-s', $serial)
    }
    $arguments += $adbArguments

    # Windows PowerShell converts native stderr into ErrorRecord objects. With
    # ErrorActionPreference=Stop, harmless ADB startup messages such as
    # "daemon not running" would otherwise abort pairing before ADB is ready.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $script:adbPath @arguments 2>&1 | ForEach-Object {
            [string]$_
        })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if (-not $allowFailure -and $exitCode -ne 0) {
        throw (($output -join "`r`n").Trim())
    }
    return $output
}

function Get-SelectedSerial {
    $selected = $script:deviceCombo.SelectedItem
    if (-not $selected) {
        throw (Get-Text 'selectDevice')
    }
    return [string]$selected.Serial
}

function Refresh-Devices([switch]$ListOnly, [switch]$ForceSearch) {
    if ($script:refreshingDevices) { return }
    $script:refreshingDevices = $true
    try {
        Invoke-Adb '' @('start-server') -allowFailure | Out-Null
        $previous = $script:lastDeviceSerial
        if ($script:deviceCombo.SelectedItem) {
            $previous = [string]$script:deviceCombo.SelectedItem.Serial
            $script:lastDeviceIdentity = [string]$script:deviceCombo.SelectedItem.Identity
        }

        $devices = if ($ListOnly) { @(Get-DiscoveryDevices) } else {
            @(Find-WirelessDevices $previous $script:lastDeviceIdentity $script:addressBox.Text.Trim() -ForceSearch:$ForceSearch)
        }
        $items = @()
        # A wireless device may appear under both its mDNS name and IP endpoint.
        foreach ($group in @($devices | Group-Object Identity)) {
            $device = $group.Group | Sort-Object @{Expression={
                if ($_.Serial -eq $previous) {0} elseif ($_.Serial -match ':|_adb') {1} else {2}
            }} | Select-Object -First 1
            $serial = $device.Serial
            $details = $device.Details
            $model = Get-Text 'androidDevice'
            if ($details -match '\bmodel:(\S+)') {
                $model = $Matches[1].Replace('_', ' ')
            }
            $transport = if ($serial -match ':|_adb') { Get-Text 'wifi' } else { Get-Text 'usb' }
            $items += [pscustomobject]@{
                Serial = $serial
                Identity = $device.Identity
                Label = "$model  [$transport]  $serial"
            }
        }

        $script:deviceCombo.Items.Clear()
        foreach ($item in $items) {
            [void]$script:deviceCombo.Items.Add($item)
        }
        if ($items.Count -gt 0) {
            $index = -1
            if ($previous) {
                for ($i = 0; $i -lt $items.Count; $i++) {
                    if ($items[$i].Serial -eq $previous -or
                        ($script:lastDeviceIdentity -and $items[$i].Identity -eq $script:lastDeviceIdentity)) { $index = $i; break }
                }
            }
            if ($index -lt 0 -and -not $previous) { $index = 0 }
            $script:deviceCombo.SelectedIndex = $index
            if ($index -ge 0) {
                $script:lastDeviceSerial = [string]$items[$index].Serial
                $script:lastDeviceIdentity = [string]$items[$index].Identity
            }
        }
        Add-Log (Get-Text 'foundDevices' @($items.Count))
    } catch {
        Add-Log (Get-Text 'refreshFailed' @($_.Exception.Message))
    } finally {
        $script:refreshingDevices = $false
    }
}


function Get-CursorPlacement {
    $screen = [System.Windows.Forms.Screen]::FromPoint(
        [System.Windows.Forms.Cursor]::Position)
    return [pscustomobject]@{
        X = $screen.WorkingArea.Left + 24
        Y = $screen.WorkingArea.Top + 24
    }
}




function Connect-WirelessAddress {
    try {
        $address = $script:addressBox.Text.Trim()
        if (-not (Test-WirelessEndpoint $address)) {
            throw (Get-Text 'addressExample')
        }
        $result = Invoke-DiscoveryAdb @('connect', $address)
        Add-Log ($result -join ' ')
        Start-Sleep -Milliseconds 500
        Refresh-Devices -ListOnly
        Save-Settings
    } catch {
        Add-Log (Get-Text 'connectFailed' @($_.Exception.Message))
    }
}

function Pair-WirelessAddress {
    try {
        $address = $script:addressBox.Text.Trim()
        $code = $script:pairCodeBox.Text.Trim()
        if (-not $address -or -not $code) {
            throw (Get-Text 'pairRequired')
        }
        $result = Invoke-Adb '' @('pair', $address, $code) -allowFailure
        Add-Log ($result -join ' ')
        if (($result -join ' ') -match 'Successfully paired') {
            $script:pairCodeBox.Clear()
            $script:addressBox.Clear()
        } else { return }
        Refresh-Devices -ForceSearch
        Save-Settings
    } catch {
        Add-Log (Get-Text 'pairFailed' @($_.Exception.Message))
    }
}

function Get-DeviceWifiIpv4Address([string]$serial) {
    # Do not take the first `src` from `ip route`: cellular (rmnet*) and VPN
    # routes can appear before Wi-Fi. Prefer an address assigned directly to a
    # Wi-Fi interface, then use progressively broader Android fallbacks.
    $addressLines = Invoke-Adb $serial @('shell', '--', 'ip', '-o', '-4', 'addr', 'show') -allowFailure
    foreach ($line in $addressLines) {
        if ($line -match '^\d+:\s+([^\s:@]+)(?:@[^\s:]+)?\s+.*\binet\s+(\d{1,3}(?:\.\d{1,3}){3})/') {
            $interfaceName = $Matches[1]
            $ipAddress = $Matches[2]
            if ($interfaceName -match '^(?:wlan|swlan|wifi)\d+$') {
                return $ipAddress
            }
        }
    }

    $routeLines = Invoke-Adb $serial @('shell', '--', 'ip', '-4', 'route') -allowFailure
    foreach ($line in $routeLines) {
        if ($line -match '\bdev\s+(?:wlan|swlan|wifi)\d+\b' -and
            $line -match '\bsrc\s+(\d{1,3}(?:\.\d{1,3}){3})\b') {
            return $Matches[1]
        }
    }

    $wifiStatus = Invoke-Adb $serial @('shell', '--', 'cmd', 'wifi', 'status') -allowFailure
    foreach ($line in $wifiStatus) {
        if ($line -match '\bIP(?: Address)?:\s*/?(\d{1,3}(?:\.\d{1,3}){3})\b') {
            return $Matches[1]
        }
    }

    throw (Get-Text 'ipNotDetected')
}

function Enable-WirelessFromUsb {
    try {
        $serial = Get-SelectedSerial
        if ($serial -match ':|_adb') {
            throw (Get-Text 'selectUsb')
        }
        $wifiIp = Get-DeviceWifiIpv4Address $serial
        $address = "${wifiIp}:5555"
        Add-Log (Get-Text 'wifiAddressDetected' @($wifiIp))
        Invoke-Adb $serial @('tcpip', '5555') | Out-Null
        Start-Sleep -Milliseconds 1500
        $result = Invoke-Adb '' @('connect', $address)
        $script:addressBox.Text = $address
        Add-Log ($result -join ' ')
        $script:lastDeviceSerial = $address
        Refresh-Devices -ListOnly
        Save-Settings
    } catch {
        Add-Log (Get-Text 'usbWifiFailed' @($_.Exception.Message))
    }
}

function Set-ComboSelection($combo, [string]$value) {
    if (-not $value) { return }
    for ($i = 0; $i -lt $combo.Items.Count; $i++) {
        if ([string]$combo.Items[$i] -eq $value) {
            $combo.SelectedIndex = $i
            return
        }
    }
}

function Save-InputDiagnostics {
    try {
        $serial = Get-SelectedSerial
        $directory = Join-Path $script:root 'data\diagnostics'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $path = Join-Path $directory (('input-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff')))
        $sections = @("Android Screen Share $($script:currentVersion)", "Captured: $(Get-Date -Format o)")
        foreach ($service in @('input', 'display', 'window', 'desktopmode')) {
            $sections += "`r`n=== dumpsys $service ==="
            $sections += Invoke-DiscoveryAdb @('-s', $serial, 'shell', 'dumpsys', $service) 6000
        }
        [IO.File]::WriteAllText($path, ($sections -join "`r`n"), [Text.UTF8Encoding]::new($false))
        Add-Log (Get-Text 'inputDiagnosticsSaved' @($path))
    } catch { Add-Log (Get-Text 'inputDiagnosticsFailed' @($_.Exception.Message)) }
}

function Load-Settings {
    if (-not (Test-Path -LiteralPath $script:settingsPath -PathType Leaf)) { return }
    try {
        $settings = ([IO.File]::ReadAllText($script:settingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
        $propertyNames = @($settings.PSObject.Properties.Name)
        if ('deviceSerial' -in $propertyNames) { $script:lastDeviceSerial = [string]$settings.deviceSerial }
        if ('deviceIdentity' -in $propertyNames) { $script:lastDeviceIdentity = [string]$settings.deviceIdentity }
        if ('address' -in $propertyNames -and [string]$settings.address -match '^\d{1,3}(?:\.\d{1,3}){3}:\d+$') {
            $script:addressBox.Text = [string]$settings.address
        }
        if ('mode' -in $propertyNames -and $settings.mode -in @('mirror', 'desktop', 'app')) {
            $script:modeCombo.SelectedIndex = [Array]::IndexOf(@('mirror', 'desktop', 'app'), [string]$settings.mode)
        }
        if ('appPackage' -in $propertyNames) { Set-IndependentAppSelection ([string]$settings.appPackage) }
        if ('appLandscape' -in $propertyNames -and $settings.appLandscape -eq $true) { $script:appOrientationCombo.SelectedIndex = 1 }
        if ('appScreenOff' -in $propertyNames) { $script:appScreenOffCheck.Checked = $settings.appScreenOff -eq $true }
        if ('appSpacePlayback' -in $propertyNames) { $script:spacePlaybackCheck.Checked = $settings.appSpacePlayback -eq $true }
        if ('resolution' -in $propertyNames) { Set-ComboSelection $script:resolutionCombo ([string]$settings.resolution) }
        if ('fps' -in $propertyNames) { Set-ComboSelection $script:fpsCombo ([string]$settings.fps) }
        if ('bitrate' -in $propertyNames) { Set-ComboSelection $script:bitrateCombo ([string]$settings.bitrate) }
        if ('audio' -in $propertyNames) { $script:audioCheck.Checked = [bool]$settings.audio }
        if ('screenOff' -in $propertyNames) { $script:screenOffCheck.Checked = [bool]$settings.screenOff }
        if ('playbackPreset' -in $propertyNames -and $settings.playbackPreset -in @('control', 'movie', 'custom')) {
            $script:presetCombo.SelectedIndex = [Array]::IndexOf(@('control', 'movie', 'custom'), [string]$settings.playbackPreset)
        }
        if ('videoBuffer' -in $propertyNames) { $script:bufferInput.Value = [Math]::Max(0, [Math]::Min(1000, [int]$settings.videoBuffer)) }
        if ('topmost' -in $propertyNames) { $script:topmostCheck.Checked = [bool]$settings.topmost }
        if ('mini' -in $propertyNames) { $script:miniCheck.Checked = [bool]$settings.mini }
        if ('rememberWindow' -in $propertyNames) { $script:rememberWindowCheck.Checked = [bool]$settings.rememberWindow }
        if ('hotkeyProfile' -in $propertyNames -and $settings.hotkeyProfile -in @('CtrlAlt', 'CtrlShift', 'Off')) {
            $script:hotkeyCombo.SelectedIndex = [Array]::IndexOf(@('CtrlAlt', 'CtrlShift', 'Off'), [string]$settings.hotkeyProfile)
        }
        if ('windowLayouts' -in $propertyNames -and $settings.windowLayouts) {
            foreach ($item in $settings.windowLayouts.PSObject.Properties) {
                if ($item.Name -match '^(mirror|desktop|app)\.(normal|mini)$') { $script:windowLayouts[$item.Name] = $item.Value }
            }
        }
    } catch {
        Add-Log (Get-Text 'settingsLoadFailed' @($_.Exception.Message))
    }
}

function Save-Settings {
    if ($script:loadingSettings) { return }
    try {
        if ($script:deviceCombo.SelectedItem) {
            $script:lastDeviceSerial = [string]$script:deviceCombo.SelectedItem.Serial
            $script:lastDeviceIdentity = [string]$script:deviceCombo.SelectedItem.Identity
        }
        $settings = [ordered]@{
            deviceSerial = $script:lastDeviceSerial
            deviceIdentity = $script:lastDeviceIdentity
            address = $script:addressBox.Text.Trim()
            mode = Get-SelectedShareMode
            appPackage = if ($script:appCombo.SelectedItem) { [string]$script:appCombo.SelectedItem.Package } else { '' }
            appLandscape = $script:appOrientationCombo.SelectedIndex -eq 1
            appScreenOff = [bool]$script:appScreenOffCheck.Checked
            appSpacePlayback = [bool]$script:spacePlaybackCheck.Checked
            resolution = [string]$script:resolutionCombo.SelectedItem
            fps = [string]$script:fpsCombo.SelectedItem
            bitrate = [string]$script:bitrateCombo.SelectedItem
            audio = [bool]$script:audioCheck.Checked
            screenOff = [bool]$script:screenOffCheck.Checked
            playbackPreset = @('control', 'movie', 'custom')[$script:presetCombo.SelectedIndex]
            videoBuffer = [int]$script:bufferInput.Value
            topmost = [bool]$script:topmostCheck.Checked
            mini = [bool]$script:miniCheck.Checked
            rememberWindow = [bool]$script:rememberWindowCheck.Checked
            hotkeyProfile = @('CtrlAlt', 'CtrlShift', 'Off')[$script:hotkeyCombo.SelectedIndex]
            windowLayouts = $script:windowLayouts
        }
        $settingsDirectory = Split-Path $script:settingsPath -Parent
        New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
        $json = $settings | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($script:settingsPath, $json, [Text.UTF8Encoding]::new($false))
    } catch {
        Add-Log (Get-Text 'settingsSaveFailed' @($_.Exception.Message))
    }
}

function Check-ForUpdate {
    $previousCursor = $form.Cursor
    try {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $updateButton.Enabled = $false
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $cacheBuster = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $versionUrl = "https://raw.githubusercontent.com/OrangeYi/android-screen-share/main/VERSION?t=$cacheBuster"
        $versionResponse = Invoke-WebRequest -UseBasicParsing -Uri $versionUrl
        $remoteVersionText = if ($versionResponse.Content -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString($versionResponse.Content).Trim()
        } else {
            ([string]$versionResponse.Content).Trim()
        }
        $currentVersion = [Version]$script:currentVersion
        $remoteVersion = [Version]$remoteVersionText
        if ($remoteVersion -le $currentVersion) {
            [System.Windows.Forms.MessageBox]::Show(
                (Get-Text 'latestVersion' @($script:currentVersion)),
                (Get-Text 'appTitle')) | Out-Null
            return
        }
        if (-not (Test-Path -LiteralPath $script:updateScript -PathType Leaf)) {
            throw (Get-Text 'updaterMissing')
        }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            (Get-Text 'updatePrompt' @($script:currentVersion, $remoteVersionText)),
            (Get-Text 'updateAvailable'),
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        Save-Settings
        $arguments = '-NoProfile -ExecutionPolicy Bypass -Sta -File "{0}" -InstallRoot "{1}" -NoConfirm -Force -Restart -WaitForProcessId {2}' -f `
            $script:updateScript, $script:root, $PID
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $script:root -WindowStyle Hidden
        $form.Close()
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            (Get-Text 'updateFailed' @($_.Exception.Message)),
            (Get-Text 'updateFailedTitle'),
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } finally {
        if (-not $form.IsDisposed) {
            $form.Cursor = $previousCursor
            $updateButton.Enabled = $true
        }
    }
}

function New-Label([string]$text, [int]$x, [int]$y, [int]$width = 150) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $text
    $label.Location = New-Object Drawing.Point($x, $y)
    $label.Size = New-Object Drawing.Size($width, 24)
    return $label
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "$(Get-Text 'appTitle') v$($script:currentVersion)"
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(760, 850)
$form.MinimumSize = New-Object Drawing.Size(760, 810)
$form.Font = New-Object Drawing.Font('Segoe UI', 9)

$form.Controls.Add((New-Label (Get-Text 'device') 24 24 100))
$script:deviceCombo = New-Object System.Windows.Forms.ComboBox
$script:deviceCombo.Location = New-Object Drawing.Point(130, 20)
$script:deviceCombo.Size = New-Object Drawing.Size(485, 28)
$script:deviceCombo.DropDownStyle = 'DropDownList'
$script:deviceCombo.DisplayMember = 'Label'
$form.Controls.Add($script:deviceCombo)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = Get-Text 'refresh'
$refreshButton.Location = New-Object Drawing.Point(625, 19)
$refreshButton.Size = New-Object Drawing.Size(95, 30)
$refreshButton.Add_Click({ Refresh-Devices -ForceSearch; Save-Settings })
$form.Controls.Add($refreshButton)

$wirelessGroup = New-Object System.Windows.Forms.GroupBox
$wirelessGroup.Text = Get-Text 'wirelessAdb'
$wirelessGroup.Location = New-Object Drawing.Point(20, 65)
$wirelessGroup.Size = New-Object Drawing.Size(700, 125)
$form.Controls.Add($wirelessGroup)

$wirelessGroup.Controls.Add((New-Label (Get-Text 'ipPort') 16 30 80))
$script:addressBox = New-Object System.Windows.Forms.TextBox
$script:addressBox.Location = New-Object Drawing.Point(95, 27)
$script:addressBox.Size = New-Object Drawing.Size(210, 26)
$wirelessGroup.Controls.Add($script:addressBox)

$wirelessGroup.Controls.Add((New-Label (Get-Text 'pairCode') 315 30 70))
$script:pairCodeBox = New-Object System.Windows.Forms.TextBox
$script:pairCodeBox.Location = New-Object Drawing.Point(385, 27)
$script:pairCodeBox.Size = New-Object Drawing.Size(95, 26)
$wirelessGroup.Controls.Add($script:pairCodeBox)

$pairButton = New-Object System.Windows.Forms.Button
$pairButton.Text = Get-Text 'pair'
$pairButton.Location = New-Object Drawing.Point(490, 25)
$pairButton.Size = New-Object Drawing.Size(75, 30)
$pairButton.Add_Click({ Pair-WirelessAddress })
$wirelessGroup.Controls.Add($pairButton)

$connectButton = New-Object System.Windows.Forms.Button
$connectButton.Text = Get-Text 'connect'
$connectButton.Location = New-Object Drawing.Point(575, 25)
$connectButton.Size = New-Object Drawing.Size(85, 30)
$connectButton.Add_Click({ Connect-WirelessAddress })
$wirelessGroup.Controls.Add($connectButton)

$usbWifiButton = New-Object System.Windows.Forms.Button
$usbWifiButton.Text = Get-Text 'enableWifiUsb'
$usbWifiButton.Location = New-Object Drawing.Point(95, 70)
$usbWifiButton.Size = New-Object Drawing.Size(285, 32)
$usbWifiButton.Add_Click({ Enable-WirelessFromUsb })
$wirelessGroup.Controls.Add($usbWifiButton)

$hintLabel = New-Label (Get-Text 'wirelessHint') 390 70 285
$hintLabel.ForeColor = [Drawing.Color]::DimGray
$wirelessGroup.Controls.Add($hintLabel)

$shareGroup = New-Object System.Windows.Forms.GroupBox
$shareGroup.Text = Get-Text 'sharing'
$shareGroup.Location = New-Object Drawing.Point(20, 205)
$shareGroup.Size = New-Object Drawing.Size(700, 190)
$form.Controls.Add($shareGroup)

$shareGroup.Controls.Add((New-Label (Get-Text 'mode') 16 32 90))
$script:modeCombo = New-Object System.Windows.Forms.ComboBox
$script:modeCombo.Location = New-Object Drawing.Point(105, 28)
$script:modeCombo.Size = New-Object Drawing.Size(235, 28)
$script:modeCombo.DropDownStyle = 'DropDownList'
[void]$script:modeCombo.Items.Add((Get-Text 'phoneMirror'))
[void]$script:modeCombo.Items.Add((Get-Text 'desktopMode'))
[void]$script:modeCombo.Items.Add((Get-Text 'independentAppMode'))
$script:modeCombo.SelectedIndex = 0
$shareGroup.Controls.Add($script:modeCombo)

$shareGroup.Controls.Add((New-Label (Get-Text 'quality') 365 32 75))
$script:resolutionCombo = New-Object System.Windows.Forms.ComboBox
$script:resolutionCombo.Location = New-Object Drawing.Point(440, 28)
$script:resolutionCombo.Size = New-Object Drawing.Size(100, 28)
$script:resolutionCombo.DropDownStyle = 'DropDownList'
[void]$script:resolutionCombo.Items.Add('1080p')
[void]$script:resolutionCombo.Items.Add('1440p')
$script:resolutionCombo.SelectedIndex = 0
$shareGroup.Controls.Add($script:resolutionCombo)

$shareGroup.Controls.Add((New-Label (Get-Text 'fps') 16 75 55))
$script:fpsCombo = New-Object System.Windows.Forms.ComboBox
$script:fpsCombo.Location = New-Object Drawing.Point(105, 71)
$script:fpsCombo.Size = New-Object Drawing.Size(80, 28)
$script:fpsCombo.DropDownStyle = 'DropDownList'
[void]$script:fpsCombo.Items.Add('30')
[void]$script:fpsCombo.Items.Add('60')
$script:fpsCombo.SelectedIndex = 1
$shareGroup.Controls.Add($script:fpsCombo)

$shareGroup.Controls.Add((New-Label (Get-Text 'bitrate') 210 75 70))
$script:bitrateCombo = New-Object System.Windows.Forms.ComboBox
$script:bitrateCombo.Location = New-Object Drawing.Point(280, 71)
$script:bitrateCombo.Size = New-Object Drawing.Size(85, 28)
$script:bitrateCombo.DropDownStyle = 'DropDownList'
foreach ($item in @('8M', '16M', '24M')) { [void]$script:bitrateCombo.Items.Add($item) }
$script:bitrateCombo.SelectedIndex = 1
$shareGroup.Controls.Add($script:bitrateCombo)

$script:audioCheck = New-Object System.Windows.Forms.CheckBox
$script:audioCheck.Text = Get-Text 'forwardAudio'
$script:audioCheck.Location = New-Object Drawing.Point(400, 72)
$script:audioCheck.Size = New-Object Drawing.Size(125, 25)
$script:audioCheck.Checked = $true
$shareGroup.Controls.Add($script:audioCheck)

$script:screenOffCheck = New-Object System.Windows.Forms.CheckBox
$script:screenOffCheck.Text = Get-Text 'turnScreenOff'
$script:screenOffCheck.Location = New-Object Drawing.Point(105, 110)
$script:screenOffCheck.Size = New-Object Drawing.Size(250, 25)
$shareGroup.Controls.Add($script:screenOffCheck)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = Get-Text 'startSharing'
$startButton.Location = New-Object Drawing.Point(105, 145)
$startButton.Size = New-Object Drawing.Size(160, 34)
$startButton.Add_Click({ Start-ShareSession })
$shareGroup.Controls.Add($startButton)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = Get-Text 'stopSelectedMode'
$stopButton.Location = New-Object Drawing.Point(280, 145)
$stopButton.Size = New-Object Drawing.Size(170, 34)
$stopButton.Add_Click({
    Stop-ShareSession (Get-SelectedShareMode)
})
$shareGroup.Controls.Add($stopButton)

$diagnosticsButton = New-Object System.Windows.Forms.Button
$diagnosticsButton.Text = Get-Text 'inputDiagnostics'
$diagnosticsButton.Location = New-Object Drawing.Point(470, 145)
$diagnosticsButton.Size = New-Object Drawing.Size(190, 34)
$diagnosticsButton.Add_Click({ Save-InputDiagnostics })
$shareGroup.Controls.Add($diagnosticsButton)

$script:desktopNote = New-Label (Get-Text 'desktopNote') 365 104 300
$script:desktopNote.ForeColor = [Drawing.Color]::DimGray
$shareGroup.Controls.Add($script:desktopNote)

$appLabel = New-Label (Get-Text 'appPickerLabel') 16 112 85
$script:appCombo = New-Object System.Windows.Forms.ComboBox
$script:appCombo.Location = New-Object Drawing.Point(105, 107)
$script:appCombo.Size = New-Object Drawing.Size(287, 28)
$script:appCombo.DropDownWidth = 450
$script:appCombo.DropDownStyle = 'DropDownList'
$script:appCombo.DisplayMember = 'Label'
[void]$script:appCombo.Items.Add([pscustomobject]@{ Package='com.phoenix.read'; Label=(Get-Text 'appHongguo') })
[void]$script:appCombo.Items.Add([pscustomobject]@{ Package='com.android.settings'; Label=(Get-Text 'appAndroidSettings') })
$script:appCombo.SelectedIndex = 0

$script:appListButton = New-Object System.Windows.Forms.Button
$script:appListButton.Text = Get-Text 'appListButton'
$script:appListButton.Location = New-Object Drawing.Point(402, 104)
$script:appListButton.Size = New-Object Drawing.Size(135, 30)
$script:appListButton.Add_Click({ Start-IndependentAppList })

$script:appOrientationCombo = New-Object System.Windows.Forms.ComboBox
$script:appOrientationCombo.Location = New-Object Drawing.Point(550, 107)
$script:appOrientationCombo.Size = New-Object Drawing.Size(110, 28)
$script:appOrientationCombo.DropDownStyle = 'DropDownList'
[void]$script:appOrientationCombo.Items.Add((Get-Text 'appPortrait'))
[void]$script:appOrientationCombo.Items.Add((Get-Text 'appLandscape'))
$script:appOrientationCombo.SelectedIndex = 0

$script:appScreenOffCheck = New-Object System.Windows.Forms.CheckBox
$script:appScreenOffCheck.Text = Get-Text 'appScreenOff'
$script:appScreenOffCheck.Location = New-Object Drawing.Point(527, 72)
$script:appScreenOffCheck.Size = New-Object Drawing.Size(165, 25)
$script:appScreenOffCheck.Checked = $true

$script:spacePlaybackCheck = New-Object System.Windows.Forms.CheckBox
$script:spacePlaybackCheck.Text = Get-Text 'appSpacePlayback'
$script:spacePlaybackCheck.Location = New-Object Drawing.Point(552, 28)
$script:spacePlaybackCheck.Size = New-Object Drawing.Size(140, 26)
$script:spacePlaybackCheck.Checked = $true
$script:spacePlaybackCheck.Add_CheckedChanged({
    if (-not $script:loadingSettings) { Update-HongguoSpaceShortcut; Save-Settings }
})

$script:appControls = @($appLabel, $script:appCombo, $script:appListButton, $script:appOrientationCombo, $script:appScreenOffCheck, $script:spacePlaybackCheck)
foreach ($control in $script:appControls) { $shareGroup.Controls.Add($control) }

$playbackGroup = New-Object System.Windows.Forms.GroupBox
$playbackGroup.Text = Get-Text 'playbackControls'
$playbackGroup.Location = New-Object Drawing.Point(20, 405)
$playbackGroup.Size = New-Object Drawing.Size(700, 175)
$form.Controls.Add($playbackGroup)

$playbackGroup.Controls.Add((New-Label (Get-Text 'playbackPreset') 16 28 70))
$script:presetCombo = New-Object System.Windows.Forms.ComboBox
$script:presetCombo.Location = New-Object Drawing.Point(90, 24)
$script:presetCombo.Size = New-Object Drawing.Size(160, 28)
$script:presetCombo.DropDownStyle = 'DropDownList'
foreach ($key in @('presetControl', 'presetMovie', 'presetCustom')) { [void]$script:presetCombo.Items.Add((Get-Text $key)) }
$script:presetCombo.SelectedIndex = 0
$script:presetCombo.Add_SelectedIndexChanged({ Set-PlaybackPreset })
$playbackGroup.Controls.Add($script:presetCombo)

$playbackGroup.Controls.Add((New-Label (Get-Text 'videoBuffer') 265 28 85))
$script:bufferInput = New-Object System.Windows.Forms.NumericUpDown
$script:bufferInput.Location = New-Object Drawing.Point(350, 24)
$script:bufferInput.Size = New-Object Drawing.Size(65, 28)
$script:bufferInput.Maximum = 1000
$script:bufferInput.Increment = 50
$script:bufferInput.Add_ValueChanged({
    if (-not $script:loadingSettings -and -not $script:applyingPreset) {
        $script:presetCombo.SelectedIndex = 2
        Save-Settings
    }
})
$playbackGroup.Controls.Add($script:bufferInput)

$script:topmostCheck = New-Object System.Windows.Forms.CheckBox
$script:topmostCheck.Text = Get-Text 'alwaysOnTop'
$script:topmostCheck.Location = New-Object Drawing.Point(435, 25)
$script:topmostCheck.Size = New-Object Drawing.Size(90, 26)
$script:topmostCheck.Add_CheckedChanged({ Set-ShareWindowOptions })
$playbackGroup.Controls.Add($script:topmostCheck)

$script:rememberWindowCheck = New-Object System.Windows.Forms.CheckBox
$script:rememberWindowCheck.Text = Get-Text 'rememberWindow'
$script:rememberWindowCheck.Location = New-Object Drawing.Point(535, 25)
$script:rememberWindowCheck.Size = New-Object Drawing.Size(155, 26)
$script:rememberWindowCheck.Checked = $true
$script:rememberWindowCheck.Add_CheckedChanged({ Save-Settings })
$playbackGroup.Controls.Add($script:rememberWindowCheck)

$previousButton = New-Object System.Windows.Forms.Button
$previousButton.Text = Get-Text 'previousEpisode'
$previousButton.Location = New-Object Drawing.Point(16, 65)
$previousButton.Size = New-Object Drawing.Size(120, 32)
$previousButton.Add_Click({ Send-ShareGesture 'previous' })
$playbackGroup.Controls.Add($previousButton)

$nextButton = New-Object System.Windows.Forms.Button
$nextButton.Text = Get-Text 'nextEpisode'
$nextButton.Location = New-Object Drawing.Point(145, 65)
$nextButton.Size = New-Object Drawing.Size(120, 32)
$nextButton.Add_Click({ Send-ShareGesture 'next' })
$playbackGroup.Controls.Add($nextButton)

$leftButton = New-Object System.Windows.Forms.Button
$leftButton.Text = Get-Text 'swipeLeft'
$leftButton.Location = New-Object Drawing.Point(274, 65)
$leftButton.Size = New-Object Drawing.Size(80, 32)
$leftButton.Add_Click({ Send-ShareGesture 'left' })
$playbackGroup.Controls.Add($leftButton)

$rightButton = New-Object System.Windows.Forms.Button
$rightButton.Text = Get-Text 'swipeRight'
$rightButton.Location = New-Object Drawing.Point(363, 65)
$rightButton.Size = New-Object Drawing.Size(80, 32)
$rightButton.Add_Click({ Send-ShareGesture 'right' })
$playbackGroup.Controls.Add($rightButton)

$script:miniCheck = New-Object System.Windows.Forms.CheckBox
$script:miniCheck.Text = Get-Text 'miniWindow'
$script:miniCheck.Location = New-Object Drawing.Point(456, 69)
$script:miniCheck.Size = New-Object Drawing.Size(100, 26)
$script:miniCheck.Add_CheckedChanged({ Set-ShareWindowOptions })
$playbackGroup.Controls.Add($script:miniCheck)

$logDirectoryButton = New-Object System.Windows.Forms.Button
$logDirectoryButton.Text = Get-Text 'openRunLogs'
$logDirectoryButton.Location = New-Object Drawing.Point(565, 65)
$logDirectoryButton.Size = New-Object Drawing.Size(120, 32)
$logDirectoryButton.Add_Click({
    $directory = Join-Path $script:root 'data\logs'
    [void](New-Item -ItemType Directory -Path $directory -Force)
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $directory + '"')
})
$playbackGroup.Controls.Add($logDirectoryButton)

$playbackGroup.Controls.Add((New-Label (Get-Text 'gestureHotkeys') 16 112 80))
$script:hotkeyCombo = New-Object System.Windows.Forms.ComboBox
$script:hotkeyCombo.Location = New-Object Drawing.Point(100, 108)
$script:hotkeyCombo.Size = New-Object Drawing.Size(205, 28)
$script:hotkeyCombo.DropDownStyle = 'DropDownList'
foreach ($value in @('Ctrl+Alt', 'Ctrl+Shift', (Get-Text 'hotkeysOff'))) { [void]$script:hotkeyCombo.Items.Add($value) }
$script:hotkeyCombo.SelectedIndex = 0
$script:hotkeyCombo.Add_SelectedIndexChanged({ if (-not $script:loadingSettings) { Update-ShareHotkeys; Save-Settings } })
$playbackGroup.Controls.Add($script:hotkeyCombo)
$playbackGroup.Controls.Add((New-Label (Get-Text 'gestureHotkeyHint') 320 112 365))
$gestureHint = New-Label (Get-Text 'gestureHint') 16 145 665
$gestureHint.ForeColor = [Drawing.Color]::DimGray
$playbackGroup.Controls.Add($gestureHint)

$form.Controls.Add((New-Label (Get-Text 'status') 24 595 100))
$updateButton = New-Object System.Windows.Forms.Button
$updateButton.Text = Get-Text 'checkUpdate'
$updateButton.Location = New-Object Drawing.Point(610, 587)
$updateButton.Size = New-Object Drawing.Size(110, 30)
$updateButton.Add_Click({ Check-ForUpdate })
$form.Controls.Add($updateButton)

$script:logBox = New-Object System.Windows.Forms.TextBox
$script:logBox.Location = New-Object Drawing.Point(20, 625)
$script:logBox.Size = New-Object Drawing.Size(700, 150)
$script:logBox.Multiline = $true
$script:logBox.ReadOnly = $true
$script:logBox.ScrollBars = 'Vertical'
$script:logBox.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($script:logBox)

Load-Settings
$script:loadingSettings = $false
$script:hotkeys = New-Object AndroidScreenShare.ShareHotkeys
$script:hotkeys.Add_SpacePressed({
    if ($script:spacePlaybackHook -and $script:spacePlaybackHook.TakePress()) { Send-HongguoPlaybackToggle }
})
Update-IndependentAppControls
$script:modeCombo.Add_SelectedIndexChanged({ Update-IndependentAppControls; Sync-ControlSessionOptions })

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 200
$pollTimer.Add_Tick({
    Complete-IndependentAppList
    Complete-HongguoPlayback
    $command = ''
    while ($script:hotkeys.TryRead([ref]$command)) { Send-ShareGesture $command }
    foreach ($mode in @($script:sessions.Keys)) {
        $session = $script:sessions[$mode]
        Update-ShareProcessLog $session
        if ($session.Process.HasExited) {
            Add-Log (Get-Text 'scrcpyExited' @($mode, $session.Process.ExitCode))
            Stop-ShareSession $mode $false
            continue
        }
        Complete-SessionDiagnostics $session
        Start-SessionDiagnostics $session
        Update-ShareGesture $session
        if (((Get-Date) - $session.LastWindowSample).TotalSeconds -ge 1) {
            Save-SessionWindow $session
            $session.LastWindowSample = Get-Date
        }
        if ($session.CompanionActive -and $session.Listener.Pending()) {
            $client = $session.Listener.AcceptTcpClient()
            try {
                $client.ReceiveTimeout = 2500
                $stream = $client.GetStream()
                $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII)
                $command = $reader.ReadLine()
                if ($command -eq 'STOP') {
                    $writer = New-Object IO.StreamWriter($stream, [Text.Encoding]::ASCII)
                    $writer.AutoFlush = $true
                    $writer.WriteLine('OK')
                    $writer.Dispose()
                    Stop-ShareSession $mode
                } else {
                    $reader.Dispose()
                }
            } catch {
                Add-Log (Get-Text 'stopFailed' @($_.Exception.Message))
            } finally {
                $client.Dispose()
            }
        }
    }
})

$form.Add_Shown({
    $hadPreferredDevice = [bool]$script:lastDeviceSerial
    Refresh-Devices
    $pollTimer.Start()
    if ($AutoStartMode -in @('mirror', 'desktop', 'app')) {
        $script:modeCombo.SelectedIndex = [Array]::IndexOf(@('mirror', 'desktop', 'app'), $AutoStartMode)
        if ($script:deviceCombo.SelectedItem -and ($hadPreferredDevice -or $script:deviceCombo.Items.Count -eq 1)) {
            Start-ShareSession
        } else {
            Add-Log (Get-Text 'autoStartOneDevice')
        }
    }
})

$form.Add_FormClosing({
    $pollTimer.Stop()
    Stop-IndependentAppList
    Stop-HongguoSpaceShortcut
    $script:hotkeys.Dispose()
    $script:hotkeys = $null
    foreach ($session in @($script:sessions.Values)) { Save-SessionWindow $session }
    Save-Settings
    foreach ($mode in @($script:sessions.Keys)) {
        Stop-ShareSession $mode
    }
})

[void]$form.ShowDialog()
