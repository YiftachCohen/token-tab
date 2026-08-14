---
name: qa-visual
description: Build, repair, run, or review Token Tab visual regression coverage without installing the app. Use whenever a request mentions visual QA, screenshot or golden-image tests, UI regressions, rendered app previews, visual diffs, menu-bar appearance, SwiftUI snapshot testing, or asks whether a UI change looks correct. Prefer the existing fixture-driven off-screen renderer; use real menu-bar automation only for interaction behavior that static rendering cannot prove.
---

# Token Tab visual QA

Treat a visual test as a regression contract for a named UI state, not as a
marketing screenshot or a substitute for behavior tests. The target is reliable
evidence from the real shipping SwiftUI views, without installing Token Tab,
reading a person's local logs, or adding a snapshot-test dependency.

## Operating boundaries

- Read `AGENTS.md` before editing. Its trust audit, zero-dependency rule, and
  design-lint ratchet still apply to UI-test work.
- Do not package, install, launch at login, or register the app just to perform
  visual QA. Build and run the Swift test bundle instead.
- Do not use a real `~/.claude` or `~/.codex` directory for a visual fixture.
  Fixture data makes every capture safe to share and reproducible.
- Do not add an npm package, SwiftPM dependency, or a generic screenshot library.
  Use XCTest, AppKit, and the repository's existing renderer.
- Do not silently replace or bless a baseline. A changed baseline is a reviewed
  product decision; show the diff and wait for explicit approval before updating it.

## First classify the request

1. **Static visual state** — a dropdown tab, light/dark appearance, empty/error
   state, metric, or provider combination. Use the off-screen renderer and a
   baseline comparison.
2. **Shell interaction** — status-item opening, dismissal, menu-bar placement,
   keyboard focus, or settings interactions. Static images cannot prove these.
   If available, use macOS UI automation for a focused smoke test after building
   the app; keep this optional and separate from the visual-regression gate.
3. **Design review only** — render the relevant staged scenes, inspect actual
   output, and report concrete visible regressions. Do not turn an aesthetic
   preference into a golden test without a named visual contract.

When a request spans more than one class, keep their evidence separate: a green
static baseline does not prove menu-bar behavior, and a successful interaction
smoke test does not prove all visual states.

## Existing install-free renderer

The repository already owns the render path:

```sh
TOKENTAB_SHOTS=1 swift test --package-path app \
  --filter TokenTabAppTests.ShotsTests/testRenderShots
```

It renders the actual `DropdownView` using fixture `Snapshot` values in a real,
off-screen `NSWindow`, then writes scratch PNGs to `docs/screenshots/generated/`.
That directory is gitignored. It does not install the `.app`, create a login
item, or access personal usage logs.

Before changing this path, inspect these files together:

- `app/Tests/TokenTabAppTests/Shots/ShotsTests.swift` — named scene catalogue.
- `app/Tests/TokenTabAppTests/Shots/ShotFixtures.swift` — safe staged state.
- `app/Tests/TokenTabAppTests/Shots/ShotStage.swift` — real AppKit render/capture.
- `app/Sources/TokenTab/Views/DropdownView.swift` — shipping composition.

Do not replace `ShotStage` with SwiftUI `ImageRenderer`: it flattens the material
and can capture the opening animation before it settles. The real off-screen
window plus `cacheDisplay` exists to preserve the glass effect and final gauge
state.

## Build or extend a visual contract

### 1. Define the state precisely

Name the scenario by what a user sees, for example `codex-dual-dark-history`.
State the mode, provider focus, selected tab, color scheme, data health, and any
important empty/error/overflow condition. Add fixture values only through
`ShotFixtures`; do not wire a shot to live readers.

Freeze every source of nondeterminism before comparing pixels:

- use a fixed instant instead of `Date()` for scene and fixture construction;
- freeze labels that include the current clock, relative durations, or locale;
- avoid network, filesystem state, and animation timing as data sources;
- allow the existing render-settle interval to finish the intentional open beat.

If a view cannot be staged honestly because it reads an environment-dependent
service, first introduce a narrow test seam or fixtureable dependency. Do not
commit an image labelled with development-machine failure text as a product
baseline.

### 2. Compare meaningful pixels

Keep approved reference images under a test-fixture directory, never in
`docs/screenshots/generated/`. Implement comparison with system frameworks in
the test target so the project keeps zero runtime and package dependencies.

The comparator should:

1. fail on dimension or scale mismatch;
2. calculate changed-pixel count and a per-channel difference summary;
3. allow a small, documented anti-aliasing tolerance only after measuring a
   known-stable capture on the pinned runner;
4. write `actual`, `expected`, and a high-contrast `diff` image to a gitignored
   diagnostics directory on failure;
5. print their paths and the measured threshold in XCTest output.

Avoid broad masks and permissive thresholds: they make the test green while
layout, contrast, or typography visibly drifts. A mask is acceptable only for a
specific uncontrollable OS-owned region, with a comment explaining why it is
not a product pixel.

### 3. Treat baselines as reviewed artifacts

Generate candidate references with the render command, inspect them at the
target size, and make an explicit approval checkpoint before copying them into
the committed fixture directory. On intentional UI changes, show the old/new
diff, explain the user-visible change, and update the baseline in the same PR.

## CI design

Keep normal unit/parity tests fast. Put visual regression in a dedicated macOS
job, with the macOS image and Xcode version pinned rather than following
`macos-latest`; SwiftUI, fonts, and compositing can change across OS releases.

The job should run the deterministic render-and-compare test. On failure, upload
only test fixtures and generated diagnostics (`actual`, `expected`, `diff`) as
short-retention artifacts. Never upload user logs, application containers, or
home-directory captures.

Before proposing CI changes, inspect the current workflow and preserve the
existing Swift parity matrix. A visual job is a new rendering contract, not a
reason to weaken the trust audit, design lint, or ordinary Swift tests.

## Verification

Run the narrow visual test first, then the repository gates affected by the
change:

```sh
swift test --package-path app
bash .github/scripts/trust-audit.sh
bash .github/scripts/design-lint.sh
```

Run `node --test` and `node .github/scripts/rates-parity.mjs` too when changes
touch shared state, core behavior, package configuration, or CI. Report a local
renderer run as equivalent local evidence, not as proof that a remote CI job
passed.

## Final report format

Use this compact structure:

```
Visual QA: PASS | FAIL | NOT RUN
States: <named scenes and what each pins>
Evidence: <render/comparison command and artifact paths>
Baseline: unchanged | approved update | needs approval
Coverage boundary: <what static rendering does not prove>
Verification: <commands and results>
```

Call out a missing environment/service seam, runner drift, or inability to
capture the native menu-bar shell as a limitation rather than implying the
goldens cover it.
