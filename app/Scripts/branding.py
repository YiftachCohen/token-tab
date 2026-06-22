#!/usr/bin/env python3
"""Token Tab — assemble raster branding from the gauge PNGs make-icon.swift renders.

  1. favicon.ico  — multi-resolution (16/32/48), PNG-payload ICO, hand-packed so the
     bytes are deterministic and each size is the crisp native render (no resampling).
  2. wordmark     — the ring + "Token Tab" lockup, in light-ink and dark-ink variants
     so a README can theme-swap it with <picture>.

Usage:  python3 branding.py <branding-dir>
"""
import math
import struct
import sys

from PIL import Image, ImageDraw, ImageFont

BRAND = sys.argv[1]

GREEN = (0x36, 0xc9, 0x8a, 255)   # progress arc / app green
RING  = (0xd8, 0xd5, 0xcf, 255)   # wordmark track
INK_LIGHT = (0x1c, 0x1d, 0x22, 255)   # name on a light background
INK_DARK  = (0xf5, 0xf4, 0xf0, 255)   # name on a dark background


# ── 1. favicon.ico ──────────────────────────────────────────────────────────
def pack_ico(sizes, out):
    pngs = [open(f"{BRAND}/favicon-{s}.png", "rb").read() for s in sizes]
    n = len(sizes)
    header = struct.pack("<HHH", 0, 1, n)        # reserved, type=icon, count
    offset = 6 + 16 * n
    entries, blob = b"", b""
    for s, png in zip(sizes, pngs):
        dim = 0 if s >= 256 else s               # 0 encodes 256 in ICO
        entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(png), offset)
        offset += len(png)
        blob += png
    with open(out, "wb") as f:
        f.write(header + entries + blob)
    print(f"  favicon.ico ({'/'.join(map(str, sizes))})")


# ── 2. wordmark lockup ──────────────────────────────────────────────────────
def load_bold(px):
    # Prefer the real system font (SF Pro); fall back to a plain bold TTF.
    try:
        f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", px)
        try:
            f.set_variation_by_name("Bold")
        except Exception:
            pass
        return f
    except Exception:
        return ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", px)


def draw_wordmark(ink, out):
    s = 4                                  # 4× the 148×24 SVG, for crispness
    cx, cy, r = 12 * s, 12 * s, 8 * s      # ring (centered vertically)
    stroke = round(2.67 * s)
    font = load_bold(16 * s)
    text_x = 30 * s

    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    text_w = probe.textlength("Token Tab", font=font)
    W, H = int(text_x + text_w + 6 * s), 24 * s

    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    box = [cx - r, cy - r, cx + r, cy + r]
    d.arc(box, 0, 360, fill=RING, width=stroke)            # track
    sweep = (1 - 18.6 / 50.27) * 360                       # ~63%
    d.arc(box, 270, 270 + sweep, fill=GREEN, width=stroke)  # progress (from top, cw)
    # round caps: a dot at each arc endpoint
    rad = stroke / 2
    for ang in (270, 270 + sweep):
        px = cx + r * math.cos(math.radians(ang))
        py = cy + r * math.sin(math.radians(ang))
        d.ellipse([px - rad, py - rad, px + rad, py + rad], fill=GREEN)
    d.text((text_x, cy), "Token Tab", font=font, fill=ink, anchor="lm")
    img.save(out)
    print(f"  {out.split('/')[-1]} ({W}×{H})")


pack_ico([16, 32, 48], f"{BRAND}/favicon.ico")
draw_wordmark(INK_LIGHT, f"{BRAND}/gauge-wordmark.png")
draw_wordmark(INK_DARK, f"{BRAND}/gauge-wordmark-dark.png")
