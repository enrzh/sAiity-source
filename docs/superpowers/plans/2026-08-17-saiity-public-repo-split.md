# sAiity Public Repository Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the current sAiity source repository to private enrzh/sAiity-source, create a separate public enrzh/sAiity product showcase, preserve the public v2.0.0 download URL, and publish the approved X posts only after public verification.

**Architecture:** The private repository remains the complete SwiftPM source of truth. The public repository is a new, unrelated history containing only README-led product presentation, screenshots, privacy pages, and release binaries. GitHub Pages renders the public README, and the public release carries the already verified notarized artifacts.

**Tech Stack:** GitHub CLI 2.96.0, Git, GitHub Pages legacy branch publishing, Markdown, static HTML/CSS, existing sAiity screenshots and notarized macOS artifacts, ego-browser task space 29.

## Global Constraints

- The private source repository name is exactly enrzh/sAiity-source.
- The public presentation repository name is exactly enrzh/sAiity.
- Do not copy source history, Sources/, Tests/, Package.swift, .build/, release scripts, or private design notes into the public repository.
- The public repository must not claim that the implementation is open source or reusable.
- Preserve the public release URL https://github.com/enrzh/sAiity/releases/tag/v2.0.0.
- Attach only the verified artifacts: ZIP SHA-256 5062ea1eb6dd2cd3adeb232894421ce2d620ab7cda7fa5b40308fc5b5efbf3b9 and DMG SHA-256 3125395307a0eb1a6ff71a4d5ac20009564491cc67e5bb093b39eead4a38c55f.
- Do not touch /Users/enrico/Documents/GitHub/apps_nas/lexware/ios-native/Lexware/Core/LexwareFinalize.swift or /Users/enrico/Documents/GitHub/aiity-web/public/lexaiity/.
- Do not post to X until both public repository and release verification gates pass.
- Use ego-browser task space 29 with the Xianjie profile for the two approved posts.
- English is primary; the Chinese text is used only for the @foreseeingx repost or quote.

---

### Task 1: Reconfirm source and artifact state

**Files:**
- Read only: /Users/enrico/Documents/GitHub/saiity
- Read only: /Users/enrico/Documents/GitHub/saiity/build/sAiity-2.0.0.zip
- Read only: /Users/enrico/Documents/GitHub/saiity/build/sAiity-2.0.0.dmg

**Interfaces:**
- Consumes: current sAiity checkout and release artifacts.
- Produces: verified commit, tag, clean tree, and artifact hashes for all later tasks.

- [ ] **Step 1: Verify the source checkout is clean and at the expected commit.**

Run:

~~~bash
cd /Users/enrico/Documents/GitHub/saiity
git status -sb
git rev-parse HEAD
git rev-parse v2.0.0^{commit}
git remote get-url origin
~~~

Expected: main tracks origin/main, the source commit is the release lineage
starting at 03d8568, and origin is git@github.com:enrzh/sAiity.git before the
rename.

- [ ] **Step 2: Recompute the release hashes.**

Run:

~~~bash
cd /Users/enrico/Documents/GitHub/saiity
shasum -a 256 build/sAiity-2.0.0.zip build/sAiity-2.0.0.dmg
stat -f '%N %z bytes' build/sAiity-2.0.0.zip build/sAiity-2.0.0.dmg
~~~

Expected:

~~~text
5062ea1eb6dd2cd3adeb232894421ce2d620ab7cda7fa5b40308fc5b5efbf3b9  build/sAiity-2.0.0.zip
3125395307a0eb1a6ff71a4d5ac20009564491cc67e5bb093b39eead4a38c55f  build/sAiity-2.0.0.dmg
build/sAiity-2.0.0.zip 20893030 bytes
build/sAiity-2.0.0.dmg 21571480 bytes
~~~

- [ ] **Step 3: Confirm no unexpected source changes are present.**

Run:

~~~bash
cd /Users/enrico/Documents/GitHub/saiity
git diff --check
git status --short
~~~

Expected: no uncommitted source changes. Do not use git add -A; if unexpected
paths appear, stop and preserve them.

---

### Task 2: Rename and privatize the source repository

**Files:**
- Modify remote configuration: /Users/enrico/Documents/GitHub/saiity/.git/config
- Remote repository: enrzh/sAiity -> enrzh/sAiity-source

**Interfaces:**
- Consumes: verified public repository enrzh/sAiity at the source commit.
- Produces: private enrzh/sAiity-source containing the complete source history.

- [ ] **Step 1: Rename and privatize the existing GitHub repository in one API call.**

Run:

