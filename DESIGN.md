# Design System — Token Tab

The source of truth for Token Tab's visual language. Tokens live in code at
`app/Sources/TokenTab/Views/Theme.swift`; this file is the *why* and the rules.
Read it before any visual or UI change.

> Design direction approved 2026-06-30 via `/design-consultation` (variant "Full
> Instrument"). Living preview:
> `~/.gstack/projects/YiftachCohen-token-tab/designs/design-system-20260630/preview.html`

## Product Context
- **What this is:** a macOS menu-bar app showing Claude Code token usage and the
  5-hour rate-limit runway, read from local `~/.claude` logs. No API keys, no
  network, sandboxed.
- **Who it's for:** developers using Claude Code — subscription (Max/Pro), the
  Anthropic API, or AWS Bedrock.
- **Space/industry:** Mac menu-bar developer utilities (neighbors: iStat Menus,
  ccusage, Raycast). Category lesson: glanceable + progressive disclosure, and
  clutter is the enemy.
- **Project type:** macOS SwiftUI menu-bar dropdown (322pt wide), glass material.
- **The memorable thing (priority order):** (1) "wow, it's beautiful" (2) "wow,
  it's easy to use" (3) "wow, I get how it works in a way that can't leak my
  credentials." Beauty leads; trust is shown by restraint, never claimed by a badge.

## Aesthetic Direction
- **Direction:** Precision Instrument (an elevated Industrial/Utilitarian). A
  jewel-like gauge in glass that reads like a damped analog meter you simply believe.
- **Decoration level:** minimal → intentional. Hairline "engraving" instead of
  stacked cards; one machined glass edge. No texture, no blobs, no gradients as
  personality. The numbers and the ring do the work.
- **Mood:** calm, dense, quietly expensive, system-native. Not a SaaS dashboard
  trapped in a menu bar.

## Typography
Apple-native everywhere except the heroes. The trick: one distinctive face for the
hero number, system font for everything else, so it feels designed but never costumey.
- **Hero figures** (the gauge `%`, the burn `$`, History period totals): **Martian
  Mono** (SIL OFL, bundled) — weight 500–600, tracking ≈ −2% to −4%, tabular. Reads
  as a *measurement*, not the OS.
- **UI / labels / body:** **SF Pro Text** (`system-ui` / `-apple-system`).
- **Runway time** (`4h 12m`): Martian Mono.
- **Data / numerics:** SF Pro with `.monospacedDigit()` — tabular everywhere a number
  ticks, so digits never jitter. **Never variable-width numbers.**
- **Code / commands:** SF Mono (`ui-monospace`).
- **Loading:** all system except Martian Mono, which ships in the bundle (no network).
- **Scale (in the 322pt panel):** hero % ≈ 33pt · hero $ ≈ 34pt · History period total
  ≈ 30pt · runway time ≈ 18pt · section labels 9.5px ALL-CAPS tracked +0.08em · primary
  rows 12–13px · footnotes 9.5–11px. Big figures get tight tracking (`Theme.tightTracking`).

## Color
**Approach: balanced / semantic — color carries the MODE.** The headline is decided
by the dominant surface, not a user toggle. Three accents max; the rest is graphite,
glass, and numbers. Values below are the `Theme.swift` tokens (light / dark).
- **Green — subscription / Claude Max / runway health** (the signature):
  `#2E9E63` / `#36C98A`. Also the structural color (trends, the week bar).
- **Amber — Bedrock/API / pay-per-token / cost / "the meter is running":**
  `#B06A1F` / `#D6A45A`, refined brighter toward `#C2740F` / `#F5B44D` for cost energy
  (never neon). `amberBar` `#C08A3E` / `#D6A45A` = the History "today" bar and cost leader.
- **Indigo — Codex:** `#5B62D6` / `#7C83F0`.
- **Slate — Haiku:** `#7D8AA3` / `#6F87B5`.
- **Danger** `#D65745` / `#E06A55` — gauge **tip only**, when the window crosses ~85% burned.
- **Text ramp** (warm grey in light, cool blue-grey in dark; never pure white on dark):
  ink `#1C1D22` / `#EEF0F4` · muted `#76736D` / `#9AA1B1` · faint `#A29E97` / `#73798A`.
- **Material:** glass (`.thinMaterial`), 14pt radius. The panel edge is a single subtle
  inner top highlight (≈ white 8% dark / 65–75% light) — the **machined glass edge**,
  **not** an accent-colored outline (see Decisions). Trust rides on the glyph + footer.
- **Dark mode:** not a tint flip — surfaces are redesigned cool blue-greys and accents
  brighten ~10–20%.

## Spacing
- **Base unit:** 4px.
- **Density:** compact (it's a dense readout) but breathing.
- **Panel:** 322pt wide; horizontal padding 16–17pt; section rhythm ≈ 11–14pt.
- **Scale:** 2xs(2) xs(4) sm(8) md(12) lg(16) xl(24) 2xl(32).

## Layout
- **Approach:** grid-disciplined but **card-less** — sections divided by inset
  hairlines (one engraved faceplate). The *only* inset card is the burn-rate box (a
  discrete read). No cards-in-cards.
- **Shell:** Header (brand chip + "Token Tab" wordmark + mode pill) → Overview/History
  tab bar → mode body → footer action row (trust line + gear/refresh/Quit). **Settings
  is a gear overlay, not a third tab** — reachable from every mode.
- **Hierarchy:** hero (gauge % on subscription, `$` on burn) → second star (the runway
  *time* / the interpretation line) → everything else recedes. Today-by-model reads like
  a quiet receipt. **Progressive disclosure; never scroll.** If it scrolls, hierarchy failed.
- **Border radius:** panel 14pt · cards 10pt · chips 5–6pt · pills 6pt.

## Motion
- **Approach:** intentional — one idea, the **"open beat."** On panel open, ~600ms
  ease-out (no bounce): the gauge sweeps 0→value, the dollar counts up, History bars
  grow from the baseline and the period figure counts with them. Everything else is instant.
- **Easing:** enter `ease-out` (easeOutCubic) · exit `ease-in` · move `ease-in-out`.
- **Duration:** micro 50–100ms · short 150–250ms · the open beat ≈ 600ms.
- The LIVE dot pulses (≈2.4s) — it means "this % is authoritative."

## Signature Patterns (Token Tab–specific)
- **Gauge-as-logo.** The meter is the product: same ring across app icon, menu-bar
  glyph, and the panel hero.
- **Interpretation line per mode.** One plain-language line does the "easy" work —
  "At this pace, you're clear until reset" (green) / "On pace for ~$31 today" (amber).
  Raw numbers stay below it.
- **By-model receipt.** Subscription shows **tokens** per model; Bedrock/API shows
  **$ + cost-share %**, sorted by spend, with an amber cost-share bar. (Main-vs-sub-agent
  is intentionally gone — in pay-per-token, *which model* burned the money is the question.)
- **History.** Daily bars (subscription green, Bedrock/API **amber** so the cost chart
  honors color-as-mode; today is the brightest bar, weekends faded, dashed average line),
  period total + delta-vs-previous, then AVG/DAY and BUSIEST MODEL in that model's accent.
  Defaults to the mode's headline metric — tokens on subscription, $ on Bedrock/API.
- **Trust as restraint.** A lit no-network glyph (tinted to the mode accent) + a quiet
  footer line ("Local only — nothing leaves this Mac" / "0 network calls · reads ~/.claude"
  / "Computed on-device · 0 network calls"). **No** lock/cloud/security imagery, **no**
  "Secure!" badge, **no** accent border. Restraint *is* the proof.

## Anti-Slop Guardrails (do NOT)
- No accent-colored border around the panel · no cards-in-cards · no gradients as the
  main personality · no decorative blobs / mesh / fake depth · no security/cloud/lock
  imagery · no "Secure"/"Private" badges · no `$0.00` hero for subscription users ·
  no variable-width numbers · no scroll-heavy panel · no system-ui as a *display* face.

## Decisions Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-06-30 | Initial design system: **Precision Instrument** | `/design-consultation`; variant "Full Instrument" chosen over Conservative / Wilder |
| 2026-06-30 | Hero figures in **Martian Mono**, SF everywhere else | Number reads as a measurement, not the OS; stays Apple-native and legible at small sizes |
| 2026-06-30 | **Dropped the accent-colored sealed bezel** | A colored ring around glass reads as a stray focus outline; trust rides on the no-network glyph + footer instead |
| 2026-06-30 | **Burn-history bars amber** (not green) | A cost chart must honor color-as-mode; green bars on a $ chart cross-wired green=health / amber=cost |
| 2026-06-30 | Burn by-model shows **cost-share %** + sorted by spend | Rank and proportion at a glance; ties each row to the cost-share bar |
| 2026-06-30 | **Removed main-vs-sub-agent** from the burn panel | In pay-per-token, "which model cost me money" is the real question |

## Where this lives in code
- **Tokens:** `app/Sources/TokenTab/Views/Theme.swift`
- **Shell + header:** `DropdownView.swift` · **Overview:** `SubscriptionPanel.swift`,
  `BurnPanel.swift` · **History:** `HistoryPanel.swift` · **Settings:** `SettingsView.swift`
- **Brand:** `app/Branding/` (`gauge-appicon.svg`, `gauge-glyph.svg`, wordmarks)
