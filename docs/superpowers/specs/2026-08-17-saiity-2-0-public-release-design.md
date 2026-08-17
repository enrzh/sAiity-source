# sAiity 2.0 Public Release Design

## Goal

Publish the current macOS-only sAiity 2.0 work, refresh its product-facing repository and screenshots, and align the aiity.de and me.aiity.de public surfaces with the product's new source-available posture.

## Decisions

- Keep `enrzh/sAiity` public so people can inspect the implementation, download releases, and report problems.
- Remove the repository's current MIT license and contributor framing. The repository will state plainly that it is public for inspection and that no reuse license is granted. Git history is preserved; no history rewrite or repository-visibility change is allowed.
- Use the concise hAiity repository pattern: product identity first, privacy and operating model next, a short capability list, build/release instructions, and the aiity family link.
- Ship the current 2.0 macOS feature set only: press-to-talk dictation and opt-in Hy-MT2 translation, alongside the already committed 2.0 groundwork. Windows remains a prototype/history item and is not presented as a product or release target.
- Keep MADLAD as the recommended translation engine. Hy-MT2 remains an explicit opt-in model.

## Repository Changes

The sAiity repository will receive a focused README rewrite, 2.0 release notes, and updated screenshots captured from the running signed app. `LICENSE` and `CONTRIBUTING.md` are removed from the current tree because they grant or invite rights that the new posture explicitly withdraws. Security reporting remains available through a concise README contact path and the existing security guidance unless the final review shows it makes a conflicting license claim.

No unrelated source refactor is part of this release. Existing dictation and Hy-MT2 modifications are staged by exact path, not with a blanket add. The release is tagged only after the full release test command, release build, real model verification already recorded for Hy-MT2, and visual app inspection succeed.

## Screenshot Set

The four README images will show the current product rather than the 1.2-era state:

1. the caption bubble with source and translated lines;
2. Captions settings with the current recognition and translation choices;
3. Dictation settings and the compact press-to-talk state surface;
4. the saved-transcripts page with a bilingual session visible.

Images must be captured from the installed app at a stable desktop size and reviewed visually. Generated mockups, code-only claims, and stale screenshots are not acceptable.

## Website Changes

`aiity-web` remains the source of truth for aiity.de. Its existing family-page work is retained and completed in place. The site will describe sAiity 2.0 as a signed macOS download, mention on-device captions, translation, and press-to-talk dictation, and replace “open source” claims with language that accurately describes public inspection without granting a reuse license. The generated `public/` tree is rebuilt from `src/content.js`; it is not hand-edited.

`apps_nas/me-aiity` remains the source of truth for me.aiity.de inside the apps_nas repository. Its project listing and GitHub command will use the same source-available wording and current sAiity 2.0 description. Only the me-aiity paths are eligible for this work; unrelated dirty Lexware changes are excluded.

Each website is deployed using its existing repository-specific mechanism, then checked over HTTPS for the changed page, links, and expected status. The aiity.de deploy must preserve the `/saiity/` release/appcast directory.

## Release and Public Posts

After verification, sAiity changes are committed, pushed to `main`, tagged `v2.0.0`, and published as a GitHub release with the 2.0 notes and current downloadable artifacts if the release build produces them. Website commits and the me-aiity parent-repository commit are pushed separately so their histories remain attributable.

The X copy is prepared as two short posts: an English release announcement for `@aiityapp` and a Chinese repost/quote from `@foreseeingx`. The exact text and links are shown for confirmation immediately before publication. No post is sent without that final confirmation.

## Verification

- `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS`
- `swift build -c release`
- `./build-app.sh` and inspection of the resulting signed app
- `git diff --check` in each changed repository
- Screenshot inspection from the running app
- Website build plus live HTTPS checks for `aiity.de` and `me.aiity.de`
- Git status and staged-path review before each commit

## Out of Scope

- A Windows client or Windows release.
- Making the GitHub repository private.
- Rewriting or deleting public Git history.
- Changing translation defaults or claiming benchmark superiority without fresh evidence.
- Publishing X content before the final copy is shown to the user.
