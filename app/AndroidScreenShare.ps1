param(
    [string]$AutoStartMode = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
$script:companionApk = Join-Path $script:root 'assets\companion.apk'
$script:companionPackage = 'dev.androidscreenshare.companion'
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

function Get-Text([string]$key, [object[]]$values = @()) {
    $value = [string]$script:T.$key
    if ($values.Count -gt 0) {
        return [string]::Format($value, $values)
    }
    return $value
}

function Add-Log([string]$message) {
    if (-not $script:logBox) { return }
    $timestamp = (Get-Date).ToString('HH:mm:ss')
    $script:logBox.AppendText("[$timestamp] $message`r`n")
    $script:logBox.SelectionStart = $script:logBox.TextLength
    $script:logBox.ScrollToCaret()
}

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

function Refresh-Devices {
    try {
        Invoke-Adb '' @('start-server') -allowFailure | Out-Null
        $previous = $null
        if ($script:deviceCombo.SelectedItem) {
            $previous = [string]$script:deviceCombo.SelectedItem.Serial
        }

        $items = @()
        foreach ($line in (Invoke-Adb '' @('devices', '-l') -allowFailure)) {
            if ($line -match '^(\S+)\s+device(?:\s+(.*))?$') {
                $serial = $Matches[1]
                $details = $Matches[2]
                $model = Get-Text 'androidDevice'
                if ($details -match '\bmodel:(\S+)') {
                    $model = $Matches[1].Replace('_', ' ')
                }
                $transport = if ($serial -match ':') { Get-Text 'wifi' } else { Get-Text 'usb' }
                $items += [pscustomobject]@{
                    Serial = $serial
                    Label = "$model  [$transport]  $serial"
                }
            }
        }

        $script:deviceCombo.Items.Clear()
        foreach ($item in $items) {
            [void]$script:deviceCombo.Items.Add($item)
        }
        if ($items.Count -gt 0) {
            $index = 0
            if ($previous) {
                for ($i = 0; $i -lt $items.Count; $i++) {
                    if ($items[$i].Serial -eq $previous) { $index = $i; break }
                }
            }
            $script:deviceCombo.SelectedIndex = $index
        }
        Add-Log (Get-Text 'foundDevices' @($items.Count))
    } catch {
        Add-Log (Get-Text 'refreshFailed' @($_.Exception.Message))
    }
}

function Ensure-Companion([string]$serial) {
    $installed = Invoke-Adb $serial @('shell', '--', 'pm', 'path', $script:companionPackage) -allowFailure
    if (-not (($installed -join '') -match '^package:')) {
        if (-not (Test-Path -LiteralPath $script:companionApk)) {
            throw (Get-Text 'companionMissing')
        }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            (Get-Text 'installPrompt'),
            (Get-Text 'installTitle'),
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            throw (Get-Text 'installDeclined')
        }
        Add-Log (Get-Text 'installing')
        $result = Invoke-Adb $serial @('install', '-r', $script:companionApk) -allowFailure
        if (($result -join "`n") -notmatch 'Success') {
            throw (Get-Text 'installFailed' @(($result -join ' ')))
        }
    }
    Invoke-Adb $serial @(
        'shell', '--', 'pm', 'grant', $script:companionPackage,
        'android.permission.POST_NOTIFICATIONS') -allowFailure | Out-Null
}

function Get-CursorPlacement {
    $screen = [System.Windows.Forms.Screen]::FromPoint(
        [System.Windows.Forms.Cursor]::Position)
    return [pscustomobject]@{
        X = $screen.WorkingArea.Left + 24
        Y = $screen.WorkingArea.Top + 24
    }
}

function Get-VirtualDisplayIds([string]$serial) {
    $ids = @()
    $lines = Invoke-Adb $serial @(
        'shell', '--', 'cmd', 'display', 'get-displays', '-i', '--type', 'virtual') -allowFailure
    foreach ($line in $lines) {
        foreach ($match in [regex]::Matches([string]$line, '\d+')) {
            $ids += [int]$match.Value
        }
    }
    return @($ids | Sort-Object -Unique)
}

function Stop-ShareSession([string]$mode, [bool]$killProcess = $true) {
    if (-not $script:sessions.ContainsKey($mode)) { return }
    $session = $script:sessions[$mode]
    $script:sessions.Remove($mode)

    if ($killProcess -and -not $session.Process.HasExited) {
        Stop-Process -Id $session.Process.Id -Force -ErrorAction SilentlyContinue
    }
    try { $session.Listener.Stop() } catch {}
    Invoke-Adb $session.Serial @(
        'shell', '--', 'am', 'stopservice', '-n', $session.Component) -allowFailure | Out-Null
    Invoke-Adb $session.Serial @(
        'reverse', '--remove', "tcp:$($session.Port)") -allowFailure | Out-Null
    Add-Log (Get-Text 'sharingStopped' @($mode))
}