~~~bash
gh api --method PATCH repos/enrzh/sAiity \
  -f name=sAiity-source \
  -F private=true \
  --jq '{nameWithOwner,visibility,default_branch}'
~~~

Expected:

~~~json
{"nameWithOwner":"enrzh/sAiity-source","visibility":"PRIVATE","default_branch":"main"}
~~~

- [ ] **Step 2: Point the local checkout at the private repository.**

Run:

~~~bash
cd /Users/enrico/Documents/GitHub/saiity
git remote set-url origin git@github.com:enrzh/sAiity-source.git
git remote get-url origin
~~~

Expected: git@github.com:enrzh/sAiity-source.git.

- [ ] **Step 3: Push the latest source commit and tags to the renamed private remote.**

Run:

~~~bash
cd /Users/enrico/Documents/GitHub/saiity
git push origin main --tags
~~~

Expected: main and the existing tags are accepted by enrzh/sAiity-source.

- [ ] **Step 4: Verify the source repository is private and complete.**

Run:

~~~bash
gh repo view enrzh/sAiity-source --json nameWithOwner,visibility,defaultBranchRef,isArchived
gh api repos/enrzh/sAiity-source/commits/main --jq '.sha'
gh api repos/enrzh/sAiity-source/git/ref/tags/v2.0.0 --jq '.object.sha'
~~~

Expected: visibility PRIVATE, main resolves to the current source commit, and
the v2.0.0 tag exists. Do not create the public replacement until this check
passes.

---

### Task 3: Build the public presentation repository

**Files:**
- Create: /Users/enrico/Documents/GitHub/saiity-public/README.md
- Create: /Users/enrico/Documents/GitHub/saiity-public/privacy.html
- Create: /Users/enrico/Documents/GitHub/saiity-public/en/privacy.html
- Create: /Users/enrico/Documents/GitHub/saiity-public/screenshots/01-bubble.png
- Create: /Users/enrico/Documents/GitHub/saiity-public/screenshots/02-subtitles.png
- Create: /Users/enrico/Documents/GitHub/saiity-public/screenshots/03-models.png
- Create: /Users/enrico/Documents/GitHub/saiity-public/screenshots/04-library.png
- Create: /Users/enrico/Documents/GitHub/saiity-public/screenshots/icon.png

**Interfaces:**
- Consumes: reviewed screenshots from /Users/enrico/Documents/GitHub/saiity/docs/screenshots/, the app icon from /Users/enrico/Documents/GitHub/saiity/Resources/AppIcon.icns, and the approved public copy.
- Produces: a standalone public product page with no source history.

- [ ] **Step 1: Create the presentation directory without copying the source repository.**

Run:

~~~bash
mkdir -p /Users/enrico/Documents/GitHub/saiity-public/en
mkdir -p /Users/enrico/Documents/GitHub/saiity-public/screenshots
~~~

Do not run cp -R on the source checkout and do not initialize the public
directory from the source Git repository.

- [ ] **Step 2: Copy only reviewed visual assets and convert the app icon.**

Run:

~~~bash
cp /Users/enrico/Documents/GitHub/saiity/docs/screenshots/01-bubble.png /Users/enrico/Documents/GitHub/saiity-public/screenshots/01-bubble.png
cp /Users/enrico/Documents/GitHub/saiity/docs/screenshots/02-subtitles.png /Users/enrico/Documents/GitHub/saiity-public/screenshots/02-subtitles.png
cp /Users/enrico/Documents/GitHub/saiity/docs/screenshots/03-models.png /Users/enrico/Documents/GitHub/saiity-public/screenshots/03-models.png
cp /Users/enrico/Documents/GitHub/saiity/docs/screenshots/04-library.png /Users/enrico/Documents/GitHub/saiity-public/screenshots/04-library.png
sips -s format png /Users/enrico/Documents/GitHub/saiity/Resources/AppIcon.icns --out /Users/enrico/Documents/GitHub/saiity-public/screenshots/icon.png
~~~

Expected: five PNG files exist and no .icns, .app, or build directory is
present in the public tree.

- [ ] **Step 3: Create the public README as the product page.**

Use apply_patch to create README.md with this content and no source links:

~~~markdown
<p align="center">
  <img src="screenshots/icon.png" width="120" alt="sAiity">
</p>

<h1 align="center">sAiity</h1>

<p align="center">Live subtitles for whatever your Mac is playing.</p>

<p align="center"><a href="https://github.com/enrzh/sAiity/releases/tag/v2.0.0">Download sAiity 2.0</a> · <a href="https://enrzh.github.io/sAiity/privacy.html">Privacy</a> · <a href="https://aiity.de">Part of the aiity family</a></p>

