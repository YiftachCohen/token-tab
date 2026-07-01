# Token Tab

A provably-safe Claude Code usage meter for the macOS menu bar. Reads local
`~/.claude` logs, makes no network calls, keeps none of your content. See
`README.md` for the trust model and architecture (JS engine + Swift port behind
CLI / SwiftBar / native app front-ends).

## Design System
Always read `DESIGN.md` before making any visual or UI decision.
All font choices, colors, spacing, motion, and aesthetic direction are defined there
(direction: "Precision Instrument"; design tokens live in
`app/Sources/TokenTab/Views/Theme.swift`).
Do not deviate without explicit user approval.
In QA mode, flag any code that doesn't match `DESIGN.md`.
