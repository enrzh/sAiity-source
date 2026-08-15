# Windows Overlay Spike

Status: source added; Windows build and visual behavior are unverified on this
Mac host because the .NET SDK and Windows runtime are not installed here.

The repository now has a Windows GitHub Actions build at
`.github/workflows/windows-overlay.yml`. Run `f6cd448` passed on
`windows-latest`, including restore and Release compilation. That proves the
source compiles on Windows; it does not prove click-through, topmost behavior,
or the DWM backdrop visually.

## Purpose

`windows/spike` answers one narrow product question before the port grows:
whether a WPF caption surface can be topmost, non-activating, click-through,
and visually restrained while asking DWM for a Windows 11 backdrop.

The surface intentionally has a solid dark fallback. It contains no gradients,
animated fades, or decorative effects. If the backdrop disappears under the
layered style, the fallback is the product behavior until a measured alternative
is better.

## Windows verification

Run on Windows 11 with the pinned .NET SDK installed:

```powershell
dotnet --info
dotnet build windows/spike/OverlaySpike.csproj -c Release -p:Platform=x64
dotnet run --project windows/spike/OverlaySpike.csproj -c Release
```

Record:

- Windows build number and .NET SDK version.
- Whether the window stays topmost without activating when another app is focused.
- Whether clicks pass through to a browser or video player beneath it.
- Whether the DWM backdrop remains visible with `WS_EX_LAYERED`.
- A screenshot with the overlay over a browser and another with it over a video.

The current source uses `WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE |
WS_EX_TOOLWINDOW | WS_EX_TOPMOST`. These are the exact behaviors that must be
verified on Windows; compiling the source on macOS cannot establish them.

## Test package

`.github/workflows/windows-package.yml` publishes a self-contained ZIP artifact
for `win-x64`. It contains the prototype executable, `Install.ps1`,
`Uninstall.ps1`, and a short README. The package is unsigned and contains no
audio capture or ASR yet. Download the artifact from the workflow run, extract
it, and run the install script from PowerShell.
