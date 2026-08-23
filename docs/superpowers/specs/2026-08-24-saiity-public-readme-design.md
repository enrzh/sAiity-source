# sAiity Public README Design

## Purpose

Make the public `enrzh/sAiity` repository page feel like a product surface from the aiity family, while keeping the repository honest: it is a presentation and download page, not the implementation source. GitHub Pages already renders this README, so one maintained document should drive both surfaces.

## Verified Reference

The live aiity homepage at `https://aiity.de/` uses:

- a restrained near-black and white editorial presentation;
- system typography with generous whitespace and direct copy;
- thin rules and small uppercase section labels;
- two-column specification rows instead of decorative cards;
- short statements about local operation and privacy;
- no gradients, badges, glossy effects, or inflated marketing claims.

The current public Pages site is the README rendered through GitHub's default Jekyll theme. There is no separate product landing page to synchronize. The current repository metadata homepage, `https://aiity.de/saiity/`, returns 404 and must be replaced with the working GitHub Pages URL.

## Scope

### In scope

- Rewrite `saiity-public/README.md` using semantic Markdown and limited HTML supported by GitHub.
- Keep the existing icon, caption-bubble hero image, and four product screenshots.
- Update release links and status from `2.2.3` to the verified `2.2.4` release.
- Add a concise aiity-style product table covering captions, translation, dictation, and transcripts.
- Add compact sections for network behavior, privacy, requirements, updates, and the public/private source boundary.
- Update GitHub repository description, homepage, and topics through the GitHub repository settings API.
- Set the repository homepage to `https://enrzh.github.io/sAiity/` because it is live and the existing `https://aiity.de/saiity/` path is not.

### Out of scope

- Changes to the private sAiity implementation source.
- Changes to the aiity.de website or its CSS.
- New screenshots unless the existing screenshots fail a visual check.
- Claims that the public repository contains reusable source code.
- A new release or X post; this is a presentation update only.

## README Structure

1. **Hero**: centered icon and `sAiity` wordmark, followed by the direct statement `Speech on the machine, not in the cloud.` and a one-line product description.
2. **Actions**: links to the verified `v2.2.4` release, signed Sparkle feed, privacy policy, and aiity family homepage.
3. **Product image**: the existing caption-bubble screenshot at a readable width.
4. **Screenshot strip**: the existing subtitles, models, library, and dictation screenshots with accurate alt text.
5. **The product**: a two-column table with `Captions`, `Translation`, `Dictation`, and `Transcripts` as the left labels and concise, factual descriptions on the right.
6. **If something needs the network**: explain one-time model downloads, on-device operation, and the opt-in update check.
7. **What we know about you**: use `Nothing.` as the pull statement, then explain no account, no tracking, no audio upload, and local storage.
8. **Requirements and status**: macOS 26 or later, Apple Silicon, permissions, current release, and Windows not supported.
9. **Source**: state that the repository is public for product inspection and downloads while implementation source remains private and carries no reuse license.
10. **Footer**: one restrained aiity family link.

The README must not use shields, emoji, animated media, nested cards, gradient backgrounds, or unsupported CSS. The visual result should come from hierarchy, whitespace, rules, image scale, and copy.

## Repository Metadata

- Description: `Live on-device captions, translation, transcripts, and press-to-talk dictation for macOS on Apple Silicon.`
- Homepage: `https://enrzh.github.io/sAiity/`
- Topics: `macos`, `swift`, `captions`, `dictation`, `translation`, `transcripts`, `privacy`, `on-device`.

## Link and Content Invariants

- Every release link points to `v2.2.4` until a later release is verified.
- The Sparkle feed link remains `https://enrzh.github.io/sAiity/appcast.xml`.
- Privacy links continue to point to the public repository's existing English and German policy pages.
- The README must not imply that audio, transcripts, or usage data are sent to an aiity server.
- The public/private source boundary remains explicit.
- The app's supported target remains macOS 26 or later on Apple Silicon.

## Verification

After the README and metadata update:

1. Run `git diff --check` and scan the README for stale `2.2.3` references.
2. Verify all local image paths and external links resolve.
3. Push the public repository and wait for the Pages build to complete.
4. Open `https://enrzh.github.io/sAiity/` in a browser and inspect a desktop and narrow viewport screenshot for hierarchy, image sizing, link visibility, and overflow.
5. Open the GitHub repository page and verify its rendered README matches the same content and links.
6. Verify the repository description, homepage, and topics through `gh repo view`.
7. Leave both the public checkout and private source checkout clean after their respective commits.
