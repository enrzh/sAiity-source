# sAiity 2.0 Public Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the existing macOS-only sAiity 2.0 work, make the public repository source-available in the hAiity style, refresh verified screenshots, and update aiity.de and me.aiity.de without publishing unapproved X copy.

**Architecture:** Treat the sAiity checkout, the private aiity-web repository, and the apps_nas me-aiity service as three separate release units. The sAiity release is verified from the running signed app and pushed/tagged only after tests and build checks. Website content is edited at source files, generated outputs are rebuilt, and each deployment is verified over HTTPS.

**Tech Stack:** SwiftPM, Swift Testing, AppKit/SwiftUI, `build-app.sh`, Node.js static-site generator, Docker/Caddy deployment, GitHub CLI, ego-browser.

## Global Constraints

- Keep `enrzh/sAiity` public; do not change repository visibility or rewrite history.
- Remove the current MIT license and contributor framing from the current tree; state that the public repository is for inspection and grants no reuse license.
- Keep the shipped product macOS 26 and Apple Silicon only; do not present the Windows overlay spike as a product or release.
- Keep MADLAD as the recommended translator; Hy-MT2 remains opt-in.
- Preserve all existing dictation and Hy-MT2 implementation changes; do not revert concurrent work.
- Stage exact paths only; never use `git add -A` in any repository.
- Keep unrelated `apps_nas/lexware` changes out of the me-aiity commit.
- Capture screenshots from the running app and inspect them visually before claiming the UI is represented.
- Do not publish X posts until the exact final copy is shown and explicitly confirmed.
- Use `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS` for sAiity tests.

### Task 1: Lock the release baseline

**Files:** read the current state in `/Users/enrico/Documents/GitHub/saiity`, `/Users/enrico/Documents/GitHub/aiity-web`, and `/Users/enrico/Documents/GitHub/apps_nas/me-aiity`.

- [ ] Re-read `git status -sb`, `git diff --name-status`, and `git log --oneline --decorate -12` in each relevant repository. Confirm the sAiity implementation changes are the already-present dictation and Hy-MT2 work plus the committed design spec. Confirm the website and apps_nas dirty paths before staging anything.
- [ ] Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS`. Expected: exit code 0 and the full test count. If it fails, stop and diagnose before changing release copy.

### Task 2: Convert sAiity to the source-available product repository

**Files:**
- Modify `/Users/enrico/Documents/GitHub/saiity/README.md`
- Create `/Users/enrico/Documents/GitHub/saiity/build/RELEASE_NOTES_2.0.0.md`
- Delete `/Users/enrico/Documents/GitHub/saiity/LICENSE`
- Delete `/Users/enrico/Documents/GitHub/saiity/CONTRIBUTING.md`

- [ ] Rewrite the README in the hAiity shape: product statement, privacy/operating model, concise feature bullets, build commands, layout, release information, and aiity family link. Add verified 2.0 capabilities: press-to-talk dictation, clipboard fallback, opt-in microphone behavior, bilingual transcripts, and opt-in Hy-MT2. Do not call the repository open source, MIT, or contributor-friendly. Include exactly: `This repository is public for inspection. No license is granted to copy, modify, or redistribute the source.`
- [ ] Write release notes with sections `sAiity 2.0`, `Press-to-talk dictation`, `Translation`, `Transcripts and captions`, `Privacy`, `Requirements`, and `Known limitations`. Say that Windows is not a supported release target.
- [ ] Remove `LICENSE` and `CONTRIBUTING.md`. Keep `SECURITY.md` only if its wording remains accurate after the README change; remove any sentence that claims MIT/open-source status.
- [ ] Run `rg -n -i 'open source|MIT License|contribut|No license is granted|Windows' README.md SECURITY.md build/RELEASE_NOTES_2.0.0.md` and `git diff --check`. Expected: no open-source or MIT claim remains; the source-available sentence and macOS-only limitation are present.

### Task 3: Capture and replace screenshots from the running app

**Files:**
- Replace `docs/screenshots/01-bubble.png`
- Replace `docs/screenshots/02-subtitles.png`
- Replace `docs/screenshots/03-models.png`
- Replace `docs/screenshots/04-library.png`
- Modify README alt text only if the captured content requires it

- [ ] Run `./build-app.sh --install`, launch `/Applications/sAiity.app`, and inspect the real app window. Do not use a SwiftUI preview or generated image.
- [ ] Capture a stable desktop screenshot of: (1) the caption bubble with source and translation, (2) Captions settings with current recognition and translation choices including Hy-MT2, (3) Dictation settings with its configurable key and controls, and (4) saved transcripts showing a bilingual session or the honest empty state if no real fixture can be created.
- [ ] Keep the existing filenames, crop only to the app window, and use the image viewer on all four files. Confirm no clipped text, stale 1.2-era tabs, unrelated windows, or misleading empty content.

### Task 4: Update aiity.de

**Files:**
- Modify `/Users/enrico/Documents/GitHub/aiity-web/src/content.js`
- Modify `/Users/enrico/Documents/GitHub/aiity-web/build.js` only if required
- Regenerate `/Users/enrico/Documents/GitHub/aiity-web/public/`

- [ ] Finish the existing family-page diff through `src/content.js`, not generated HTML. Describe sAiity as a signed macOS 26 Apple Silicon download with on-device captions, translation, and press-to-talk dictation. Replace “open source” with public-inspection/no-reuse-license wording in every affected locale.
- [ ] Run `node build.js`, `git diff --check`, and a targeted `rg` over `src/content.js public/index.html public/de/index.html`. Do not hand-edit `public/`.
- [ ] Stage exact website paths, review `git diff --cached --name-status`, `git diff --cached --check`, commit `content: align aiity family page with sAiity 2.0`, and push `origin main`.
- [ ] Run `scripts/deploy.sh --dry-run`, then apply the existing deployment script while preserving `/saiity/`. Verify `https://aiity.de/`, `https://aiity.de/de/`, `https://aiity.de/saiity/appcast.xml`, and the sAiity GitHub link over HTTPS.