<hr>

<p align="center">
  <img src="screenshots/01-bubble.png" width="92%" alt="sAiity caption bubble with translation">
</p>

<p align="center">
  <img src="screenshots/02-subtitles.png" width="32%" alt="Caption settings">
  <img src="screenshots/03-models.png" width="32%" alt="Local speech and translation models">
  <img src="screenshots/04-library.png" width="32%" alt="Saved transcript library">
</p>

## What it is

sAiity listens to the audio your Mac is playing, recognises speech on-device,
and shows a stable caption bubble above the screen. Translation can appear as a
second line. Saved sessions keep the original and translated text together.

## What it does

**Captions stay local.** Screen audio is recognised on the Mac. There is no
account, no API key, and no audio upload.

**Translation stays local.** Choose the broad-coverage MADLAD engine, the
Hy-MT2 translation specialist, or a supported local GGUF model.

**Transcripts stay useful.** Save sessions only when you choose to. Read them
inside the app and export bilingual SRT, WebVTT, Markdown, or plain text.

**Dictation is press-to-talk.** Hold the configured key, speak, and release.
The result is inserted into the focused text field when possible and always
kept on the clipboard.

## Requirements

macOS 26 or later on Apple Silicon. Screen Recording permission is required for
system-audio captions. Accessibility permission is only needed to insert
dictation into another app; clipboard fallback works without it.

## Privacy

Recognition, translation, dictation, and saved transcripts run on-device. The
microphone is opened for captions only when its explicit setting is enabled,
and for dictation only while the press-to-talk key is held. Models are downloaded
from their declared sources; update checks are opt-in.

