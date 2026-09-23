# Connection recovery shared by GUI startup and the Search button.
# This file contains no device-specific addresses or identities.
function Invoke-DiscoveryAdb([string[]]$Arguments, [int]$TimeoutMs = 4000) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $script:adbPath
    # Only internally generated endpoints/subcommands are passed to this helper.
    $info.Arguments = $Arguments -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            try { $process.Kill() } catch {}
            return ''
        }
        return ($stdout.GetAwaiter().GetResult() + "`n" + $stderr.GetAwaiter().GetResult()).Trim()
    } finally { $process.Dispose() }
}

function Test-WirelessEndpoint([string]$Endpoint) {
    if ($Endpoint -notmatch '^(\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5})$') { return $false }
    $ip = $null
    return ([Net.IPAddress]::TryParse($Matches[1], [ref]$ip) -and
        [int]$Matches[2] -gt 0 -and [int]$Matches[2] -le 65535)
}

function Get-DiscoveryDevices {
    $output = Invoke-DiscoveryAdb @('devices', '-l')
    foreach ($line in ($output -split "`r?`n")) {
        if ($line -match '^(\S+)\s+device(?:\s+(.*))?$') {
            $serial = $Matches[1]
            $details = $Matches[2]
            $identity = Invoke-DiscoveryAdb @('-s', $serial, 'shell', 'getprop', 'ro.serialno') 1500
            if ($identity -match '\s|error:|unknown' -or -not $identity) { $identity = $serial }
            [pscustomobject]@{ Serial = $serial; Details = $details; Identity = $identity }
        }
    }
}

function Test-DiscoveryTarget($Devices, [string]$Serial, [string]$Identity) {
    if ($Identity) { return [bool]@($Devices | Where-Object Identity -eq $Identity).Count }
    if ($Serial) { return [bool]@($Devices | Where-Object Serial -eq $Serial).Count }
    return [bool]@($Devices).Count
}

function Find-OpenWirelessEndpoints([string[]]$Endpoints, [int]$TimeoutMs = 700) {
    $pending = @()
    try {
        foreach ($endpoint in @($Endpoints | Select-Object -Unique)) {
            if (-not (Test-WirelessEndpoint $endpoint)) { continue }
            $parts = $endpoint.Split(':')
            $client = New-Object Net.Sockets.TcpClient
            try {
                $task = $client.ConnectAsync($parts[0], [int]$parts[1])
                $pending += [pscustomobject]@{ Endpoint=$endpoint; Client=$client; Task=$task }
            } catch { $client.Dispose() }
        }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($timer.ElapsedMilliseconds -lt $TimeoutMs -and
            @($pending | Where-Object { -not $_.Task.IsCompleted }).Count -gt 0) {
            Start-Sleep -Milliseconds 20
        }
        foreach ($entry in $pending) {
            if ($entry.Task.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion -and $entry.Client.Connected) {
                $entry.Endpoint
            }
        }
    } finally {
        foreach ($entry in $pending) { $entry.Client.Dispose() }
    }
}

function Get-LocalWirelessCandidates {
    # Scan only directly attached private IPv4 networks with a default gateway.
    # Large subnets are bounded to the host's /24 to avoid expansive scans.
    foreach ($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($adapter.OperationalStatus -ne 'Up' -or
            $adapter.NetworkInterfaceType -notin @('Ethernet', 'Wireless80211')) { continue }
        $properties = $adapter.GetIPProperties()
        if (-not @($properties.GatewayAddresses | Where-Object {
            $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -ne '0.0.0.0'
        }).Count) { continue }
        foreach ($unicast in $properties.UnicastAddresses) {
            if ($unicast.Address.AddressFamily -ne 'InterNetwork') { continue }
            $ip = $unicast.Address.ToString()
            if ($ip -notmatch '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)') { continue }
            $bytes = $unicast.Address.GetAddressBytes()
            $mask = $unicast.IPv4Mask.GetAddressBytes()
            $prefix = "$($bytes[0]).$($bytes[1]).$($bytes[2])"
            foreach ($hostNumber in 1..254) {
                if ($hostNumber -eq $bytes[3]) { continue }
                if (($hostNumber -band $mask[3]) -ne ($bytes[3] -band $mask[3])) { continue }
                "${prefix}.${hostNumber}:5555"
            }
        }
    }
}

function Find-WirelessDevices([string]$SavedSerial, [string]$SavedIdentity, [string]$SavedAddress,
    [switch]$ForceSearch) {
    $devices = @(Get-DiscoveryDevices)
    if (-not $ForceSearch -and (Test-DiscoveryTarget $devices $SavedSerial $SavedIdentity)) { return $devices }

    Add-Log (Get-Text 'reconnectingSaved')
    $cached = @($SavedSerial, $SavedAddress) | Where-Object { Test-WirelessEndpoint $_ }
    foreach ($endpoint in @(Find-OpenWirelessEndpoints $cached)) {
        if (@($devices | ForEach-Object Serial) -notcontains $endpoint) {
            $result = Invoke-DiscoveryAdb @('connect', $endpoint)
            Add-Log $result
        }
    }
    $devices = @(Get-DiscoveryDevices)
    if (-not $ForceSearch -and (Test-DiscoveryTarget $devices $SavedSerial $SavedIdentity)) { return $devices }

    Add-Log (Get-Text 'searchingWireless')
    $mdns = Invoke-DiscoveryAdb @('mdns', 'services')
    $candidates = @()
    foreach ($line in ($mdns -split "`r?`n")) {
        # Pairing ports are NOT connection ports. Never adb-connect to them.
        if ($line -match '\s_adb(?:-tls-connect)?\._tcp\.?\s+(\d{1,3}(?:\.\d{1,3}){3}:\d+)') {
            $candidates += $Matches[1]
        }
    }
    foreach ($endpoint in @($candidates | Select-Object -Unique)) {
        if (@($devices | ForEach-Object Serial) -notcontains $endpoint) {
            Add-Log (Invoke-DiscoveryAdb @('connect', $endpoint))
        }
    }
    $devices = @(Get-DiscoveryDevices)
    if (-not $ForceSearch -and (Test-DiscoveryTarget $devices $SavedSerial $SavedIdentity)) { return $devices }

    Add-Log (Get-Text 'searchingLan')
    $candidates = @(Get-LocalWirelessCandidates | Select-Object -Unique | Select-Object -First 1024)
    # Bound work even on networks containing many unrelated open services.
    foreach ($endpoint in @(Find-OpenWirelessEndpoints $candidates 1200 | Select-Object -First 16)) {
        if (@($devices | ForEach-Object Serial) -notcontains $endpoint) {
            Add-Log (Invoke-DiscoveryAdb @('connect', $endpoint) 1800)
        }
    }
    $devices = @(Get-DiscoveryDevices)
    if (-not (Test-DiscoveryTarget $devices $SavedSerial $SavedIdentity)) {
        Add-Log (Get-Text 'wirelessNotFound')
    }
    return $devices
}
