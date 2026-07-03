## What & why

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] `node --test` and `swift test --package-path app` pass
- [ ] Engine behavior changes land in **both** engines, pinned by a fixture in
      `test/fixtures/parity/` (see [AGENTS.md](../AGENTS.md))
- [ ] The trust-invariant greps still print nothing (CI `audit` job — no
      network/subprocess/content reads in `src/` or `app/Sources`, deps stay `{}`)
- [ ] UI changes follow [DESIGN.md](../DESIGN.md)
- [ ] README / CHANGELOG updated if flags, env vars, or output formats changed
