# sAiity DMG Installer Design

**Status:** Approved 2026-08-17

## Goal

Make the macOS drag-to-Applications installer feel deliberate and product-quality while preserving Finder's native installation interaction.

## User experience

The disk image keeps exactly two user-facing items: the sAiity app and the Applications alias. The window uses a wider, balanced canvas with the app on the left and Applications on the right. A visible directional arrow connects them. A restrained sAiity wordmark and a short "Drag to install" instruction sit above the path, so the action is clear without turning the DMG into a wizard.

The installer remains a normal Finder window. There is no helper app, custom install button, extra documentation file, account flow, or change to the `/Applications` symlink.

## Visual direction

- Use a warm near-white background that remains readable when Finder opens the image in either macOS appearance.
- Use the app's existing teal accent sparingly for the wordmark and directional cue.
- Use system-like typography, generous whitespace, and a thin arrow rather than a large decorative illustration.
- Keep all artwork in the generated PNG so the repository does not gain hand-authored binary assets.
- Size the canvas and icon positions from one shared set of constants so the artwork and Finder layout cannot drift apart.

## Build behavior

`scripts/make-dmg-background.swift` remains the single source of truth for the generated background. It will draw the canvas, wordmark, instruction, and arrow using AppKit/Core Graphics.

`scripts/make-dmg.sh` will keep the existing staging, signing, notarization, stapling, and mounted verification flow. Its Finder AppleScript will use the same canvas dimensions and positions as the renderer, explicitly apply the background picture, and persist the window's icon view settings before closing. If Finder automation is unavailable, the image must still remain installable and the script must retain its existing best-effort fallback behavior.

## Verification

- Compile and run the background renderer into a temporary PNG and inspect the resulting pixels.
- Build a local DMG from the existing notarised app, mount it, and inspect the actual Finder window.
- Confirm the mounted volume contains exactly the sAiity app, the Applications symlink, and the hidden presentation files.
- Confirm the symlink still resolves to `/Applications`.
- Run the supported release test command; no application behavior is changed, but the source checkout must remain clean apart from the intended installer changes.

## Non-goals

- No custom installer application.
- No changes to app onboarding, permissions, or first-run setup.
- No changes to release versioning, public repositories, or published 2.0.0 artifacts.