Read the full [privacy policy](https://enrzh.github.io/sAiity/privacy.html).

## Status

sAiity 2.0 is released for macOS 26 and Apple Silicon. Windows is not a
supported release target.

## Source

This repository is the public product presentation. The implementation source
is kept in a private repository. No source code or reuse license is provided
here.

---

<p align="center"><sub>Built as part of the <a href="https://aiity.de">aiity</a> family.</sub></p>
~~~

- [ ] **Step 4: Create the privacy pages.**

Use the existing hAiity privacy-page CSS structure, changing the product-specific
content to these factual sAiity statements. Keep both files static, responsive,
system-font based, and free of external scripts, fonts, cookies, analytics, or
tracking pixels:

~~~text
German title: Datenschutzerklärung - sAiity
English title: Privacy Policy - sAiity

Short summary in both languages:
sAiity has no account and no audio-upload service. Speech recognition,
translation, dictation, and saved transcripts run on the Mac. The optional
caption microphone mixer is off by default, and dictation opens the microphone
only while the configured press-to-talk key is held.

Required sections:
1. Verantwortlich und Kontakt / Who is responsible and contact
2. Keine Konten, kein Tracking / No accounts, no tracking
3. Audio processing on the Mac
4. Optional microphone access for captions and dictation
5. Models and downloads
6. Saved transcripts and exports
7. Update checks
8. This static website
9. Rights and changes
~~~

The pages must link back to the public README, https://aiity.de, and the other
language page. They must not claim that the microphone is never opened.

- [ ] **Step 5: Inspect the public directory before initializing Git.**

Run:

~~~bash
cd /Users/enrico/Documents/GitHub/saiity-public
find . -maxdepth 3 -type f -print | sort
rg -n 'Sources/|Tests/|Package\.swift|\.build|private key|password|api[_-]?key|bearer|ghp_|sk-' . || true
~~~

Expected: only the README, two privacy pages, and five PNG assets exist; the
secret/source scan returns no matches.

- [ ] **Step 6: Initialize and inspect the public repository commit.**

Run:

~~~bash
cd /Users/enrico/Documents/GitHub/saiity-public
git init -b main
git add README.md privacy.html en/privacy.html screenshots/
git diff --cached --check
git diff --cached --name-status
git diff --cached --stat
git commit -m 'docs: create sAiity public product page'
~~~

Expected: the first commit contains only presentation files and no source
history.

---

### Task 4: Create and publish the public repository

**Files:**
- Remote repository: enrzh/sAiity
- Local repository: /Users/enrico/Documents/GitHub/saiity-public

**Interfaces:**
- Consumes: the presentation commit from Task 3.
- Produces: public enrzh/sAiity with its main branch and GitHub Pages source.

- [ ] **Step 1: Create the empty public repository.**

Run from the public presentation directory:

~~~bash
cd /Users/enrico/Documents/GitHub/saiity-public
gh repo create enrzh/sAiity \
  --public \
  --description 'Live on-device subtitles, translation, transcripts, and press-to-talk dictation for macOS.' \
  --homepage https://aiity.de/saiity/ \
  --disable-issues \
  --disable-wiki \
  --source . \
  --remote origin \
  --push
~~~

Expected: GitHub reports https://github.com/enrzh/sAiity and the public
repository's default branch is main.

- [ ] **Step 2: Enable GitHub Pages from main root.**

Run:

~~~bash
gh api --method POST repos/enrzh/sAiity/pages \
  -f 'source[branch]=main' \
  -f 'source[path]=/' \
  --jq '{status,html_url,source}'
~~~

If Pages already exists, use gh api repos/enrzh/sAiity/pages and verify its
source is main and /; do not create a second Pages configuration.

Expected: html_url is https://enrzh.github.io/sAiity/ and the source is main at /.

- [ ] **Step 3: Create the public presentation tag.**

Run:

~~~bash
cd /Users/enrico/Documents/GitHub/saiity-public
git tag -a v2.0.0 -m 'sAiity 2.0'
git push origin v2.0.0
~~~

Expected: the public repository has a v2.0.0 tag pointing to the public
presentation commit, not to the private source history.

---

### Task 5: Recreate and verify the public v2.0.0 release

**Files:**
- Read only: /Users/enrico/Documents/GitHub/saiity/build/RELEASE_NOTES_2.0.0.md
- Read only: /Users/enrico/Documents/GitHub/saiity/build/sAiity-2.0.0.zip
- Read only: /Users/enrico/Documents/GitHub/saiity/build/sAiity-2.0.0.dmg

**Interfaces:**
- Consumes: the verified release artifacts and public tag.
- Produces: public GitHub release enrzh/sAiity:v2.0.0 with the same download URL.

- [ ] **Step 1: Create the public release record.**

Run:

~~~bash
gh release create v2.0.0 \
  --repo enrzh/sAiity \
  --verify-tag \
  --title 'sAiity 2.0' \
  --notes-file /Users/enrico/Documents/GitHub/saiity/build/RELEASE_NOTES_2.0.0.md
~~~

Expected: the release is published, not draft and not prerelease.

- [ ] **Step 2: Upload the exact verified artifacts.**

Run:

~~~bash
gh release upload v2.0.0 /Users/enrico/Documents/GitHub/saiity/build/sAiity-2.0.0.zip --repo enrzh/sAiity
gh release upload v2.0.0 /Users/enrico/Documents/GitHub/saiity/build/sAiity-2.0.0.dmg --repo enrzh/sAiity
~~~

Expected: exactly two assets with names sAiity-2.0.0.zip and sAiity-2.0.0.dmg.

- [ ] **Step 3: Verify release metadata and asset sizes.**

Run:

~~~bash
gh release view v2.0.0 --repo enrzh/sAiity --json tagName,name,isDraft,isPrerelease,assets,url \
  --jq '{tagName,name,isDraft,isPrerelease,url,assets:[.assets[]|{name,size,url}]}'
gh api repos/enrzh/sAiity/releases/latest --jq '{tag_name,name,draft,prerelease,html_url}'
~~~

Expected: latest tag is v2.0.0, the release is published, the URL is
https://github.com/enrzh/sAiity/releases/tag/v2.0.0, and sizes are 20,893,030
and 21,571,480 bytes.

- [ ] **Step 4: Verify public downloads and hashes.**

Run:

~~~bash
curl -fsSL -o /tmp/public-saiity-2.0.0.zip https://github.com/enrzh/sAiity/releases/download/v2.0.0/sAiity-2.0.0.zip
curl -fsSL -o /tmp/public-saiity-2.0.0.dmg https://github.com/enrzh/sAiity/releases/download/v2.0.0/sAiity-2.0.0.dmg
shasum -a 256 /tmp/public-saiity-2.0.0.zip /tmp/public-saiity-2.0.0.dmg
~~~

Expected: hashes equal the Task 1 values exactly. If either hash differs, do
not post; remove the incorrect asset and retry with the verified file.

---

### Task 6: Verify Pages and public/private boundaries

**Files:**
- Read only: https://enrzh.github.io/sAiity/
- Read only: https://enrzh.github.io/sAiity/privacy.html
- Read only: https://enrzh.github.io/sAiity/en/privacy.html
- Read only: https://github.com/enrzh/sAiity-source

**Interfaces:**
- Consumes: public repository and release from Tasks 4 and 5.
- Produces: evidence that public pages work and source code is private.

- [ ] **Step 1: Poll GitHub Pages until the site is served.**

Run:

~~~bash
curl -fsSL -D /tmp/saiity-pages-headers.txt https://enrzh.github.io/sAiity/ -o /tmp/saiity-pages.html
curl -fsSL https://enrzh.github.io/sAiity/privacy.html -o /tmp/saiity-privacy.html
curl -fsSL https://enrzh.github.io/sAiity/en/privacy.html -o /tmp/saiity-privacy-en.html
rg -n 'sAiity|Download sAiity|Privacy|macOS 26|source' /tmp/saiity-pages.html /tmp/saiity-privacy.html /tmp/saiity-privacy-en.html
~~~

Expected: all three requests return HTTP 200 and contain the public product
content. Do not post while Pages is still serving a 404 or stale placeholder.

- [ ] **Step 2: Confirm the public GitHub tree contains no source.**

Run:

~~~bash
gh api 'repos/enrzh/sAiity/git/trees/main?recursive=1' --jq '.tree[] | select(.type=="blob") | .path'
~~~

Expected: only README.md, privacy.html, en/privacy.html, and files under
screenshots/ are listed. No Sources/, Tests/, Package.swift, .build/, or
source-history commit is present.

- [ ] **Step 3: Confirm the source repository is private.**

Run:

~~~bash
gh repo view enrzh/sAiity-source --json visibility,nameWithOwner
curl -sS -o /tmp/saiity-private-anonymous.json -w '%{http_code}\n' https://api.github.com/repos/enrzh/sAiity-source
~~~

Expected: authenticated gh reports PRIVATE; the unauthenticated API request
returns 404 or another non-success response.

---

### Task 7: Publish the approved X posts

**Files:**
- No repository files.
- External target: X account @aiityapp.
- External target: X account @foreseeingx.

**Interfaces:**
- Consumes: verified public release URL and public Pages content.
- Produces: one English release post and one Chinese repost or quote with final URLs.

- [ ] **Step 1: Reuse ego-browser task space 29 and verify account selection.**

Run through ego-browser:

~~~javascript
const task = await useOrCreateTaskSpace(29)
const tabs = await listTabs()
cliLog(JSON.stringify(tabs))
~~~

Expected: the task space uses the Xianjie profile and has the @aiityapp and
@foreseeingx tabs. If the account selector is wrong or unavailable, stop.

- [ ] **Step 2: Publish the English post from @aiityapp.**

Use exactly:

~~~text
sAiity 2.0 is out for macOS 26 on Apple Silicon. Live on-device captions, translation, bilingual transcripts, and press-to-talk dictation. No account, no API key, no audio leaves the Mac. Download: https://github.com/enrzh/sAiity/releases/tag/v2.0.0
~~~

After posting, read the rendered post and record its final URL.

- [ ] **Step 3: Publish the Chinese repost or quote from @foreseeingx.**

Use exactly:

~~~text
sAiity 2.0 已发布：在 Mac 本地运行的实时字幕、翻译、双语转录和按住说话听写。无需账号或 API 密钥，音频不离开设备。macOS 26 + Apple Silicon：https://github.com/enrzh/sAiity/releases/tag/v2.0.0
~~~

After posting, read the rendered post and record its final URL. Do not substitute
another account or alter the approved copy.

- [ ] **Step 4: Verify both final posts and the release link.**

Use ego-browser to open each final URL and confirm the rendered text contains the
public v2.0.0 release URL. Leave the task space open only if the user needs to
inspect the posts; otherwise complete it with keep: false.

---

### Task 8: Final audit and handoff

**Files:**
- Read only: /Users/enrico/Documents/GitHub/saiity
- Read only: /Users/enrico/Documents/GitHub/saiity-public

- [ ] **Step 1: Verify both local repositories.**

Run:

~~~bash
git -C /Users/enrico/Documents/GitHub/saiity status -sb
git -C /Users/enrico/Documents/GitHub/saiity remote -v
git -C /Users/enrico/Documents/GitHub/saiity-public status -sb
git -C /Users/enrico/Documents/GitHub/saiity-public remote -v
~~~

Expected: source points at sAiity-source and is clean; public points at sAiity
and contains only its presentation commit.

- [ ] **Step 2: Record final migration evidence.**

Report the private source URL, public showcase URL, public release URL, public
artifact hashes, Pages URLs, and both X post URLs. State separately which facts
were verified locally, through authenticated GitHub API calls, through public
HTTP requests, and through ego-browser.

- [ ] **Step 3: Keep the source and presentation repositories separate.**

Do not add public presentation files back into the private source checkout, and
do not rewrite the source history after the private remote is verified.
