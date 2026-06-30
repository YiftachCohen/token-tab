# Token Tab branding

The mark is the **gauge** — the usage meter itself: a progress ring that doubles as the
app's live indicator, the green arc as the runway. It reads from a 16px menu-bar glyph
up to the app icon, and tints cleanly as a monochrome template.

| Role | Hex | |
|---|---|---|
| Gauge green (progress / health) | `#36C98A` | the primary signal color |
| Wordmark green | `#2E9E63` | the ring on a light background |
| Tile gradient | `#26272E` → `#15161B` | the dark squircle (160°) |
| Ring track | `#D8D5CF` | the unfilled arc |
| Ink | `#1C1D22` | the wordmark text |

The SVGs are the source of truth; the rasters are generated from them.

- **Vector** — `gauge-appicon.svg` (app icon), `favicon.svg` (full-bleed, for browser
  tabs), `gauge-glyph.svg` (monochrome menu-bar glyph, uses `currentColor`),
  `gauge-wordmark.svg` (ring + name lockup).
- **Raster** — `gauge-appicon.png` (hero), `gauge-wordmark{,-dark}.png` (light/dark ink),
  `favicon.ico` (16/32/48), `favicon-{16,32,48,192,512}.png`, `apple-touch-icon.png` (180).

## Use the favicon on a web page

```html
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png">
<link rel="icon" type="image/png" sizes="16x16" href="/favicon-16.png">
<link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
<link rel="icon" href="/favicon.ico" sizes="any"><!-- legacy fallback -->
```

## Regenerate

Vector-drawn with Core Graphics — no external rasterizer:

```sh
app/Scripts/make-icon.sh       # → app/Bundle/AppIcon.icns (the macOS app icon)
app/Scripts/make-branding.sh   # → the favicons, hero, and wordmarks above
```

The native app icon is wired in via `CFBundleIconFile`; `build-app.sh` regenerates the
`.icns` on demand if it's missing. See [`app/README.md`](../README.md#app-icon).
