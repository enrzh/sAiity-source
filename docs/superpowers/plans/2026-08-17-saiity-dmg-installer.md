# sAiity DMG Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Finder drag-to-Applications DMG visually polished and reliably present its background/layout without changing installation or release security behavior.

**Architecture:** Keep the generated artwork in `scripts/make-dmg-background.swift` and the Finder staging/layout/notarization flow in `scripts/make-dmg.sh`. Shared canvas and icon-position constants will be reflected in both files so the rendered arrow and Finder icons stay aligned. The existing `/Applications` symlink, signed app copy, DMG signing, notarization, stapling, and mounted validation remain unchanged.

**Tech Stack:** Swift AppKit/Core Graphics for the generated PNG; Bash, `hdiutil`, Finder AppleScript, `codesign`, `xcrun notarytool`, and `xcrun stapler` for the disk-image pipeline.

## Global Constraints

- Preserve the native drag-to-Applications interaction.
- Keep the existing `Applications` symlink pointing to `/Applications`.
- Do not change app source, onboarding, permissions, versioning, or published 2.0.0 artifacts.
- Keep artwork generated at build time; do not add hand-authored binary assets.
- Keep the best-effort Finder automation fallback so an image remains installable when Automation permission is unavailable.
- Validate the generated image as mounted bytes, not only as the local build output.

---

### Task 1: Generate the polished installer background

**Files:**
- Modify: `scripts/make-dmg-background.swift`
- Test artifact: `/tmp/saiity-dmg-background.png`

**Interfaces:**
- Consumes: an optional output path in `CommandLine.arguments[1]`.
- Produces: a 700x440-point, 2x PNG containing the neutral background, sAiity wordmark, installation instruction, and arrow aligned to the Finder icon positions.

- [ ] **Step 1: Render the current generator and record its dimensions**

Run:

```bash
swift scripts/make-dmg-background.swift /tmp/saiity-dmg-background-before.png
sips -g pixelWidth -g pixelHeight /tmp/saiity-dmg-background-before.png
```

Expected: the current renderer produces a 1200x760 PNG, confirming the existing 600x380-point canvas before the change.

- [ ] **Step 2: Replace the renderer constants and artwork**

Use a 700x440-point logical canvas with `scale = 2`. Draw the wordmark and instruction in system fonts, use a neutral near-white fill, and draw a thin teal arrow between the two icon homes. The renderer must use the same logical centers that the Finder script uses: app `{170, 220}`, Applications `{530, 220}`, and arrow y `220`.

- [ ] **Step 3: Render and inspect the new pixels**

Run:

```bash
swift scripts/make-dmg-background.swift /tmp/saiity-dmg-background.png
sips -g pixelWidth -g pixelHeight /tmp/saiity-dmg-background.png
```

Expected: `1400` by `880`. Visually inspect the PNG; the wordmark, instruction, and arrow must be visible with no clipping.

- [ ] **Step 4: Commit the renderer**

```bash
git add scripts/make-dmg-background.swift
git commit -m "feat: polish sAiity installer artwork"
```

### Task 2: Persist the Finder presentation

**Files:**
- Modify: `scripts/make-dmg.sh`

**Interfaces:**
- Consumes: the generated PNG at `.background/installer.png`, the staged `sAiity.app`, and the `/Applications` symlink.
- Produces: a DMG whose Finder window uses the 700x440-point canvas, 128-point icons, and positions `{170, 220}` and `{530, 220}` in Finder coordinates.

- [ ] **Step 1: Update Finder geometry and icon positions**

Change the AppleScript window bounds to `{200, 150, 900, 590}` and set:

```applescript
set position of item "sAiity.app" of container window to {170, 220}
set position of item "Applications" of container window to {530, 220}
```

Keep the background picture assignment after `set theViewOptions` and before the icon positions. Keep the existing note-and-continue fallback when Finder Automation is unavailable.

- [ ] **Step 2: Let Finder persist the view before detach**

Keep `update without registering applications`, increase the existing delay to `2`, and add a second `update without registering applications`. Leave the Finder window open until `hdiutil detach`: on current macOS, explicitly closing it first rewrites `.DS_Store` from cached defaults and drops the background alias. Ejecting the mounted read-write image closes the window while preserving the background and positions.

- [ ] **Step 3: Run shell syntax and renderer checks**

Run:

```bash
bash -n scripts/make-dmg.sh
swift scripts/make-dmg-background.swift /tmp/saiity-dmg-background.png
test "$(sips -g pixelWidth /tmp/saiity-dmg-background.png | awk '/pixelWidth/{print $2}')" = 1400
test "$(sips -g pixelHeight /tmp/saiity-dmg-background.png | awk '/pixelHeight/{print $2}')" = 880
```

Expected: exit status `0` for every command.

- [ ] **Step 4: Commit the Finder pipeline change**

```bash
git add scripts/make-dmg.sh
git commit -m "feat: refine Finder installer layout"
```

### Task 3: Build and visually verify a local DMG

**Files:**
- Read: `build/sAiity.app`
- Generate: `build/sAiity-2.0.1-preview.dmg`

**Interfaces:**
- Consumes: the existing notarised `build/sAiity.app`.
- Produces: a local preview DMG only; it is not uploaded or published.

- [ ] **Step 1: Confirm the app is present and stapled**

Run:

```bash
test -d build/sAiity.app
xcrun stapler validate build/sAiity.app
```

Expected: the app exists and stapler validation succeeds.

- [ ] **Step 2: Build the preview through the existing pipeline**

Run:

```bash
scripts/make-dmg.sh 2.0.1-preview
```

Expected: the pipeline produces `build/sAiity-2.0.1-preview.dmg` and prints mounted app validation plus the `/Applications` drag-target check.

- [ ] **Step 3: Mount and inspect the real Finder window**

Run:

```bash
MOUNT=$(hdiutil attach -nobrowse -readonly build/sAiity-2.0.1-preview.dmg | awk '/\\/Volumes\\//{print substr($0, index($0,"/Volumes/")); exit}')
test -L "$MOUNT/Applications"
test "$(readlink "$MOUNT/Applications")" = "/Applications"
find "$MOUNT" -maxdepth 1 -mindepth 1 -print | sort
hdiutil detach "$MOUNT"
```

Expected: the mounted root contains the app and Applications symlink plus hidden presentation metadata. Open it in Finder and capture a screenshot; the title, instruction, arrow, icon spacing, and labels must all be visible.

- [ ] **Step 4: Remove only the preview artifact**

```bash
rm -f build/sAiity-2.0.1-preview.dmg
```

The published `build/sAiity-2.0.0.dmg` must not be modified.

### Task 4: Run regression checks and record the result

**Files:**
- Read: all tracked source files

- [ ] **Step 1: Run the supported release test command**

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS
```

Expected: all suites pass. Existing compiler warnings may remain, but no test failures are acceptable.

- [ ] **Step 2: Confirm only intended files changed**

```bash
git status --short
git diff HEAD~2 --stat
```

Expected: only the two installer scripts and the two installer design/plan documents are present in the new commits; no build artifacts are tracked.

- [ ] **Step 3: Do not publish a release from this task**

Leave `v2.0.0` and its public assets unchanged. Cut a new release separately only after the user approves the mounted preview.
