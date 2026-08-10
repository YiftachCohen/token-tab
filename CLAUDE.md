# Token Tab

Claude Code and Codex usage in the macOS menu bar. Reads the local `~/.claude`
(and `~/.codex`) logs; nothing leaves your machine — no network calls, no
content read, and every claim is verifiable. See `README.md` for the trust
model and architecture (JS engine + Swift port behind CLI / SwiftBar / native
app front-ends).

## Working rules (trust invariants, two-engine parity, rate checklist)
@AGENTS.md

## Design System
Always read `DESIGN.md` before making any visual or UI decision.
All font choices, colors, spacing, motion, and aesthetic direction are defined there
(direction: "Precision Instrument"; design tokens live in
`app/Sources/TokenTab/Views/Theme.swift`).
Do not deviate without explicit user approval.
In QA mode, flag any code that doesn't match `DESIGN.md`.
