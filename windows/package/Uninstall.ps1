$ErrorActionPreference = 'Stop'

$installRoot = Join-Path $env:LOCALAPPDATA 'sAiity\WindowsOverlayPrototype'
$shortcutPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\sAiity Windows Overlay Prototype.lnk'

if (Test-Path $shortcutPath) { Remove-Item $shortcutPath -Force }
if (Test-Path $installRoot) { Remove-Item $installRoot -Recurse -Force }

Write-Host 'sAiity Windows overlay prototype removed.'
