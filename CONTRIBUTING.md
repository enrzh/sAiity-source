# Contributing

Issues and pull requests are welcome. This file is short and specific: it covers
what to run before opening one, and the handful of things in this codebase that
are easy to get wrong.

## Before opening a pull request

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS
./build-app.sh --install
```

The release configuration and the two flags are not optional — a plain
`swift test` fails on this toolchain's debug C targets, and `-enable-testing` is
what makes `@testable import` resolve.

Check the **test count**, not just the exit code. 68 tests in 13 suites at the
time of writing; a target that silently stops being compiled still exits zero.

If the change is visible in the caption bubble, verify it in the running app
rather than by reasoning about it. TCC binds Screen Recording permission to the
LaunchServices-registered bundle, so launch it the way the system does:

```bash
open --stderr /tmp/x.log --env SAIITY_AUTOSTART=1 -a /Applications/sAiity.app
```

`SAIITY_AUTOSTART` also turns on verbose logging, which prints the bubble's
frame after every caption — the stillness of the bubble cannot be seen from a
script, so it is logged instead.

## Three things that are easy to trip over

1. **The bubble's width is a setting, not a measurement.** Any change that
   derives it from the text reintroduces the jitter the design exists to
   prevent: a panel sized to its content resizes and re-centres on every caption
   *and* again when the translation lands. `BubbleGeometryTests` fails loudly if
   you try, and that is deliberate. The failure signature to recognise is a
   width exactly equal to the screen's, which means the margin was bypassed and
   the clamp then has one legal `x`: hard against an edge.

2. **A stored setting that nothing reads looks exactly like a working
   feature.** Five of the original ten `CaptionStyle` fields were in that state
   — persisted, exposed in the UI, read by nobody. `CaptionStyleTests`
   enumerates every property and stops compiling when a field is added without
   being listed, which is the point of it.

3. **Exactly one `process()` call may be in flight on a streaming engine.**
   FluidAudio's managers are actors, and Swift actors are re-entrant across
   `await`, so two overlapping calls corrupt the buffer offset and trap. This
   has caused two separate production crashes. `StreamingASRBackend` documents
   what it enforces and what it still assumes about its caller; if you add a
   second caller, enforce it rather than assuming it.

## Style

Match the file you are editing. Comments in this codebase explain *why* — a
constraint, a failure that motivated the code, a trap the next reader would
otherwise fall into — and not what the next line does. If a comment could be
deleted without losing information, delete it.

Commit messages: what changed and why it matters, in prose. The git history here
is meant to be readable a year from now.

## Localisation

German is a translation; English is the source. New user-facing strings go
through the string catalog at `Resources/Localizable.xcstrings`. SwiftUI keys
`Text("literal")` automatically. Four things silently bypass that, and each one
looks exactly like a working translation until you launch in German:

1. **`Text("a" + "b")`.** The concatenation resolves to `String` and hits the
   verbatim overload. Write the sentence as one literal, however long.
2. **`Text(someString)`.** Same overload. If the value comes from a model or an
   enum, wrap it at the definition site with `String(localized:)` — that is why
   `ASREngine.summary`, `LocalModel.note` and friends are wrapped there and not
   where they are displayed.
3. **A `String` parameter on a view wrapper.** `LabeledToggle`, `SheetShell` and
   `ResetButton` take `LocalizedStringKey`; as `String` they bind the caller's
   literal to the verbatim overload, and every explanation under every switch in
   Settings stayed English while the section headers around them translated.
4. **Interpolating a number.** `"Step \(n) of \(total)"` produces the key
   `Step %lld of %lld`, not `%@` — an `Int` is not a `String`. A catalog entry
   written with `%@` never matches and falls back to English. `Double` gives
   `%lf`. When unsure, print `LocalizedStringResource(value).key` rather than
   guessing.

AppKit (`NSAlert`, `NSOpenPanel`, `stringValue`, `NSMenuItem(title:)`) always
needs `String(localized:)` explicitly. Proper nouns — model and licence names —
carry `"shouldTranslate": false` in the catalog instead of a German value.

Where a whole channel is user-facing, type the channel rather than trusting each
caller. `AppDelegate.setStatus` takes a `String.LocalizationValue`, so its ~30
literal call sites key themselves and a missed one is a compile error;
`setStatus(localized:)` is the separate door for text the producer already
localised. The ASR and translator progress sinks stay `(String) -> Void` on
purpose — their messages carry runtime percentages — so they localise at the
producer instead, which is why `NemotronBackend`, `ParakeetEouEngine` and
`Translators` all wrap their own progress literals.

`LocalizationTests` now enforces the mechanical half of this continuously:
every catalog key must carry a finished German localization (or
`shouldTranslate: false`), and every single-line literal it finds in a
localized position must resolve to a catalog key. Its scanner deliberately
does not see triple-quoted strings, ternary literals, or values passed
through variables — for those, and for layout, still verify by rendering
rather than by counting keys:

```bash
defaults write de.aiity.saiity AppleLanguages '(de)'
open --env SAIITY_OPEN_SETTINGS=1 -a /Applications/sAiity.app
```

Delete the key again afterwards, or the app stays German regardless of the
system setting.
