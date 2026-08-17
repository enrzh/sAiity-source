# sAiity Public Repository Split Design

## Goal

Separate the sAiity implementation from its public product presentation while
preserving the existing public download URL and the verified 2.0.0 release.

The implementation repository will become `enrzh/sAiity-source` and private.
The public `enrzh/sAiity` repository will become a curated product "shop window"
in the same style as hAiity: README-led presentation, selected screenshots,
privacy pages, and public release artifacts, with no source tree.

## Current state

- The current checkout is `/Users/enrico/Documents/GitHub/saiity`.
- Its remote is `git@github.com:enrzh/sAiity.git`.
- `main` and tag `v2.0.0` point to commit `03d8568`.
- GitHub release `v2.0.0` is published on the current public repository.
- `build/sAiity-2.0.0.zip` and `build/sAiity-2.0.0.dmg` are notarized, stapled,
  and independently verified.
- The current release assets have these verified values:
  - ZIP: 20,893,030 bytes; SHA-256
    `5062ea1eb6dd2cd3adeb232894421ce2d620ab7cda7fa5b40308fc5b5efbf3b9`
  - DMG: 21,571,480 bytes; SHA-256
    `3125395307a0eb1a6ff71a4d5ac20009564491cc67e5bb093b39eead4a38c55f`

## Decisions

### Repository identities

The existing repository is renamed to `enrzh/sAiity-source` and changed to
private. Its complete Git history, tags, source, tests, build scripts, and
private release record remain intact. The local checkout keeps this history and
changes its `origin` URL to `git@github.com:enrzh/sAiity-source.git`.

A new public repository is created at `enrzh/sAiity`. It is intentionally not a
fork, mirror, or filtered copy of the source repository. Its history starts as
the public product presentation so the GitHub tree cannot expose source through
old commits.

### Public repository contents

The public repository contains only:

- `README.md`, written as the primary product page;
- `screenshots/`, containing the four reviewed sAiity UI screenshots and an app
  icon image;
- `privacy.html` and `en/privacy.html`, containing the privacy statement in the
  same structure as hAiity;
- minimal repository metadata needed for GitHub Pages.

It does not contain `Sources/`, `Tests/`, `Package.swift`, `.build/`, release
scripts, private design notes, credentials, or a source license. The README
states plainly that the source repository is private. The public presentation
does not claim that the implementation is open source or reusable.

### Download continuity

The existing `v2.0.0` release URL must remain public:

`https://github.com/enrzh/sAiity/releases/tag/v2.0.0`

After the rename, that URL belongs to the new public presentation repository.
The verified ZIP and DMG are therefore attached to a new public `v2.0.0`
release in `enrzh/sAiity`, using the existing release notes and the exact
verified artifact bytes. The old release remains with the now-private source
repository and is not used for public distribution.

### Pages and visual direction

The public repository follows hAiity's restrained product-page pattern rather
than becoming a second application website:

- centered product identity and one-sentence promise;
- generous whitespace and native-looking screenshots;
- light and dark UI screenshots shown together where useful;
- short sections for capabilities, privacy, requirements, and status;
- direct links to the public release, aiity.de, and privacy pages;
- no gradients, animated marketing background, fake metrics, or generated
  product claims.

GitHub Pages renders the README at `https://enrzh.github.io/sAiity/`. The two
privacy paths are available at `/privacy.html` and `/en/privacy.html`.

### X sequencing

The X posts are sent only after the new public repository and release have been
verified from an unauthenticated/public view. The existing ego-browser task
space `29` and the Xianjie profile are reused.

The approved English post remains targeted at `@aiityapp`:

> sAiity 2.0 is out for macOS 26 on Apple Silicon. Live on-device captions,
> translation, bilingual transcripts, and press-to-talk dictation. No account,
> no API key, no audio leaves the Mac. Download:
> https://github.com/enrzh/sAiity/releases/tag/v2.0.0

The approved Chinese repost or quote remains targeted at `@foreseeingx`:

> sAiity 2.0 已发布：在 Mac 本地运行的实时字幕、翻译、双语转录和按住说话听写。无需账号或 API 密钥，音频不离开设备。macOS 26 + Apple Silicon：
> https://github.com/enrzh/sAiity/releases/tag/v2.0.0

No post is sent if the public release URL, account selection, or final copy
does not match these decisions.

## Migration order

1. Reconfirm the source checkout is clean and the two release artifact hashes
   still match this spec.
2. Rename the current GitHub repository to `sAiity-source` and set its
   visibility to private in the same controlled operation.
3. Update the local `origin` remote and verify that the source repository is
   private and contains commit `03d8568` and tag `v2.0.0`.
4. Build the public presentation directory from the reviewed screenshots and
   privacy copy. Verify that no source paths or secret-shaped values are in it.
5. Create `enrzh/sAiity` as a new public repository and push only the
   presentation files.
6. Create the public `v2.0.0` release and upload the verified ZIP and DMG.
7. Verify the public repository, release, asset sizes, asset downloads, and
   GitHub Pages paths from a public request. Verify that the private source
   repository is not readable without authentication.
8. Publish the two approved X posts through ego-browser and record their final
   URLs.

## Failure handling

- If the rename succeeds but the local remote update fails, do not create the
  public replacement until the private source repository is confirmed by its
  new URL.
- If public repository creation succeeds but the release upload fails, leave
  the public repository without a release rather than attaching unverified or
  stale files; retry with the same verified artifacts.
- If GitHub Pages does not render the README or privacy pages, fix the public
  presentation repository before posting.
- If the X account selector is not the intended account, stop and leave both
  posts unpublished.

## Acceptance criteria

- `enrzh/sAiity-source` is private and contains the complete source history.
- `enrzh/sAiity` is public and contains no source files or source history.
- Public `v2.0.0` release assets match the verified ZIP and DMG hashes.
- `https://github.com/enrzh/sAiity/releases/tag/v2.0.0` is publicly reachable.
- GitHub Pages displays the visual README and both privacy paths resolve.
- The two X posts use the approved copy, the intended accounts, and the public
  release URL.
