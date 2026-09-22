param(
    [string]$InstallRoot = $PSScriptRoot,
    [switch]$Silent,
    [switch]$NoConfirm,
    [switch]$Force,
    [switch]$Restart,
    [int]$WaitForProcessId = 0,
    [string]$Repository = 'OrangeYi/android-screen-share',
    [string]$Branch = 'main',
    [string]$VersionUrl = '',
    [string]$ArchiveUrl = ''
)

$ErrorActionPreference = 'Stop'
if (-not $VersionUrl) { $VersionUrl = "https://raw.githubusercontent.com/$Repository/$Branch/VERSION" }
if (-not $ArchiveUrl) { $ArchiveUrl = "https://github.com/$Repository/archive/refs/heads/$Branch.zip" }

$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$trimmedRoot = $InstallRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$driveRoot = [IO.Path]::GetPathRoot($InstallRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
if ($trimmedRoot -eq $driveRoot) {
    throw 'Refusing to update a drive root.'
}
if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot 'Start-AndroidScreenShare.cmd') -PathType Leaf)) {
    throw "The selected folder is not an Android Screen Share installation: $InstallRoot"
}

$localePath = Join-Path $InstallRoot 'locales\zh-CN.json'
$text = ([IO.File]::ReadAllText($localePath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
Add-Type -AssemblyName System.Windows.Forms

function Show-UpdateMessage([string]$message, [string]$title = '') {
    if (-not $title) { $title = [string]$text.appTitle }
    if ($Silent) {
        Write-Host $message
    } else {
        [System.Windows.Forms.MessageBox]::Show($message, $title) | Out-Null
    }
}

function Read-Version([string]$path) {
    $value = ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)).Trim()
    $parsed = $null
    if (-not [Version]::TryParse($value, [ref]$parsed)) {
        throw ([string]::Format([string]$text.invalidVersion, $value))
    }
    return $parsed
}

function Get-ResponseText($response) {
    if ($response.Content -is [byte[]]) {
        return [Text.Encoding]::UTF8.GetString($response.Content)
    }
    return [string]$response.Content
}

function Invoke-Git([string[]]$arguments) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git.exe @arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw (($output -join "`r`n").Trim())
    }
    return $output
}

$tempRoot = $null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $currentVersion = Read-Version (Join-Path $InstallRoot 'VERSION')
    $cacheBuster = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $separator = if ($VersionUrl.Contains('?')) { '&' } else { '?' }
    $versionResponse = Invoke-WebRequest -UseBasicParsing -Uri "${VersionUrl}${separator}t=$cacheBuster"
    $remoteVersionText = (Get-ResponseText $versionResponse).Trim()
    $remoteVersion = $null
    if (-not [Version]::TryParse($remoteVersionText, [ref]$remoteVersion)) {
        throw ([string]::Format([string]$text.invalidVersion, $remoteVersionText))
    }

    if (-not $Force -and $remoteVersion -le $currentVersion) {
        Show-UpdateMessage ([string]::Format([string]$text.latestVersion, $currentVersion))
        exit 0
    }

    if (-not $Silent -and -not $NoConfirm) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            ([string]::Format([string]$text.updatePrompt, $currentVersion, $remoteVersion)),
            ([string]$text.updateAvailable),
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
    }

    if ($WaitForProcessId -gt 0) {
        $parent = Get-Process -Id $WaitForProcessId -ErrorAction SilentlyContinue
        if ($parent) { $null = $parent.WaitForExit(15000) }
    }

    if (Test-Path -LiteralPath (Join-Path $InstallRoot '.git') -PathType Container) {
        if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
            throw ([string]$text.updateGitMissing)
        }
        $changes = @(Invoke-Git @('-C', $InstallRoot, 'status', '--porcelain'))
        if ($changes.Count -gt 0) {
            throw ([string]$text.updateGitDirty)
        }
        Invoke-Git @('-C', $InstallRoot, 'pull', '--ff-only', 'origin', 'main') | Out-Null
        $archiveVersion = Read-Version (Join-Path $InstallRoot 'VERSION')
    } else {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('android-screen-share-update-' + [Guid]::NewGuid().ToString('N'))
        $zipPath = Join-Path $tempRoot 'source.zip'
        $extractPath = Join-Path $tempRoot 'extract'
        New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
        Invoke-WebRequest -UseBasicParsing -Uri $ArchiveUrl -OutFile $zipPath
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

        $sourceDir = Get-ChildItem -LiteralPath $extractPath -Directory | Select-Object -First 1
        if (-not $sourceDir -or
            -not (Test-Path -LiteralPath (Join-Path $sourceDir.FullName 'Setup.ps1') -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $sourceDir.FullName 'Update.ps1') -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $sourceDir.FullName 'app\AndroidScreenShare.ps1') -PathType Leaf)) {
            throw ([string]$text.updateArchiveInvalid)
        }

        $archiveVersion = Read-Version (Join-Path $sourceDir.FullName 'VERSION')
        if ($archiveVersion -ne $remoteVersion) {
            throw ([string]$text.updateVersionMismatch)
        }

        # Program-owned directories are replaced. Downloaded scrcpy and local
        # settings are intentionally preserved across updates.
        foreach ($sourceDirectory in (Get-ChildItem -LiteralPath $sourceDir.FullName -Directory -Force)) {
            if ($sourceDirectory.Name -in @('tools', 'data', '.git')) { continue }
            $targetDirectory = Join-Path $InstallRoot $sourceDirectory.Name
            if (Test-Path -LiteralPath $targetDirectory) {
                Remove-Item -LiteralPath $targetDirectory -Recurse -Force
            }
            Copy-Item -LiteralPath $sourceDirectory.FullName -Destination $targetDirectory -Recurse -Force
        }
        foreach ($sourceFile in (Get-ChildItem -LiteralPath $sourceDir.FullName -File -Force)) {
            Copy-Item -LiteralPath $sourceFile.FullName -Destination (Join-Path $InstallRoot $sourceFile.Name) -Force
        }
    }

    if ($archiveVersion -ne $remoteVersion) {
        throw ([string]$text.updateVersionMismatch)
    }

    $setupScript = Join-Path $InstallRoot 'Setup.ps1'
    $setupArguments = '-NoProfile -ExecutionPolicy Bypass -Sta -File "{0}" -Silent' -f $setupScript
    $setupProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $setupArguments `
        -WorkingDirectory $InstallRoot -WindowStyle Hidden -Wait -PassThru
    if ($setupProcess.ExitCode -ne 0) {
        throw "Setup validation failed with exit code $($setupProcess.ExitCode)."
    }

    Show-UpdateMessage ([string]::Format([string]$text.updateComplete, $archiveVersion))
    if ($Restart) {
        Start-Process -FilePath (Join-Path $InstallRoot 'Start-AndroidScreenShare.cmd') -WorkingDirectory $InstallRoot
    }
} catch {
    Show-UpdateMessage ([string]::Format([string]$text.updateFailed, $_.Exception.Message)) ([string]$text.updateFailedTitle)
    exit 1
} finally {
    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
