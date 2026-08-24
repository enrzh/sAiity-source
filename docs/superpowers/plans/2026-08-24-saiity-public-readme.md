# sAiity Public README Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Rewrite the public enrzh/sAiity README so the GitHub repository and its Pages rendering feel like an honest, restrained aiity product surface, then synchronize the repository metadata and verify both rendered surfaces.

**Architecture:** README.md is the single presentation source for the public repository and the existing GitHub Pages site. The implementation source remains in the separate private sAiity-source checkout; this work changes only the public README and GitHub repository metadata. The visual language comes from semantic Markdown, limited GitHub-supported HTML, existing screenshots, system typography, whitespace, and thin rules rather than custom CSS or decorative effects.

**Tech Stack:** GitHub-flavored Markdown, GitHub-supported HTML, GitHub Pages' existing README/Jekyll rendering, gh CLI, curl, python3, and a browser session for rendered visual verification.

## Global Constraints

- Work in /Users/enrico/Documents/GitHub/saiity-public for public-repository changes.
- Do not modify /Users/enrico/Documents/GitHub/saiity implementation source during execution; the private checkout is only the source of truth for verified product behavior and stores this plan.
- Keep README.md as the only product-page content source; do not add a second landing page or modify /Users/enrico/Documents/GitHub/aiity-web.
- Keep the current release at v2.2.4 until a later release is verified; do not write 2.2.3 into any new copy.
- Keep the Sparkle feed URL exactly https://enrzh.github.io/sAiity/appcast.xml.
- Keep privacy links on the existing public Pages files at https://enrzh.github.io/sAiity/privacy.html and https://enrzh.github.io/sAiity/en/privacy.html.
- Keep the supported target factual: macOS 26 or later on Apple Silicon; Windows is not a supported release target.
- Keep the public/private source boundary explicit. Do not imply that the public repository contains reusable implementation source or a reuse license.
- Do not add badges, emoji, animated media, gradients, glossy cards, fake metrics, unsupported CSS, or claims that audio, transcripts, or usage data reach an aiity server.
- Preserve the existing icon, 01-bubble.png, and screenshots 02-subtitles.png through 05-dictation.png unless validation proves a file is missing or unusable.
- Do not include credentials, access tokens, private URLs, or other secrets in the README, plan, commit messages, or command output.
- Before any release of this presentation change, verify the actual Pages bytes and rendered page instead of assuming a push succeeded.

## File Map

### Public checkout

