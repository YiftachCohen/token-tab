# Releasing Token Tab

Two artifacts ship per release, both from the same tag:

- **`Token-Tab-<version>.zip`** — the native app, Developer ID-signed, hardened-runtime,
  notarized, stapled, universal (arm64 + x86_64). Built **locally** by
  `app/Scripts/package-app.sh` (add `--dmg` for a drag-to-Applications
  `Token-Tab-<version>.dmg` alongside it — Homebrew consumes the zip either way).
- **`ycstudios-token-tab-<version>.tgz`** — the npm package
  **`@ycstudios/token-tab`** (CLI + SwiftBar plugin + live adapters; the installed
  command is still `token-tab`). Built by `npm pack` / published with `npm publish`.
  Scoped because unscoped `token-tab` collides with the unrelated `tokentab` package
  under npm's name-similarity rule.

## Why signing is local, not CI

The project's whole claim is "verify it yourself, trust no one's infrastructure."
Keeping the Developer ID private key out of CI secrets is that claim applied to the
release process: the key never leaves the maintainer's keychain, and CI only proves the
tagged commit builds and passes the trust-invariant audit. The `release.yml` workflow
therefore creates a **draft** release; the notarized zip is attached from the machine
that holds the key.

## One-time setup

1. **Developer ID Application certificate** in your login keychain (Apple Developer
   Program). `package-app.sh` auto-detects it.
2. **Notary credentials** stored as a keychain profile (uses an app-specific password
   from [appleid.apple.com](https://appleid.apple.com), *not* your Apple ID password):

   ```sh
   xcrun notarytool store-credentials token-tab-notary \
     --apple-id <your-apple-id> --team-id <your-team-id>
   ```

   (`package-app.sh` reads the profile name from `TOKENTAB_NOTARY_PROFILE`,
   default `token-tab-notary`.)
3. **npm login** if publishing the CLI: `npm login`.

## Cutting a release

1. **Bump the version in both places** (CI fails the tag if they disagree), and give
   the release a dated `CHANGELOG.md` section:
   - `package.json` → `"version"`
   - `app/Bundle/Info.plist` → `CFBundleShortVersionString`
   - `CHANGELOG.md` → `## [x.y.z] — YYYY-MM-DD` (call out any trust-surface change)
2. Land that on `main`, then tag it:

   ```sh
   git tag v0.1.0 && git push origin v0.1.0
   ```

   The `Release` workflow re-runs both engines' tests, checks the version stamps,
   proves the app assembles, and opens a **draft** GitHub release with the npm tarball
   attached.
3. **Build + notarize the app locally** (waits on Apple, typically 1–5 min):

   ```sh
   app/Scripts/package-app.sh 0.1.0          # add --dmg for a drag-to-Applications DMG too
   ```

   This produces `dist/Token-Tab-0.1.0.zip` + `.sha256` (and the `.dmg` pair with
   `--dmg`), stapled and Gatekeeper-verified (`spctl -a` runs at the end — it must say
   `accepted`, `source=Notarized Developer ID`).
4. **Attach and publish:**

   ```sh
   gh release upload v0.1.0 dist/Token-Tab-0.1.0.*
   gh release edit v0.1.0 --draft=false
   ```
5. **Publish the CLI** (optional, when the npm side changed):

   ```sh
   npm publish
   ```

## Homebrew (after the first published release)

A cask needs a tap repo (`YiftachCohen/homebrew-tap`, file `Casks/token-tab.rb`).
Template — update `version` and `sha256` (from the `.sha256` file) each release:

```ruby
cask "token-tab" do
  version "0.1.0"
  sha256 "<sha256 of Token-Tab-#{version}.zip>"

  url "https://github.com/YiftachCohen/token-tab/releases/download/v#{version}/Token-Tab-#{version}.zip"
  name "Token Tab"
  desc "Provably-safe Claude Code usage meter for the menu bar"
  homepage "https://github.com/YiftachCohen/token-tab"

  depends_on macos: ">= :ventura"

  app "Token Tab.app"
end
```

Then users install with:

```sh
brew tap YiftachCohen/tap
brew install --cask token-tab
```

## No auto-update, by design

The app has no network entitlement, so it cannot check for updates — that's the
feature, not a gap. Updates arrive the same way the app did: a new notarized zip on the
Releases page (or `brew upgrade`). Keep the release notes honest about what changed in
the trust surface (entitlements, parser fields, rate table).
