# Security

sAiity has no server, no account and no telemetry, which removes most of the
attack surface an app like this would normally have. What is left is worth being
precise about.

## What the app can reach

- **System audio**, via ScreenCaptureKit. macOS gates this behind Screen
  Recording permission — there is no audio-only permission to ask for, which is
  why the app requests something that sounds broader than what it does. There
  are no `AVCaptureDevice` or `AVAudioEngine` call sites in the source: the
  microphone is never opened, and `Info.plist` deliberately declares no camera
  or microphone usage strings.
- **huggingface.co**, once per model, to download weights. Nothing else is
  fetched at runtime except the update feed, if you switch update checks on.
- **The local filesystem**, under
  `~/Library/Application Support/de.aiity.saiity/` — model weights, and session
  transcripts if you have turned recording on. Both are removable from the app.

Audio is never written to disk and never leaves the machine. Recognition and
translation run entirely on-device.

## Updates

In-app updates use [Sparkle](https://sparkle-project.org). The appcast is signed
with Ed25519; the public key is embedded in `Info.plist` as `SUPublicEDKey`, and
the private half is not in this repository and never will be. Automatic update
checks are **off** until you opt in during onboarding — an app whose pitch is
that nothing leaves the device should not phone home before being asked.

## Reporting

If you find something, please report it privately first rather than opening a
public issue: **[aiity.de](https://aiity.de)**.

Useful in a report: macOS version, whether the build was your own or notarised,
and the smallest reproduction you can manage. Crash reports from
`~/Library/Logs/DiagnosticReports/` are welcome and contain no caption text.

### What counts

- Anything that gets caption text, transcripts or audio off the machine.
- Anything that makes the app process input it should not — a crafted model
  file, a hostile appcast, a path that escapes the app's own directories.
- Bypassing the update signature check.

### What does not

- The Screen Recording prompt being broader than "audio only". That is macOS's
  gate, not a choice the app makes.
- Model output being wrong, biased or offensive. Captions are a recognition
  result, not a transcript of record, and the README says so.
- Anything requiring an attacker who already has code execution as your user.

## Honest limitations

This has not been audited. One adversarial review has been run over the app as a
whole and its findings fixed, and the security-relevant reasoning is written down
in the source, but that is a different and much weaker claim than an audit.

There is currently no Developer ID certificate on the project, so builds are not
notarised and Gatekeeper will object. Do not run a "sAiity" binary you did not
build yourself from this source.
