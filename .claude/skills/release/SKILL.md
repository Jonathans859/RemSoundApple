---
name: release
description: Cut a RemSound release - draft plain-text notes from commits, bump the version, create the GitHub Release (after explicit user confirmation) which triggers the signed-IPA/TestFlight workflow, then watch the run. Use when asked to "cut a release", "publish a release", "ship to TestFlight", or "make a new version".
---

# Release RemSound (GitHub Release → signed IPA → TestFlight)

Publishing a GitHub Release with tag `vX.Y.Z` triggers `.github/workflows/release.yml`:
tests → signed archive → IPA attached to the release → TestFlight upload with the release
body as the "What to Test" text. This skill prepares and publishes that release. See
`plan.md` for the one-time Apple/secrets setup this depends on.

## Hard rules

- **Creating the release and pushing are outward-facing.** Prepare everything, show the
  user the exact version + notes, and only push / `gh release create` after they say go.
- Tag format must be `vMAJOR.MINOR.PATCH` — the workflow rejects anything else.
- Release notes become TestFlight "What to Test" verbatim: write **plain sentences, no
  markdown tables/headings/links** (TestFlight renders raw text; the user's testers may
  use screen readers — plain prose reads best).
- This machine cannot compile Swift — never try to validate locally; the workflow is the
  validation.

## Procedure

1. **Preflight**
   - `git status` clean, on `main`, and `main`'s CI is green
     (`gh run list --branch main --limit 3`). Unpushed local commits are fine — they go
     up with the release push — but tell the user they'll be included.
   - First-release blockers (skip once these exist): `Apps/iOS/Assets.xcassets` with an
     AppIcon must exist, and the repository secrets from `plan.md` Phase 2 must be set
     (`gh secret list`). If missing, stop and point at `plan.md`.

2. **Pick the version**: `git describe --tags --abbrev=0` (or `gh release list`) for the
   latest `vX.Y.Z`; propose the semver bump implied by the changes (user decides if
   ambiguous). First release: propose `v0.1.0`.

3. **Draft the notes** from `git log <lasttag>..HEAD --oneline` plus your knowledge of the
   changes: 3–8 plain sentences aimed at a tester ("what changed, what to try"). Not a
   commit list.

4. **Sync the fallback version**: update all `MARKETING_VERSION = <old>;` occurrences in
   `RemSound.xcodeproj/project.pbxproj` to the new version (iOS and macOS configs — keep
   them identical) and commit. The workflow injects the real version from the tag; this
   just keeps local Xcode builds honest.

5. **Confirm with the user**: show tag, notes, and what will be pushed. Wait for an
   explicit yes.

6. **Publish**: `git push`, then create the release with the notes via a body file
   (avoids quoting issues):
   `gh release create vX.Y.Z --target main --title "RemSound vX.Y.Z" --notes-file <file>`

7. **Watch the run**: `gh run list --workflow Release --limit 1`, then
   `gh run watch <id> --exit-status` (the TestFlight step alone takes 5–15 min while App
   Store Connect processes the build). On failure, read the failed step's log
   (`gh run view <id> --log-failed`), fix, and either re-run the workflow
   (`gh run rerun <id>`) for infra flakes or — for code/config fixes — delete the release
   + tag (`gh release delete vX.Y.Z --cleanup-tag`, only with user OK) and start over.

8. **Report**: link the release, confirm the IPA asset is attached
   (`gh release view vX.Y.Z`), and remind the user the build reaches TestFlight testers
   automatically once processing finishes.
