$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\app\AndroidScreenShare.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
$function=$ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Refresh-Devices' }, $true)
. ([scriptblock]::Create($function.Extent.Text))
function Invoke-Adb {}
function Get-Text([string]$Key) { $Key }
function Add-Log([string]$Message) { if ($Message -eq 'refreshFailed') { throw 'GUI refresh failed' } }
function Get-DiscoveryDevices { $script:testDevices }
$script:refreshingDevices=$false
$script:deviceCombo=New-Object Windows.Forms.ComboBox
$script:lastDeviceSerial='old:1234'
$script:lastDeviceIdentity='TARGET'
$script:testDevices=@(
    [pscustomobject]@{ Serial='192.168.50.8:41234'; Identity='TARGET'; Details='model:Test' },
    [pscustomobject]@{ Serial='adb-test._adb-tls-connect._tcp'; Identity='TARGET'; Details='model:Test' },
    [pscustomobject]@{ Serial='another-usb'; Identity='ANOTHER'; Details='model:Other' }
)
try {
    Refresh-Devices -ListOnly
    if ($script:deviceCombo.Items.Count -ne 2) { throw 'mDNS/IP duplicates not merged' }
    if ($script:deviceCombo.SelectedItem.Identity -ne 'TARGET') { throw 'Device identity not retained' }
    $script:testDevices=@($script:testDevices | Where-Object Identity -eq 'ANOTHER')
    Refresh-Devices -ListOnly
    if ($script:deviceCombo.SelectedIndex -ne -1) { throw 'Missing target silently switched to another phone' }
    $script:testDevices=@()
    Refresh-Devices -ListOnly
    if ($script:deviceCombo.Items.Count -ne 0) { throw 'Disconnected device retained' }
    Write-Output 'PASS: GUI identity selection, duplicate merging, missing target, empty list'
} finally { $script:deviceCombo.Dispose() }
