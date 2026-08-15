sAiity Windows Overlay Prototype 0.1.0

This is an early Windows overlay package, not the sAiity 2.0 release.
It does not capture audio or transcribe speech yet.

Install:
  1. Open PowerShell in this folder.
  2. Run:
     powershell -ExecutionPolicy Bypass -File .\Install.ps1
  3. Start it from the Start Menu.

Remove:
  powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1

The executable is self-contained and does not require .NET to be installed.
The package is unsigned. Windows SmartScreen may show a warning; only run it
if you downloaded it from the sAiity repository's official Actions artifact.
