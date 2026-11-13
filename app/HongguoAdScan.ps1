function ConvertTo-HongguoAdCountdown([string[]]$Lines, [switch]$KnownAd) {
    $lines = @($Lines -replace '[ \t　]', '')
    $label = '^广告(?:中)?(?=$|[|｜丨·:：\d])'
    $countdown = '(?:(?:剩余|还剩|广告(?:倒计时)?[|｜丨·:：]?)\s*(?<seconds>\d{1,2})秒|(?<seconds>\d{1,2})秒(?:后)?(?:可)?(?:跳过|关闭)|(?:跳过|关闭)[|｜丨·:：]?(?<seconds>\d{1,2})(?:秒|s)?)'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch $label -and $lines[$i] -notmatch '^广告(?:倒计时|剩余)') { continue }
        $block = $lines[[Math]::Max(0,$i-1)..[Math]::Min($lines.Count-1,$i+1)] -join "`n"
        $match = [regex]::Match($block, $countdown, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $seconds = [int]$match.Groups['seconds'].Value
            if ($seconds -gt 0 -and $seconds -le 90) { return $seconds }
        }
    }
    if ($KnownAd) {
        # The ad renderer is already confirmed. A timer may be shown without the word 广告.
        foreach ($line in $lines) {
            if ($line -match '(?:^(?<sec>\d{1,2})(?:秒|s)$|(?:剩余|还剩|跳过|关闭)[|｜丨·:：]?(?<sec>\d{1,2})(?:秒|s)?$|(?<sec>\d{1,2})(?:秒|s)(?:后)?(?:可)?(?:跳过|关闭)$)') {
                $seconds = [int]$Matches.sec
                if ($seconds -gt 0 -and $seconds -le 90) { return $seconds }
            }
        }
    }
}

function Wait-OcrResult($Operation, [type]$ResultType) {
    $task = $script:ocrAsTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    if (-not $task.Wait(1400)) { throw 'Windows OCR timed out.' }
    return $task.GetAwaiter().GetResult()
}

function Get-HongguoAdCountdown([int]$PlayerPid, [int]$VideoWidth, [int]$VideoHeight, [switch]$KnownAd) {
    if (-not $script:ocrEngine) {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
        $null = [Windows.Graphics.Imaging.BitmapDecoder,Windows.Foundation,ContentType=WindowsRuntime]
        $null = [Windows.Storage.Streams.InMemoryRandomAccessStream,Windows.Foundation,ContentType=WindowsRuntime]
        $language = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages |
            Where-Object { $_.LanguageTag -match '^zh(?:-Hans|-CN)' } | Select-Object -First 1
        if (-not $language) { throw 'Windows OCR requires the Simplified Chinese language pack.' }
        $script:ocrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language)
        if (-not $script:ocrEngine) { throw 'Could not initialize Chinese OCR.' }
        $script:ocrAsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        } | Select-Object -First 1
    }

    $bitmap = [AndroidScreenShare.DesktopWindows]::CapturePlayerTop($PlayerPid, $VideoWidth, $VideoHeight)
    if (-not $bitmap) { return }
    try {
        $countdown = Read-HongguoAdBitmap $bitmap -KnownAd:$KnownAd
        if ($null -eq $countdown) { return 0 }
        return $countdown
    } finally { $bitmap.Dispose() }
}

function Read-HongguoAdBitmap([Drawing.Bitmap]$Bitmap, [switch]$KnownAd) {
    $bytes = [IO.MemoryStream]::new()
    $stream = [Windows.Storage.Streams.InMemoryRandomAccessStream]::new()
    $writer = $null
    $image = $null
    try {
        $Bitmap.Save($bytes, [Drawing.Imaging.ImageFormat]::Png)
        $writer = [Windows.Storage.Streams.DataWriter,Windows.Foundation,ContentType=WindowsRuntime]::new($stream)
        $writer.WriteBytes($bytes.ToArray())
        [void](Wait-OcrResult ($writer.StoreAsync()) ([uint32]))
        [void]$writer.DetachStream()
        $stream.Seek(0)
        $decoder = Wait-OcrResult ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $image = Wait-OcrResult ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap,Windows.Foundation,ContentType=WindowsRuntime])
        $result = Wait-OcrResult ($script:ocrEngine.RecognizeAsync($image)) ([Windows.Media.Ocr.OcrResult,Windows.Foundation,ContentType=WindowsRuntime])
        $seconds = ConvertTo-HongguoAdCountdown @($result.Lines | ForEach-Object Text)
        if ($seconds -or -not $KnownAd) { return $seconds }
        $rightEdge = $Bitmap.Width * 0.60
        $cornerLines = foreach ($line in $result.Lines) {
            ($line.Words | Where-Object { $_.BoundingRect.X -ge $rightEdge } | ForEach-Object Text) -join ''
        }
        ConvertTo-HongguoAdCountdown @($cornerLines) -KnownAd
    } finally {
        if ($image) { $image.Dispose() }
        if ($writer) { $writer.Dispose() }
        $stream.Dispose()
        $bytes.Dispose()
    }
}

$script:ocrEngine = $null
$script:ocrAsTask = $null

function Get-HongguoAdObservation(
    [string]$AdbPath, [string]$Serial, [int]$DisplayId, [int]$PlayerPid,
    [int]$VideoWidth, [int]$VideoHeight
) {
    if (-not [AndroidScreenShare.FocusedPlayerHotkeys]::HasFocus($PlayerPid)) { return }
    $card = $null
    if ($DisplayId -gt 0) {
        try {
            $player = Join-Path $PSScriptRoot 'HongguoPlayback.ps1'
            $card = & $player -AdbPath $AdbPath -Serial $Serial -DisplayId $DisplayId -PlayerPid $PlayerPid -CheckAdPage
        } catch {
            # Activity dumps can be unavailable while the player is changing screens.
        }
    }
    $countdown = Get-HongguoAdCountdown $PlayerPid $VideoWidth $VideoHeight -KnownAd:([bool]$card)
    if ($null -eq $countdown) { return }
    return [pscustomobject]@{ Countdown=$countdown; AdPage=$(if ($card) { $card.Key } else { '' }) }
}
