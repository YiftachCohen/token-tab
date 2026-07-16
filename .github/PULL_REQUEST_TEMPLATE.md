## What & why

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] `node --test` and `swift test --package-path app` pass
- [ ] Engine behavior changes land in **both** engines, pinned by a fixture in
      `test/fixtures/parity/` (see [AGENTS.md](../AGENTS.md)); rate-table edits also pass
      `node .github/scripts/rates-parity.mjs`
- [ ] `bash .github/scripts/trust-audit.sh` still exits 0 (no network/subprocess/content
      reads in `src/` or `app/Sources`, deps stay `{}`)
- [ ] UI changes follow [DESIGN.md](../DESIGN.md) and pass
      `bash .github/scripts/design-lint.sh` (new colors/fonts go in `Theme.swift`)
- [ ] README / CHANGELOG updated if flags, env vars, or output formats changed
