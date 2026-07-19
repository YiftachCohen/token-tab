---
name: release
description: Cut a Token Tab release end-to-end — bump versions, tag, drive the draft release, build+notarize locally, publish npm, bump the Homebrew cask. Use when asked to "cut a release", "release vX.Y.Z", "ship a new version", or "publish the app".
---

# Cutting a Token Tab release

The full process is `RELEASING.md`; this skill is the executable version with the
gotchas baked in. Two artifacts ship per tag: the notarized app zip (built LOCALLY —
the signing key never enters CI) and the npm tarball `@ycstudios/token-tab`.

## 0. Preflight

- Working tree clean, `main` up to date, CI green on `main`.
- Pick the version (SemVer; 0.x minor bumps may change behavior).
- Run the local gate before touching versions — a release should never be where you
  discover red:
  ```sh
  node --test
  swift test --package-path app
  bash .github/scripts/trust-audit.sh
  node .github/scripts/rates-parity.mjs
  bash .github/scripts/design-lint.sh
  ```

## 1. Bump the version — three places, or the tag fails CI

1. `package.json` → `"version"`.
2. `app/Bundle/Info.plist` → `CFBundleShortVersionString` (leave `CFBundleVersion` alone —
   it's a build number, not the release version).
3. `CHANGELOG.md` → retitle `## [Unreleased]` to `## [x.y.z] — YYYY-MM-DD`, and start a
   fresh empty `## [Unreleased]` above it. **Call out any trust-surface change explicitly**
   (entitlements, parsed fields, rate table, network posture) — that honesty is the product.

Land this on `main` through the normal PR flow.

## 2. Tag → draft release

```sh
git tag vX.Y.Z && git push origin vX.Y.Z
```

Watch the `Release` workflow (`gh run watch`): it re-checks version stamps, re-runs the
trust audit and both engines' tests, proves the app assembles, and opens a **draft**
GitHub release with the npm tarball attached. If it fails, fix on `main`, delete and
re-push the tag.

## 3. Build + notarize the app — LOCAL, and it needs a real terminal

```sh
app/Scripts/package-app.sh X.Y.Z --dmg
```

- Waits on Apple notarization, typically 1–5 min. Produces `dist/Token-Tab-X.Y.Z.zip`
  + `.sha256` (and the `.dmg` pair).
- **Gotcha — keychain access:** `codesign`/`notarytool` need the login keychain, which a
  background/sandboxed agent shell may not get (`errSecInternalComponent`). If signing
  fails that way, ask the user to run the exact command above in their own foreground
  terminal — do not retry in a loop.
- Notary credentials come from the keychain profile named by `TOKENTAB_NOTARY_PROFILE`
  (default `token-tab-notary`; one-time setup in `RELEASING.md`).
- The script ends with `spctl -a`; do not proceed unless it printed `accepted` /
  `source=Notarized Developer ID`.

## 4. Attach and publish the GitHub release

```sh
gh release upload vX.Y.Z dist/Token-Tab-X.Y.Z.*
gh release edit vX.Y.Z --draft=false
```

## 5. Publish npm (only when `src/`, `adapters/`, or `swiftbar/` changed)

- **Gotcha — npm shims:** corporate/dev-machine setups sometimes shadow `npm` with a
  proxy shim pointing at a localhost registry. Verify before publishing:
  ```sh
  npm config get registry   # must be https://registry.npmjs.org/
  ```
  If it isn't, use the real binary directly: `/opt/homebrew/bin/npm publish`.
- `npm publish` runs `node --test` via `prepublishOnly`; a red test aborts, as intended.

## 6. Bump the Homebrew cask — the step people forget

The cask lives in the separate repo `YiftachCohen/homebrew-tap`, at `Casks/token-tab.rb`.

1. `version` → `X.Y.Z`
2. `sha256` → the hash from `dist/Token-Tab-X.Y.Z.zip.sha256`
3. Commit and push. `brew upgrade --cask token-tab` picks it up from there.

## 7. Post-verify

- Release page shows: app zip + sha256 (+ dmg pair if built) + npm tarball, not draft.
- `npm view @ycstudios/token-tab version` matches (if published).
- Cask `version`/`sha256` match the shipped zip.

Never: put signing keys in CI, add an auto-updater (the app has no network entitlement —
that's the feature), or ship a release whose notes are silent about a trust-surface change.
