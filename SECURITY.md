# Security Policy

Token Tab's entire pitch is that it *verifiably can't* leak your data: no network
code, no runtime dependencies, no reads of message content, and a sandboxed
native app with no network entitlement. A security report here is any evidence
that one of those claims doesn't hold.

## What counts as a vulnerability

- Any path by which Token Tab (the `src/` core, the native app, or the SwiftBar
  wrappers) could transmit data off the machine.
- Any way the audited code reads or retains `message.content` (prompts, code,
  responses) rather than token metadata.
- A weakness in the audit itself — a technique that would let network,
  subprocess, or content-reading code pass the CI trust-invariant greps
  (`.github/workflows/ci.yml`, `audit` job) undetected.
- Sandbox or entitlement issues in the native app
  (`app/Bundle/TokenTab.entitlements`).
- Anything in the opt-in live paths (`adapters/`, or the bundled helper in
  `app/Helper/`) that exceeds their documented scope of running
  `claude -p "/usage"`, parsing the printed summary, and writing the local
  cache file.

Accuracy bugs (wrong totals, dedup mistakes, pricing drift) are ordinary bugs —
please file a public issue for those.

## How to report

Use GitHub's private vulnerability reporting:
**[Report a vulnerability](https://github.com/YiftachCohen/token-tab/security/advisories/new)**.
If that doesn't work for you, email <co.yiftach@gmail.com> with
`[token-tab security]` in the subject.

Please include the affected file/line and, for audit-bypass reports, the
concrete pattern that evades the greps. You can expect an acknowledgment within
a few days. Please don't open a public issue for anything exploitable until
it's fixed.

## Supported versions

The latest release and `main`. There are no backports.
