param(
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$localePath = Join-Path $root 'locales\zh-CN.json'
$text = ([IO.File]::ReadAllText($localePath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
$toolsDir = Join-Path $root 'tools'
$scrcpyDir = Join-Path $toolsDir 'scrcpy'
$launcher = Join-Path $root 'Start-AndroidScreenShare.cmd'
$requiredScrcpyFiles = @(
    'scrcpy.exe',
    'scrcpy-server',
    'adb.exe',
    'AdbWinApi.dll',
    'AdbWinUsbApi.dll'
)

Add-Type -AssemblyName System.Windows.Forms

function Show-SetupMessage([string]$message, [string]$title = '') {
    if (-not $title) { $title = [string]$text.appTitle }
    [System.Windows.Forms.MessageBox]::Show($message, $title) | Out-Null
}

function Test-ScrcpyInstall {
    foreach ($name in $requiredScrcpyFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $scrcpyDir $name) -PathType Leaf)) {
            return $false
        }
    }
    return $true
}

try {
    if (-not (Test-ScrcpyInstall)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod -UseBasicParsing `
            'https://api.github.com/repos/Genymobile/scrcpy/releases/latest'
        $asset = $release.assets | Where-Object {
            $_.name -match '^scrcpy-win64-.*\.zip$'
        } | Select-Object -First 1
        if (-not $asset) {
            throw ([string]$text.latestNotFound)
        }

        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) `
            ('android-screen-share-' + [Guid]::NewGuid().ToString('N'))
        $zipPath = Join-Path $tempRoot 'scrcpy.zip'
        $extractPath = Join-Path $tempRoot 'extract'
        New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
        Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $zipPath
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

        $sourceDir = Get-ChildItem -LiteralPath $extractPath -Directory | Select-Object -First 1
        if (-not $sourceDir) {
            throw ([string]$text.archiveLayout)
        }
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
        if (Test-Path -LiteralPath $scrcpyDir) {
            Remove-Item -LiteralPath $scrcpyDir -Recurse -Force
        }
        Move-Item -LiteralPath $sourceDir.FullName -Destination $scrcpyDir
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }

    if (-not (Test-ScrcpyInstall)) {
        throw ([string]$text.scrcpyIncomplete)
    }

    # Validate the exact bundled ADB that the app will use. This catches files
    # removed by antivirus and unsupported/corrupt executables during setup,
    # instead of failing later in scrcpy with a vague server error.
    $adbPath = Join-Path $scrcpyDir 'adb.exe'
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $adbOutput = @(& $adbPath start-server 2>&1 | ForEach-Object { [string]$_ })
        $adbExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($adbExitCode -ne 0) {
        $detail = ($adbOutput -join "`r`n").Trim()
        if (-not $detail) { $detail = "exit code $adbExitCode" }
        throw ([string]::Format([string]$text.adbCheckFailed, $adbPath, $detail))
    }

    if (-not $Silent) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $shortcutPath = Join-Path $desktop 'Android Screen Share.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $launcher
        $shortcut.WorkingDirectory = $root
        $shortcut.IconLocation = (Join-Path $scrcpyDir 'scrcpy.exe') + ',0'
        $shortcut.Description = [string]$text.appTitle
        $shortcut.Save()

        Show-SetupMessage ([string]$text.setupComplete)
        Start-Process -FilePath $launcher -WorkingDirectory $root
    }
} catch {
    if ($Silent) {
        Write-Error $_.Exception.Message
    } else {
        Show-SetupMessage $_.Exception.Message ([string]$text.setupFailed)
    }
    exit 1
}