- Modify: /Users/enrico/Documents/GitHub/saiity-public/README.md - the complete public product presentation and GitHub Pages source.
- Do not modify: /Users/enrico/Documents/GitHub/saiity-public/appcast.xml - already serves the verified 2.2.4 feed.
- Do not modify: /Users/enrico/Documents/GitHub/saiity-public/privacy.html and /Users/enrico/Documents/GitHub/saiity-public/en/privacy.html - existing privacy pages linked by the README.
- Do not modify: /Users/enrico/Documents/GitHub/saiity-public/screenshots/* - use the existing verified assets.

### GitHub metadata

- External state: repository description, homepage URL, and topics on enrzh/sAiity, updated with gh repo edit.

### Verification artifacts

- Temporary only: browser screenshots captured outside the repository for desktop and narrow viewport review. Do not add screenshot artifacts to the public checkout.

## Proposed README Content

Use the following complete content for /Users/enrico/Documents/GitHub/saiity-public/README.md. The only allowed substitutions are link targets that are already specified here; do not reintroduce the old 2.2.3 copy.

~~~markdown
<p align="center">
  <img src="screenshots/icon.png" width="112" alt="sAiity app icon">
</p>

<h1 align="center">sAiity</h1>

<p align="center"><strong>Speech on the machine, not in the cloud.</strong></p>

<p align="center">Live captions, translation, transcripts, and press-to-talk dictation for macOS.</p>

<p align="center">
  <a href="https://github.com/enrzh/sAiity/releases/tag/v2.2.4">Download v2.2.4</a>
  &nbsp;&middot;&nbsp;
  <a href="https://enrzh.github.io/sAiity/appcast.xml">Sparkle update feed</a>
  &nbsp;&middot;&nbsp;
  <a href="https://enrzh.github.io/sAiity/privacy.html">Privacy</a>
  &nbsp;&middot;&nbsp;
  <a href="https://aiity.de">aiity</a>
</p>

<hr>

<p align="center">
  <img src="screenshots/01-bubble.png" width="92%" alt="sAiity caption bubble showing original speech and translation">
</p>

<p align="center">
  <img src="screenshots/02-subtitles.png" width="24%" alt="sAiity subtitle settings">
  <img src="screenshots/03-models.png" width="24%" alt="sAiity local speech and translation models">
  <img src="screenshots/04-library.png" width="24%" alt="sAiity saved transcript library">
  <img src="screenshots/05-dictation.png" width="24%" alt="sAiity press-to-talk dictation settings">
</p>

## The product

| Capability | Description |
| --- | --- |
| **Captions** | Speech from your Mac's system audio becomes stable captions in a small, movable bubble. Recognition runs on the Mac. |
| **Translation** | Add a second line in another language with a local translation model. Original speech remains available. |
| **Dictation** | Hold a configurable key, speak, and release. The result is inserted into the focused field when possible and also kept on the clipboard. |
| **Transcripts** | Save sessions in the app with original and translated text together. Read them later or export SRT, WebVTT, Markdown, or plain text. |

## If something needs the network

Daily use does not. sAiity downloads the models you choose from their declared sources, then recognises and translates on-device. The signed app can check the opt-in Sparkle feed for updates. No account or API key is required.

## What we know about you

<p><strong>Nothing.</strong></p>

There is no account, tracking, telemetry, or audio upload. The microphone is opened for captions only when its explicit setting is enabled, and for dictation only while the press-to-talk key is held. Saved transcripts stay on your Mac until you export or delete them.

Read the [German privacy policy](https://enrzh.github.io/sAiity/privacy.html) or [English privacy policy](https://enrzh.github.io/sAiity/en/privacy.html).

## Requirements and status

| Requirement | Details |
| --- | --- |
| **System** | macOS 26 or later on Apple Silicon. |
| **Captions** | Screen Recording permission for system-audio capture. |
| **Dictation** | Microphone permission while the push-to-talk key is held. Accessibility permission is needed for insertion into another app; clipboard fallback works without it. |
| **Release** | v2.2.4 is the current signed release. Windows is not supported. |

## Updates

GitHub Releases is the canonical download location. Sparkle reads the signed [appcast.xml](https://enrzh.github.io/sAiity/appcast.xml) from this GitHub Pages site, and the feed points to the matching ZIP in the GitHub Release.

Publish release assets before updating the feed. The feed is served from the main branch of this public repository.

## Source

This repository is the public product page and download surface. The implementation source is kept in a private repository. No source code or reuse license is provided here.

<hr>

<p align="center"><sub>Part of the <a href="https://aiity.de">aiity</a> family.</sub></p>
~~~

## Implementation Tasks

### Task 1: Rewrite the public README

**Files:**

- Modify: /Users/enrico/Documents/GitHub/saiity-public/README.md
- Read-only reference: /Users/enrico/Documents/GitHub/saiity-public/screenshots/01-bubble.png
- Read-only reference: /Users/enrico/Documents/GitHub/saiity-public/screenshots/02-subtitles.png
- Read-only reference: /Users/enrico/Documents/GitHub/saiity-public/screenshots/03-models.png
- Read-only reference: /Users/enrico/Documents/GitHub/saiity-public/screenshots/04-library.png
- Read-only reference: /Users/enrico/Documents/GitHub/saiity-public/screenshots/05-dictation.png
- Read-only reference: /Users/enrico/Documents/GitHub/saiity-public/screenshots/icon.png

**Interfaces:**

- Consumes: the existing public screenshots, privacy pages, appcast URL, and verified v2.2.4 release.
- Produces: a README whose exact content is the complete block in the Proposed README Content section above.

- [ ] **Step 1: Confirm the public checkout is still clean and the assets still exist.**

Run:

~~~bash
git -C /Users/enrico/Documents/GitHub/saiity-public status --short
test -f /Users/enrico/Documents/GitHub/saiity-public/screenshots/icon.png
test -f /Users/enrico/Documents/GitHub/saiity-public/screenshots/01-bubble.png
test -f /Users/enrico/Documents/GitHub/saiity-public/screenshots/02-subtitles.png
test -f /Users/enrico/Documents/GitHub/saiity-public/screenshots/03-models.png
test -f /Users/enrico/Documents/GitHub/saiity-public/screenshots/04-library.png
test -f /Users/enrico/Documents/GitHub/saiity-public/screenshots/05-dictation.png
~~~

Expected: no status output and six successful test commands.

- [ ] **Step 2: Replace the README with the approved product presentation.**

Write the complete Proposed README Content block above to /Users/enrico/Documents/GitHub/saiity-public/README.md. Keep the image order, exact link targets, two specification tables, explicit privacy language, and public/private source boundary. Do not add CSS, shields, badges, or a second HTML page.

- [ ] **Step 3: Check the document for malformed Markdown and accidental stale copy.**

Run:

~~~bash
cd /Users/enrico/Documents/GitHub/saiity-public
git diff --check
if rg -n '2\.2\.3|aiity\.de/saiity/' README.md; then
  exit 1
fi
rg -n 'v2\.2\.4|enrzh\.github\.io/sAiity/appcast\.xml|privacy\.html|The product|What we know about you|private repository' README.md
~~~

Expected: git diff --check is silent; the stale-copy scan exits successfully without output; the final rg prints the required current release, links, sections, and source-boundary lines.

- [ ] **Step 4: Commit the README-only change.**

Run:

~~~bash
cd /Users/enrico/Documents/GitHub/saiity-public
git add README.md
git commit -m "docs: refresh public sAiity README"
~~~

Expected: one commit containing only README.md. Do not include screenshots, the appcast, privacy pages, or generated files.

### Task 2: Synchronize GitHub repository metadata

**Files:**

- External metadata: https://github.com/enrzh/sAiity repository description, homepage, and topics.
- Read-only verification: /Users/enrico/Documents/GitHub/saiity-public/README.md

**Interfaces:**

- Consumes: the public repository name enrzh/sAiity and the exact metadata values below.
- Produces: repository metadata matching the README and the aiity Pages surface.

- [ ] **Step 1: Set the description and homepage.**

Run:

~~~bash
gh repo edit enrzh/sAiity \
  --description 'Live on-device captions, translation, transcripts, and press-to-talk dictation for macOS on Apple Silicon.' \
  --homepage 'https://enrzh.github.io/sAiity/'
~~~

Expected: the command exits zero and the homepage is the live GitHub Pages URL, not the stale https://aiity.de/saiity/ path.

- [ ] **Step 2: Add the approved repository topics.**

Run:

~~~bash
for topic in macos swift captions dictation translation transcripts privacy on-device; do
  gh repo edit enrzh/sAiity --add-topic "$topic"
done
~~~

Expected: every command exits zero; no unrelated topics are added.

- [ ] **Step 3: Verify the metadata through GitHub.**

Run:

~~~bash
gh repo view enrzh/sAiity --json description,homepageUrl,repositoryTopics \
  --jq '{description: .description, homepage: .homepageUrl, topics: [.repositoryTopics[].name]}'
~~~

Expected JSON:

~~~json
{
  "description": "Live on-device captions, translation, transcripts, and press-to-talk dictation for macOS on Apple Silicon.",
  "homepage": "https://enrzh.github.io/sAiity/",
  "topics": [
    "macos",
    "swift",
    "captions",
    "dictation",
    "translation",
    "transcripts",
    "privacy",
    "on-device"
  ]
}
~~~

The topic array may be returned in a different order; its set must match exactly.

### Task 3: Validate local assets and external links

**Files:**

- Read-only: /Users/enrico/Documents/GitHub/saiity-public/README.md
- Read-only: /Users/enrico/Documents/GitHub/saiity-public/screenshots/*
- Read-only: /Users/enrico/Documents/GitHub/saiity-public/privacy.html
- Read-only: /Users/enrico/Documents/GitHub/saiity-public/en/privacy.html
- Read-only: /Users/enrico/Documents/GitHub/saiity-public/appcast.xml

**Interfaces:**

- Consumes: README image paths and the exact external URLs in the approved content.
- Produces: evidence that every local asset exists and every critical public URL resolves.

- [ ] **Step 1: Validate every local image reference against the checkout.**

Run:

~~~bash
cd /Users/enrico/Documents/GitHub/saiity-public
python3 - <<'PY'
from pathlib import Path
import re

readme = Path('README.md').read_text(encoding='utf-8')
paths = re.findall(r'<img[^>]+src="([^"]+)"', readme)
expected = {
    'screenshots/icon.png',
    'screenshots/01-bubble.png',
    'screenshots/02-subtitles.png',
    'screenshots/03-models.png',
    'screenshots/04-library.png',
    'screenshots/05-dictation.png',
}
assert set(paths) == expected, (paths, expected)
missing = [path for path in paths if not Path(path).is_file()]
assert not missing, missing
print(f'{len(paths)} README images present')
PY
~~~

Expected: 6 README images present.

- [ ] **Step 2: Check every critical public URL.**

Run:

~~~bash
for url in \
  'https://github.com/enrzh/sAiity/releases/tag/v2.2.4' \
  'https://enrzh.github.io/sAiity/appcast.xml' \
  'https://enrzh.github.io/sAiity/privacy.html' \
  'https://enrzh.github.io/sAiity/en/privacy.html' \
  'https://enrzh.github.io/sAiity/' \
  'https://aiity.de'; do
  printf '%s\n' "$url"
  curl --fail --silent --show-error --location --head --max-time 20 "$url" >/dev/null
done
~~~

Expected: every URL returns a successful response. A redirect is acceptable; an error response is not.

- [ ] **Step 3: Verify the appcast still describes the current release.**

Run:

~~~bash
curl --fail --silent --show-error --location https://enrzh.github.io/sAiity/appcast.xml \
  | rg -n 'sparkle:version="2\.2\.4"|github\.com/enrzh/sAiity/releases/download/v2\.2\.4/'
~~~

Expected: at least one matching 2.2.4 version line and one matching GitHub Release ZIP URL. Do not modify appcast.xml as part of this README task.

### Task 4: Push and verify GitHub Pages deployment

**Files:**

- External deployment: the main branch of https://github.com/enrzh/sAiity.
- Read-only verification: /Users/enrico/Documents/GitHub/saiity-public/README.md and rendered Pages output.

**Interfaces:**

- Consumes: the README commit from Task 1 and verified metadata from Task 2.
- Produces: a live Pages page at https://enrzh.github.io/sAiity/ rendering the new README.

- [ ] **Step 1: Push the README commit.**

Run:

~~~bash
git -C /Users/enrico/Documents/GitHub/saiity-public push origin main
~~~

Expected: the commit created in Task 1 is accepted by origin/main.

- [ ] **Step 2: Inspect the latest Pages build state.**

Run:

~~~bash
gh api repos/enrzh/sAiity/pages/builds/latest \
  --jq '{status: .status, error: .error.message, commit: .commit, pusher: .pusher.login, created: .created_at, updated: .updated_at}'
~~~

Expected: status is built, error is empty or null, and commit matches the pushed README commit. If the status is still building, poll the same endpoint until it is built or reports an error; do not call the deployment complete before built is observed.

- [ ] **Step 3: Confirm the deployed README bytes contain the new content.**

Run:

~~~bash
curl --fail --silent --show-error --location https://enrzh.github.io/sAiity/ \
  | rg -n 'Speech on the machine, not in the cloud\.|Download v2\.2\.4|The product|What we know about you|private repository'
~~~

Expected: all five phrases are present in the deployed HTML.

### Task 5: Perform visual verification on desktop and narrow viewports

**Files:**

- Read-only URL: https://enrzh.github.io/sAiity/
- Temporary artifacts: browser screenshots outside the repository.

**Interfaces:**

- Consumes: the deployed Pages site from Task 4.
- Produces: visual evidence that the layout is readable, restrained, and usable at both viewport sizes.

- [ ] **Step 1: Inspect the desktop rendering.**

Open https://enrzh.github.io/sAiity/ in the browser at a 1440 x 1100 viewport and capture a screenshot outside the repository. Check the rendered page itself, not the local Markdown. Confirm:

1. The icon, wordmark, tagline, and action links form a quiet centered opening.
2. The caption-bubble image is readable without dominating the page.
3. The four-image strip remains evenly spaced and does not overflow.
4. The two-column product and requirements tables align labels and descriptions cleanly.
5. The Nothing. privacy statement reads as a deliberate pull line rather than a card or badge.
6. There are no gradients, browser error blocks, broken images, or visible raw HTML fragments.

Expected: the page reads as a restrained product document with clear hierarchy and no overlapping or clipped content.

- [ ] **Step 2: Inspect the narrow rendering.**

Open the same URL at a 390 x 844 viewport and capture a screenshot outside the repository. Confirm:

1. The centered hero does not clip or force horizontal scrolling.
2. The action links wrap without overlapping.
3. The large screenshot and four-image strip remain within the viewport.
4. Each table becomes readable as stacked label and description rows.
5. The footer link remains visible and tappable.

Expected: no horizontal overflow, clipped text, overlapping controls, or unreadable table rows.

- [ ] **Step 3: Inspect the GitHub repository rendering.**

Open https://github.com/enrzh/sAiity at a desktop viewport and confirm that GitHub's README renderer shows the same hero, screenshots, tables, links, privacy language, and source-boundary statement. Verify that all local image paths resolve on GitHub as well as Pages.

Expected: repository rendering and Pages rendering contain the same content and no broken image placeholders.

### Task 6: Final repository and deployment checks

**Files:**

- Read-only: /Users/enrico/Documents/GitHub/saiity-public
- Read-only: /Users/enrico/Documents/GitHub/saiity

**Interfaces:**

- Consumes: all changes and verification results from Tasks 1 through 5.
- Produces: clean checkouts, a clean diff, and an auditable final state.

- [ ] **Step 1: Re-run the content and whitespace checks after deployment.**

Run:

~~~bash
git -C /Users/enrico/Documents/GitHub/saiity-public diff --check
if rg -n '2\.2\.3|aiity\.de/saiity/' /Users/enrico/Documents/GitHub/saiity-public/README.md; then
  exit 1
fi
~~~

Expected: no whitespace errors and no stale release or homepage references.

- [ ] **Step 2: Verify the public checkout contains only the intended commit and files.**

Run:

~~~bash
git -C /Users/enrico/Documents/GitHub/saiity-public status --short --branch
git -C /Users/enrico/Documents/GitHub/saiity-public show --stat --oneline HEAD
~~~

Expected: the public checkout is clean on main, and the latest commit changes only README.md.

- [ ] **Step 3: Verify the private source checkout has no accidental implementation changes.**

Run:

~~~bash
git -C /Users/enrico/Documents/GitHub/saiity status --short --branch
git -C /Users/enrico/Documents/GitHub/saiity diff --name-only
~~~

Expected: no implementation files are modified by this work. The plan commit may be present in the private branch, but there must be no working-tree changes.

- [ ] **Step 4: Record the final evidence before reporting completion.**

Record the public README commit SHA, the metadata JSON, the Pages build status and deployed commit, the URLs checked, and the two visual viewport checks. Report any item that could not be verified as unverified; do not call the presentation update complete based only on local Markdown inspection.

## Self-Review Checklist

- [ ] Spec coverage: the README structure, current release links, screenshots, product table, network section, privacy statement, requirements, status, source boundary, metadata, link checks, Pages verification, repository verification, and viewport checks all have explicit tasks.
- [ ] Placeholder scan: this plan contains no TBD, TODO, fill in, or unspecified implementation steps.
- [ ] Type and path consistency: every command uses /Users/enrico/Documents/GitHub/saiity-public for public changes, enrzh/sAiity for GitHub metadata, and /Users/enrico/Documents/GitHub/saiity only for private-checkout cleanliness verification.
- [ ] Boundary review: no task modifies the private implementation source, aiity-web, the appcast, privacy pages, or screenshots.
- [ ] Release truth: all README and verification references use the currently verified v2.2.4 release and Pages appcast.

## Execution Handoff

After this plan is approved, use one of the following execution paths:

1. **Subagent-driven execution (recommended):** dispatch a fresh worker for each task with review checkpoints between tasks, using the subagent-driven-development skill.
2. **Inline execution:** execute the tasks in this session with the executing-plans skill and stop at the verification checkpoints for review.
