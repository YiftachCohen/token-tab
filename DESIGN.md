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
| 2026-07-05 | **Two-gauge Overview, never a combined quota gauge** | Focused provider is the hero gauge; the other provider (when it has usage) is a compact hairline secondary row that swaps focus on tap — a zero-usage provider is hidden. A merged Claude+Codex % is mathematically fake (both blind designs agreed), so it's banned |
| 2026-07-05 | **Max-pressure headline rule** (menu bar + Overview focus) | The provider under most 5h pressure headlines, but ONLY real percentages compete — Codex's official `used_percent`, Claude's % only with a configured/calibrated cap or live reading. Inferred time-left never competes; neither has a real % → fall back to combined today-tokens. Re-ranked only on the 30s refresh tick (no intra-tick flapping) |
| 2026-07-05 | **`Cdx` suffix on the Codex menu-bar label** | When Codex is the focused provider the menu bar reads e.g. `◧ 42% Cdx`, so the number is unambiguous at a glance without a second glyph. *(Still true for the single-figure label — see the 2026-07-30 dual-label row, where a second glyph makes the suffix redundant)* |
| 2026-07-05 | **Indigo = Codex** across every surface | The existing indigo token is Codex's accent everywhere (hero ring, secondary row, history bars, header pill, by-model dots). Claude keeps green/amber-by-surface; Codex has no runway-health semantic, so its ring is flat indigo, not health-tinted |
| 2026-07-05 | **Codex staleness affordance** | Codex's official % is only as fresh as the newest `token_count`; past ~10 min the hero shows a subtle "as of HH:MM" line instead of implying a live reading |
| 2026-07-30 | **Every menu-bar percentage is `% LEFT`, both providers** | Codex's official reading is natively `used_percent`, and showing it raw put a 92%-full ring next to the figure "8%" — the glyph and the number contradicting each other. Both providers' rings already fill to runway-left, so the figures now match them (8% spent reads `92%`). The dropdown still quotes Codex's native "% used" where there's room to say so; only the bar normalizes. Applies to the SwiftBar label too (`◧`), so one Mac can't get two different numbers from two front-ends |
| 2026-07-30 | **The status item is an `NSStatusItem`, not a `MenuBarExtra`** | Forced by the dual label: `MenuBarExtra` renders only ONE `Text` + ONE `Image` in its label, so the second provider's pair was silently truncated — the item didn't even size for it (66pt, one pair) and flattening the `HStack` changed nothing. It's the same ceiling that made a custom SwiftUI `Shape` invisible there. Hosting the same `MenuBarLabel` in an `NSHostingView` inside a status-item button lifts it (112pt, two pairs); the dropdown keeps its presentation as a `.transient` `NSPopover` around the same unmodified `DropdownView`. Cost: the selection highlight is now ours to paint, so the figures invert via `Theme.onMenuSelection` instead of AppKit doing it for a template image |
| 2026-07-30 | **Dual menu-bar label: one glyph+figure pair per provider** | With two providers in use, showing one of them withholds half the reading. `◔ 42%  ◕ 92%` — Claude ALWAYS first, so position identifies each pair and neither needs a text suffix (this is what supersedes `Cdx` in dual mode; the single-figure label keeps it). Shown only when both providers have usage, so a Claude-only bar is byte-identical to before; a provider with usage but no real % gets a dot + tokens, never a ring implying a percentage we don't have. Per-provider figures are per-provider — the single label's combined today-tokens would double-count Codex into Claude's slot. Settings ▸ Providers ▸ MENU BAR switches back to `Headline` |
| 2026-07-31 | **An expired official window is not a percentage** | Codex only writes logs while it runs, so its last `rate_limits` snapshot sits on disk indefinitely. Once `resets_at` has passed, the recorded `used_percent` describes a window that no longer exists — OpenAI restarts the new one at 0% — so past that instant it stops being a percentage *everywhere at once*: no menu-bar headline, no ring, no hero figure (the panel falls back to `idle` + tokens, captioned "window reset at HH:MM"). Distinct from the ~10-min staleness affordance, which softens a reading that is still about the current window. Mirrored in the SwiftBar label, which likewise won't headline an expired `%` and labels the detail line `last known` |
| 2026-07-31 | **Each provider's numbers stay that provider's own** | A figure the UI labels "Claude" must be sourced from Claude's records alone — its dollars (`providers.claude.cost.*`, not the combined `cost.*`), its 5h window (Codex timestamps never feed the inferred Anthropic block), and its mode (a Codex-heavy Mac must not flip Claude's panel into burn). History follows: it opens on the focused provider's filter, not `All`, so a Claude-focused journey never lands on a chart that has folded Codex into it. Combined figures still exist — they're just labelled as combined |
| 2026-07-31 | **Trust copy names only what was actually read** | The footer's "reads ~/.claude + ~/.codex" is a claim, so it's derived from the resolved provider flags rather than assumed: a single-provider configuration names one directory, and the file count in the status line covers both providers (a Codex-only Mac reporting "0 files" beneath a live Codex gauge reads as broken) |

## Where this lives in code
- **Tokens:** `app/Sources/TokenTab/Views/Theme.swift`
- **Shell + header:** `DropdownView.swift` · **Overview:** `SubscriptionPanel.swift`,
  `BurnPanel.swift` · **History:** `HistoryPanel.swift` · **Settings:** `SettingsView.swift`
- **Brand:** `app/Branding/` (`gauge-appicon.svg`, `gauge-glyph.svg`, wordmarks)
