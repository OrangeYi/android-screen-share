function Get-SelectedShareMode {
    switch ($script:modeCombo.SelectedIndex) {
        1 { return 'desktop' }
        2 { return 'app' }
        default { return 'mirror' }
    }
}

function Test-AndroidAppPackage([string]$package) {
    return $package -cmatch '^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$'
}

function Get-IndependentAppDisplay([string]$quality, [bool]$landscape) {
    $short = if ($quality -eq '1440p') { 1440 } else { 1080 }
    $long = if ($quality -eq '1440p') { 2560 } else { 1920 }
    $dpi = if ($quality -eq '1440p') { 420 } else { 320 }
    $width = if ($landscape) { $long } else { $short }
    $height = if ($landscape) { $short } else { $long }
    return [pscustomobject]@{ Width=$width; Height=$height; Spec="${width}x${height}/$dpi" }
}

function Get-ScrcpyCreatedDisplayId([string]$line) {
    if ($line -match '^\[server\]\s+INFO:\s+New display:.*\(id=([1-9]\d*)\)') { return [int]$Matches[1] }
    return $null
}

function Test-AppOnDisplay([string]$dump, [int]$displayId, [string]$package) {
    $targetDisplay = $false
    $activityPattern = 'ActivityRecord\{[^}\r\n]*\s' + [regex]::Escape($package) + '/'
    foreach ($line in ($dump -split '\r?\n')) {
        if ($line -match '^\s*Display #([0-9]+)\s+\(activities') { $targetDisplay = [int]$Matches[1] -eq $displayId }
        elseif ($targetDisplay -and $line -match $activityPattern) { return $true }
    }
    return $false
}

function ConvertFrom-ScrcpyAppList([string[]]$lines) {
    $found = @{}
    foreach ($line in $lines) {
        if ($line -match '^\s*[-*]\s+(.+?)\s+([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+)\s*$') {
            $label = $Matches[1].Trim()
            $package = $Matches[2]
            $found[$package] = [pscustomobject]@{ Package=$package; Label="$label  [$package]" }
        }
    }
    return $found.Values | Sort-Object Label
}

function Set-IndependentAppSelection([string]$package) {
    if (-not (Test-AndroidAppPackage $package)) { return }
    for ($i = 0; $i -lt $script:appCombo.Items.Count; $i++) {
        if ($script:appCombo.Items[$i].Package -ceq $package) {
            $script:appCombo.SelectedIndex = $i
            return
        }
    }
    [void]$script:appCombo.Items.Add([pscustomobject]@{ Package=$package; Label=$package })
    $script:appCombo.SelectedIndex = $script:appCombo.Items.Count - 1
}

function Get-SelectedAppPackage {
    $item = $script:appCombo.SelectedItem
    if (-not $item -or -not (Test-AndroidAppPackage $item.Package)) { throw (Get-Text 'appSelectRequired') }
    return [string]$item.Package
}

function Update-IndependentAppControls {
    $isApp = (Get-SelectedShareMode) -eq 'app'
    foreach ($control in $script:appControls) { $control.Visible = $isApp }
    $script:screenOffCheck.Visible = -not $isApp
    $script:screenOffCheck.Enabled = (Get-SelectedShareMode) -eq 'mirror'
    $script:desktopNote.Visible = -not $isApp
    $script:appListButton.Enabled = -not $script:appListProbe
}

function Start-IndependentAppList {
    if ($script:appListProbe) { return }
    try {
        $serial = Get-SelectedSerial
        if (-not (Test-Path -LiteralPath $script:scrcpyPath -PathType Leaf)) { throw (Get-Text 'scrcpyMissing') }
        $capture = [AndroidScreenShare.CapturedProcess]::new($script:scrcpyPath, [string[]]@('-s', $serial, '--list-apps'), $script:scrcpyDir)
        $script:appListProbe = [pscustomobject]@{ Capture=$capture; Serial=$serial; Timer=[Diagnostics.Stopwatch]::StartNew() }
        Update-IndependentAppControls
        Add-Log (Get-Text 'appListLoading')
    } catch { Add-Log (Get-Text 'appListFailed' @($_.Exception.Message)) }
}

function Stop-IndependentAppList {
    if (-not $script:appListProbe) { return }
    $script:appListProbe.Capture.Dispose()
    $script:appListProbe = $null
}

function Complete-IndependentAppList {
    $probe = $script:appListProbe
    if (-not $probe) { return }
    $process = $probe.Capture.Process
    $completed = $process.HasExited -and $probe.Capture.OutputComplete
    if (-not $completed -and $probe.Timer.ElapsedMilliseconds -lt 12000) { return }
    try {
        if (-not $completed) { throw (Get-Text 'appListTimeout') }
        $line = ''; $lines = New-Object 'Collections.Generic.List[string]'
        while ($probe.Capture.TryReadLine([ref]$line)) { $lines.Add($line) }
        if ($process.ExitCode -ne 0) { throw ($lines -join ' ') }
        if (-not $script:deviceCombo.SelectedItem -or $script:deviceCombo.SelectedItem.Serial -ne $probe.Serial) { return }
        $apps = @(ConvertFrom-ScrcpyAppList $lines.ToArray())
        if ($apps.Count -eq 0) { throw (Get-Text 'appListEmpty') }
        $previous = if ($script:appCombo.SelectedItem) { $script:appCombo.SelectedItem.Package } else { '' }
        $script:appCombo.Items.Clear()
        foreach ($app in $apps) { [void]$script:appCombo.Items.Add($app) }
        $script:appCombo.SelectedIndex = 0
        if ($apps.Package -contains $previous) { Set-IndependentAppSelection $previous }
        Add-Log (Get-Text 'appListLoaded' @($apps.Count))
    } catch { Add-Log (Get-Text 'appListFailed' @($_.Exception.Message)) }
    finally { Stop-IndependentAppList; Update-IndependentAppControls }
}