function Start-ShareSession {
    try {
        if (-not (Test-Path -LiteralPath $script:scrcpyPath)) {
            throw (Get-Text 'scrcpyMissing')
        }

        $serial = Get-SelectedSerial
        $mode = if ($script:modeCombo.SelectedIndex -eq 1) { 'desktop' } else { 'mirror' }
        if ($script:sessions.ContainsKey($mode)) {
            Add-Log (Get-Text 'alreadyRunning' @($mode))
            return
        }

        Ensure-Companion $serial
        $quality = [string]$script:resolutionCombo.SelectedItem
        $fps = [string]$script:fpsCombo.SelectedItem
        $bitrate = [string]$script:bitrateCombo.SelectedItem
        $placement = Get-CursorPlacement
        $beforeIds = @()
        if ($mode -eq 'desktop') {
            $beforeIds = @(Get-VirtualDisplayIds $serial)
        }

        $scrcpyArguments = @(
            '-s', $serial,
            '--video-codec=h264',
            "--max-fps=$fps",
            "--video-bit-rate=$bitrate",
            '--video-buffer=0',
            '--audio-buffer=80',
            "--window-x=$($placement.X)",
            "--window-y=$($placement.Y)"
        )
        if ($script:audioCheck.Checked) {
            $scrcpyArguments += @('--audio-source=output', '--audio-codec=aac')
        } else {
            $scrcpyArguments += '--no-audio'
        }

        if ($mode -eq 'desktop') {
            $displaySpec = if ($quality -eq '1440p') {
                '2560x1440/213'
            } else {
                '1920x1080/160'
            }
            $scrcpyArguments += @(
                "--new-display=$displaySpec",
                '--window-title=AndroidScreenShare-Desktop')
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

        Add-Log (Get-Text 'starting' @($serial, $mode))
        $process = Start-Process -FilePath $script:scrcpyPath `
            -WorkingDirectory $script:scrcpyDir `
            -ArgumentList $scrcpyArguments -PassThru
        Start-Sleep -Milliseconds 900
        if ($process.HasExited) {
            throw (Get-Text 'startupExit')
        }

        $listener = [System.Net.Sockets.TcpListener]::new(
            [System.Net.IPAddress]::Loopback,
            $port)
        $listener.Start()
        Invoke-Adb $serial @('reverse', "tcp:$port", "tcp:$port") | Out-Null
        Invoke-Adb $serial @(
            'shell', '--', 'am', 'start-foreground-service', '-n', $component,
            '--ei', 'port', [string]$port) | Out-Null

        $script:sessions[$mode] = [pscustomobject]@{
            Mode = $mode
            Serial = $serial
            Port = $port
            Component = $component
            Process = $process
            Listener = $listener
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
                if ($null -eq $displayId -and $currentIds.Count -gt 0) {
                    $displayId = $currentIds | Select-Object -Last 1
                }
                if ($null -ne $displayId) { break }
            }
            if ($null -ne $displayId) {
                Invoke-Adb $serial @(
                    'shell', '--', 'input', '-d', [string]$displayId,
                    'keyevent', 'KEYCODE_HOME') -allowFailure | Out-Null
            }
        }

        Add-Log (Get-Text 'sharingActive' @($mode))
    } catch {
        Add-Log (Get-Text 'startFailed' @($_.Exception.Message))
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            (Get-Text 'startFailedTitle'),
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
}

function Connect-WirelessAddress {
    try {
        $address = $script:addressBox.Text.Trim()
        if ($address -notmatch '^\d{1,3}(?:\.\d{1,3}){3}:\d+$') {
            throw (Get-Text 'addressExample')
        }
        $result = Invoke-Adb '' @('connect', $address) -allowFailure
        Add-Log ($result -join ' ')
        Start-Sleep -Milliseconds 500
        Refresh-Devices
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
        if ($serial -match ':') {
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
        Refresh-Devices
    } catch {
        Add-Log (Get-Text 'usbWifiFailed' @($_.Exception.Message))
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
$form.Text = Get-Text 'appTitle'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(760, 650)
$form.MinimumSize = New-Object Drawing.Size(760, 650)
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
$refreshButton.Add_Click({ Refresh-Devices })
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
    $mode = if ($script:modeCombo.SelectedIndex -eq 1) { 'desktop' } else { 'mirror' }
    Stop-ShareSession $mode
})
$shareGroup.Controls.Add($stopButton)

$desktopNote = New-Label (Get-Text 'desktopNote') 365 104 300
$desktopNote.ForeColor = [Drawing.Color]::DimGray
$shareGroup.Controls.Add($desktopNote)

$form.Controls.Add((New-Label (Get-Text 'status') 24 410 100))
$script:logBox = New-Object System.Windows.Forms.TextBox
$script:logBox.Location = New-Object Drawing.Point(20, 438)
$script:logBox.Size = New-Object Drawing.Size(700, 150)
$script:logBox.Multiline = $true
$script:logBox.ReadOnly = $true
$script:logBox.ScrollBars = 'Vertical'
$script:logBox.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($script:logBox)

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 200
$pollTimer.Add_Tick({
    foreach ($mode in @($script:sessions.Keys)) {
        $session = $script:sessions[$mode]
        if ($session.Process.HasExited) {
            Stop-ShareSession $mode $false
            continue
        }
        if ($session.Listener.Pending()) {
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
    Refresh-Devices
    $pollTimer.Start()
    if ($AutoStartMode -in @('mirror', 'desktop')) {
        $script:modeCombo.SelectedIndex = if ($AutoStartMode -eq 'desktop') { 1 } else { 0 }
        if ($script:deviceCombo.Items.Count -eq 1) {
            Start-ShareSession
        } else {
            Add-Log (Get-Text 'autoStartOneDevice')
        }
    }
})

$form.Add_FormClosing({
    $pollTimer.Stop()
    foreach ($mode in @($script:sessions.Keys)) {
        Stop-ShareSession $mode
    }
})

[void]$form.ShowDialog()
