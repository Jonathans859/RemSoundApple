# Plan: RemSound iOS → TestFlight via GitHub Actions + Releases

Goal state (matches how you want to work):

- **Push to any branch** → existing `build.yml` runs tests + unsigned builds. (Already true.)
- **Publish a GitHub Release** (tag `vX.Y.Z` + notes) → new `release.yml` runs tests, builds a
  **signed IPA**, **uploads it to TestFlight** with the release notes as the TestFlight
  "What to Test" text, and **attaches the IPA to the GitHub release**.
- A `/release` Claude skill drives the whole thing: drafts notes, bumps the version, creates
  the release after your confirmation, and watches the workflow.

The workflow (`.github/workflows/release.yml`) and the skill
(`.claude/skills/release/SKILL.md`) are already committed. What remains is the Apple-side
setup you must do once, plus one repo gap (the app icon). Nothing here can be tested from
this Windows machine — expect the first release to take one or two iterations of reading
the Actions logs.

---

## Phase 1 — one-time Apple setup (you, ~30–45 min in the browser)

1. **Enrolled Apple Developer account** — done (prerequisite).

2. **Find your Team ID**: developer.apple.com → Membership details → 10-character Team ID.

3. **Register the App ID**: developer.apple.com → Certificates, Identifiers & Profiles →
   Identifiers → “+” → App IDs → App → Bundle ID **explicit** `com.jonathan859.remsound.ios`,
   description "RemSound iOS". No extra capabilities needed (background audio is an
   Info.plist mode, not a capability; we deliberately do NOT request multicast).

4. **Create an Apple Distribution certificate** (Windows-friendly, no Mac needed):
   - In Git Bash: generate a private key + certificate signing request:
     ```
     openssl genrsa -out dist.key 2048
     openssl req -new -key dist.key -out dist.csr -subj "/emailAddress=accounts@jonathan859.com/CN=Jonathan Distribution/C=DE"
     ```
   - Portal → Certificates → “+” → **Apple Distribution** → upload `dist.csr` → download
     `distribution.cer`.
   - Convert to a password-protected .p12:
     ```
     openssl x509 -in distribution.cer -inform DER -out dist.pem
     openssl pkcs12 -export -inkey dist.key -in dist.pem -out dist.p12
     ```
     (Choose a strong export password — it becomes a GitHub secret.)
   - Keep `dist.key`/`dist.p12` somewhere safe and OFF the repo.

5. **Create an App Store Connect API key**: App Store Connect → Users and Access →
   Integrations → App Store Connect API → Team Keys → “+”, role **App Manager**.
   Note the **Key ID** and **Issuer ID**, download the `.p8` file (one chance only).

6. **Create the app record**: App Store Connect → Apps → “+” → New App → iOS,
   name "RemSound" (or "RemSound Receiver" if taken), primary language, bundle ID
   `com.jonathan859.remsound.ios`, any SKU (e.g. `remsound-ios`).

7. **TestFlight internal group**: in the app → TestFlight → Internal Testing → create a
   group (e.g. "Core") with automatic distribution and add yourself. Internal testers need
   no review; builds appear as soon as processing finishes.

## Phase 2 — GitHub repository secrets (you, ~10 min)

Repo → Settings → Secrets and variables → Actions → New repository secret. The
`release.yml` workflow expects exactly these names:

- `APPLE_TEAM_ID` — the 10-character Team ID.
- `APPLE_DISTRIBUTION_CERT_P12_BASE64` — `base64 -w0 dist.p12` output (Git Bash).
- `APPLE_DISTRIBUTION_CERT_PASSWORD` — the .p12 export password.
- `KEYCHAIN_PASSWORD` — any random string (protects the throwaway CI keychain).
- `APP_STORE_CONNECT_API_KEY_ID` — the API key's Key ID.
- `APP_STORE_CONNECT_API_ISSUER_ID` — the Issuer ID.
- `APP_STORE_CONNECT_API_PRIVATE_KEY` — the full text content of the `.p8` file.

## Phase 3 — repo gaps to close before the first upload (Claude, needs your input)

1. **App icon (BLOCKER)**: App Store Connect rejects uploads without an asset-catalog
   AppIcon including the 1024×1024 marketing icon. The repo has none. Provide a
   1024×1024 PNG (no alpha) and Claude wires up `Apps/iOS/Assets.xcassets` (single-size
   icon), the pbxproj resources phase, and `ASSETCATALOG_COMPILER_APPICON_NAME`.

2. **Export compliance**: the app uses Apple's standard AES-GCM (CryptoKit). To keep
   TestFlight from asking the encryption question on every build, add
   `ITSAppUsesNonExemptEncryption` = `false` (standard-algorithms exemption) to
   `Apps/iOS/Info.plist` — confirm you're comfortable with that declaration for your
   jurisdiction first (France has extra rules), then Claude adds it.

3. Nothing else: versions are already wired (`CFBundleShortVersionString` =
   `$(MARKETING_VERSION)`, `CFBundleVersion` = `$(CURRENT_PROJECT_VERSION)`), so the
   workflow injects them at build time — tag `v1.2.3` becomes marketing version `1.2.3`
   and the workflow run number becomes the ever-increasing build number. The `0.1.0` in
   the pbxproj is only the local/Xcode fallback; the release skill keeps it in sync.

## Phase 4 — how a release then works (repeatable)

1. Say "cut a release" (or invoke `/release`). The skill will:
   - check the working tree is clean and CI is green on `main`,
   - propose the next semver + plain-text release notes drafted from the commits since the
     last tag (plain text on purpose — TestFlight shows "What to Test" without markdown),
   - sync `MARKETING_VERSION` in the pbxproj and commit,
   - after your explicit go-ahead: push and `gh release create vX.Y.Z`.
2. Publishing the release triggers `release.yml`:
   - `swift test`,
   - signed archive (cloud-managed provisioning via the API key — no profiles to maintain),
   - export IPA → **upload to TestFlight with the release body as the changelog**
     (fastlane pilot waits for processing, then sets "What to Test"),
   - attach `RemSound-iOS-vX.Y.Z.ipa` to the GitHub release,
   - throwaway keychain deleted even on failure.
3. TestFlight processing takes ~5–15 min; internal testers get the build automatically.

## Phase 5 — later / optional

- **macOS**: TestFlight for macOS is possible too (needs Developer ID / Mac App Store
  signing decisions + sandbox review for the network client entitlement) — separate plan
  when wanted; the unsigned zip from `build.yml` stays the macOS distribution meanwhile.
- **External TestFlight testers**: needs a Beta App Review pass and privacy details in
  App Store Connect; internal testing needs neither.
- Screenshots, App Privacy questionnaire, and the App Store listing only matter when you
  go beyond TestFlight.

## First-release checklist (condensed)

1. Phase 1 steps 2–7 done, Phase 2 secrets set.
2. Icon PNG handed to Claude → icon commit lands; encryption key decision made.
3. `/release` → confirm version + notes → release published.
4. Watch the `Release` workflow (`gh run watch` or share the logs); iterate if the first
   signing/upload attempt fails — that is normal.
5. Build appears in TestFlight → install via the TestFlight app on the iPhone.
