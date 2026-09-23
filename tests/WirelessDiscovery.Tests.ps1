$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\app\WirelessDiscovery.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Add-Log([string]$Message) {}
function Get-Text([string]$Key) { $Key }
function Get-TestDevice([string]$Serial = '192.168.50.8:5555') {
    [pscustomobject]@{Serial=$Serial; Identity='TEST_DEVICE'; Details='model:Test'}
}

Assert (Test-WirelessEndpoint '192.168.50.8:5555') 'Valid endpoint rejected'
Assert (-not (Test-WirelessEndpoint '999.168.1.1:5555')) 'Invalid IPv4 accepted'
Assert (-not (Test-WirelessEndpoint '192.168.50.8:65536')) 'Invalid port accepted'
Assert (-not (Test-DiscoveryTarget @() 'old' 'TEST_DEVICE')) 'Empty device list matched'
Assert (Test-DiscoveryTarget @((Get-TestDevice '192.168.50.9:41234')) 'old-address' 'TEST_DEVICE') 'Stable identity did not survive address change'

# Fast path must never search when the selected physical device is online.
function Get-DiscoveryDevices { Get-TestDevice }
function Find-OpenWirelessEndpoints { throw 'Unexpected port scan on fast path' }
function Invoke-DiscoveryAdb { throw 'Unexpected ADB connect on fast path' }
$result = @(Find-WirelessDevices 'old-address' 'TEST_DEVICE' '')
Assert ($result.Count -eq 1) 'Fast path lost the device'

# Saved-address reconnection must work from an empty ADB list.
$script:testConnected = $false
function Get-DiscoveryDevices { if ($script:testConnected) { Get-TestDevice } }
function Find-OpenWirelessEndpoints { param($Endpoints, $TimeoutMs) $Endpoints }
function Invoke-DiscoveryAdb { param($Arguments, $TimeoutMs)
    if ($Arguments[0] -ne 'connect') { throw 'Unexpected discovery after cached reconnection' }
    $script:testConnected = $true
    'connected'
}
$result = @(Find-WirelessDevices '192.168.50.8:5555' 'TEST_DEVICE' '')
Assert ($result.Count -eq 1) 'Cache reconnect failed'

# Only connect-service ports are used; pairing-service ports must be ignored.
$script:testConnected = $false
$script:testConnects = @()
function Find-OpenWirelessEndpoints { param($Endpoints, $TimeoutMs) }
function Invoke-DiscoveryAdb { param($Arguments, $TimeoutMs)
    if ($Arguments[0] -eq 'mdns') {
        return "test _adb-tls-pairing._tcp 192.168.50.8:40000`ntest _adb-tls-connect._tcp 192.168.50.8:41000"
    }
    if ($Arguments[0] -eq 'connect') {
        $script:testConnects += $Arguments[1]
        $script:testConnected = $true
        return 'connected'
    }
    throw 'Unexpected command'
}
function Get-LocalWirelessCandidates { throw 'LAN scan ran after mDNS found the phone' }
$result = @(Find-WirelessDevices 'old-address' 'TEST_DEVICE' '')
Assert ($script:testConnects.Count -eq 1 -and $script:testConnects[0] -eq '192.168.50.8:41000') 'Pairing port was treated as a connection port'
Assert ($result.Count -eq 1) 'mDNS discovery failed'

# A failed mDNS lookup falls through to bounded LAN discovery.
$script:testConnected = $false
function Get-LocalWirelessCandidates { '192.168.50.8:5555' }
function Find-OpenWirelessEndpoints { param($Endpoints, $TimeoutMs) $Endpoints }
function Invoke-DiscoveryAdb { param($Arguments, $TimeoutMs)
    if ($Arguments[0] -eq 'mdns') { return 'List of discovered mdns services' }
    if ($Arguments[0] -eq 'connect') { $script:testConnected = $true; return 'connected' }
}
$result = @(Find-WirelessDevices '' '' '')
Assert ($result.Count -eq 1) 'LAN fallback failed'
Write-Output 'PASS: endpoint validation, device identity, fast path, cached reconnect, mDNS filtering, LAN fallback'