### Task 5: Update and deploy me.aiity.de

**Files:**
- Modify `/Users/enrico/Documents/GitHub/apps_nas/me-aiity/app.js`
- Modify `/Users/enrico/Documents/GitHub/apps_nas/me-aiity/README.md`
- Do not modify `apps_nas/lexware/ios-native/Lexware/Core/LexwareFinalize.swift`

- [ ] Align the project output and GitHub command with the source-available wording, keep the sAiity link, and add its signed 2.0 macOS description.
- [ ] Run `git diff -- me-aiity/app.js me-aiity/README.md` and `git diff --check -- me-aiity/app.js me-aiity/README.md`. Expected: only those two files are eligible for this change.
- [ ] Inspect the exact `scripts/deploy-service.sh` command and compose service name, then commit/push only the me-aiity paths and deploy that service. Verify `https://me.aiity.de/` in ego-browser by running `projects` and `github`.

### Task 6: Final sAiity verification and 2.0 GitHub release

**Files:** current sAiity implementation/tests, README, release notes, screenshots, and approved spec/plan docs.

- [ ] Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS`, `swift build -c release`, `./build-app.sh`, and `git diff --check`. Read the complete outputs. Reinspect the installed app if UI/localization changed after screenshots.
- [ ] Stage exact sAiity paths, review `git diff --cached --name-status`, `git diff --cached --stat`, and `git diff --cached --check`, then commit `release: ship sAiity 2.0`.
- [ ] Confirm `v2.0.0` does not exist, then run `git push origin main`, `git tag -a v2.0.0 -m 'sAiity 2.0'`, `git push origin v2.0.0`, and `gh release create v2.0.0 --repo enrzh/sAiity --title 'sAiity 2.0' --notes-file build/RELEASE_NOTES_2.0.0.md`. Attach only artifacts produced by the verified build; do not claim notarization without fresh proof.
- [ ] Verify `git status -sb`, `gh release view v2.0.0 --repo enrzh/sAiity`, and `gh api repos/enrzh/sAiity/releases/latest --jq '.tag_name, .name, .draft, .prerelease'`.

### Task 7: Prepare and publish X posts after confirmation

- [ ] Show the exact final copy and target accounts. English for `@aiityapp`:
  `sAiity 2.0 is out for macOS 26 on Apple Silicon. Live on-device captions, translation, bilingual transcripts, and press-to-talk dictation. No account, no API key, no audio leaves the Mac. Download: https://github.com/enrzh/sAiity/releases/tag/v2.0.0`
- [ ] Show the Chinese repost/quote for `@foreseeingx`:
  `sAiity 2.0 已发布：在 Mac 本地运行的实时字幕、翻译、双语转录和按住说话听写。无需账号或 API 密钥，音频不离开设备。macOS 26 + Apple Silicon：https://github.com/enrzh/sAiity/releases/tag/v2.0.0`
- [ ] After explicit confirmation, use the existing ego-browser task space to publish from the intended accounts, then verify the final post URLs and release link. If account switching is blocked, leave the copy ready and report that instead of substituting another account.

## Final Review Checklist

- [ ] sAiity worktree is clean after the release commit and tag.
- [ ] No MIT/open-source/contributor claim remains in the current sAiity tree or updated website copy.
- [ ] README screenshots visibly match the shipped app.
- [ ] aiity.de and me.aiity.de show the 2.0/source-available positioning.
- [ ] GitHub release exists and points at v2.0.0.
- [ ] X posts are verified at final URLs or explicitly left unpublished pending confirmation/access.
