$ErrorActionPreference = 'Stop'

$installRoot = Join-Path $env:LOCALAPPDATA 'sAiity\WindowsOverlayPrototype'
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$shortcutPath = Join-Path $startMenu 'sAiity Windows Overlay Prototype.lnk'
$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
Copy-Item -Path (Join-Path $sourceRoot 'sAiity.WindowsOverlayPrototype.exe') `
    -Destination (Join-Path $installRoot 'sAiity.WindowsOverlayPrototype.exe') -Force

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $installRoot 'sAiity.WindowsOverlayPrototype.exe'
$shortcut.WorkingDirectory = $installRoot
$shortcut.Description = 'sAiity Windows overlay prototype'
$shortcut.Save()

Write-Host "Installed to $installRoot"
Write-Host "Start Menu shortcut: $shortcutPath"
