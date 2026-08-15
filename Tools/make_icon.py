#!/usr/bin/env python3
"""
QualDriller app icon.

One mark carrying both halves of the app:
  * concentric rings + crosshair -> target / reticle   (the shooting half)
  * amber sweep on the outer track -> a running timer  (the drill half)

The rings double as a clock face so the two ideas share geometry instead of
being stacked. Two hues only, so it survives being drawn at 29px.

Everything is composited through antialiased masks at 4x and downsampled once,
so the crosshair "gaps" in the rings are true knockouts against the gradient
rather than flat rectangles painted over it.
"""
from PIL import Image, ImageDraw, ImageChops
import numpy as np
import pathlib

# Output lands directly in the asset catalog, so re-running this script is all
# it takes to change the icon.  Needs:  pip3 install pillow numpy
ROOT = pathlib.Path(__file__).resolve().parent.parent
ICON = ROOT / "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
PREVIEW = ROOT / "Tools/icon-preview.png"

S, SS = 1024, 4
N = S * SS
C = N / 2

BG_IN, BG_OUT = (26, 33, 44), (8, 11, 16)
RING     = (92, 108, 132)
RING_HI  = (124, 143, 170)
TRACK    = (46, 55, 70)
AMBER    = (245, 166, 35)

# geometry, as fractions of the canvas
R_TRACK, W_TRACK = 0.360, 0.050
RINGS = ((0.248, 0.032, RING), (0.140, 0.032, RING_HI))
ARM_IN, ARM_OUT = 0.062, 0.298
BAR_HALF, GAP_HALF = 0.0125, 0.026
R_DOT = 0.046
SWEEP_FROM, SWEEP_TO = -90, 38          # 12 o'clock, clockwise ~128 degrees


def blank():
    return Image.new("L", (N, N), 0)


def px(f):
    return f * N


def gradient():
    y, x = np.mgrid[0:N, 0:N].astype(np.float32)
    d = np.clip(np.sqrt((x - C) ** 2 + (y - C) ** 2) / (N * 0.70), 0, 1) ** 1.2
    a, b = np.array(BG_IN, np.float32), np.array(BG_OUT, np.float32)
    return Image.fromarray(
        (a[None, None] * (1 - d[..., None]) + b[None, None] * d[..., None]).astype(np.uint8),
        "RGB")


def bars(half):
    """Four crosshair arms, `half` thick, as a mask."""
    m = blank()
    d = ImageDraw.Draw(m)
    a_in, a_out, h = px(ARM_IN), px(ARM_OUT), px(half)
    for sign in (1, -1):
        d.rectangle([C + min(sign * a_in, sign * a_out), C - h,
                     C + max(sign * a_in, sign * a_out), C + h], fill=255)
        d.rectangle([C - h, C + min(sign * a_in, sign * a_out),
                     C + h, C + max(sign * a_in, sign * a_out)], fill=255)
    return m


def paint(base, mask, colour):
    base.paste(Image.new("RGB", base.size, colour), (0, 0), mask)


def main():
    img = gradient()

    # --- timer track, then the sweep on top of it ---------------------------
    box = [C - px(R_TRACK), C - px(R_TRACK), C + px(R_TRACK), C + px(R_TRACK)]

    m = blank()
    ImageDraw.Draw(m).arc(box, 0, 360, fill=255, width=int(px(W_TRACK)))
    paint(img, m, TRACK)

    m = blank()
    d = ImageDraw.Draw(m)
    d.arc(box, SWEEP_FROM, SWEEP_TO, fill=255, width=int(px(W_TRACK)))
    for ang in (SWEEP_FROM, SWEEP_TO):            # rounded caps
        a = np.radians(ang)
        cx, cy = C + px(R_TRACK) * np.cos(a), C + px(R_TRACK) * np.sin(a)
        r = px(W_TRACK) / 2
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    paint(img, m, AMBER)

    # --- reticle: rings knocked out by the crosshair, bars laid in the gaps --
    gap = bars(GAP_HALF)
    keep = ImageChops.invert(gap)
    for r, w, colour in RINGS:
        m = blank()
        ImageDraw.Draw(m).ellipse([C - px(r), C - px(r), C + px(r), C + px(r)],
                                  outline=255, width=int(px(w)))
        paint(img, ImageChops.multiply(m, keep), colour)
    paint(img, bars(BAR_HALF), RING)

    # --- centre pivot --------------------------------------------------------
    m = blank()
    ImageDraw.Draw(m).ellipse([C - px(R_DOT), C - px(R_DOT), C + px(R_DOT), C + px(R_DOT)],
                              fill=255)
    paint(img, m, AMBER)

    out = img.resize((S, S), Image.LANCZOS).convert("RGB")   # RGB => no alpha
    out.save(ICON, "PNG")

    # legibility sheet at the sizes iOS actually draws, on both backdrops
    pad, sizes = 22, (180, 120, 87, 60, 40, 29)
    w = pad + sum(s + pad for s in sizes)
    sheet = Image.new("RGB", (w, 250), (242, 242, 245))
    ImageDraw.Draw(sheet).rectangle([0, 125, w, 250], fill=(18, 18, 20))
    x = pad
    for s in sizes:
        t = out.resize((s, s), Image.LANCZOS)
        sheet.paste(t, (x, (125 - s) // 2))
        sheet.paste(t, (x, 125 + (125 - s) // 2))
        x += s + pad
    sheet.save(PREVIEW, "PNG")
    print(f"wrote {ICON}\nwrote {PREVIEW}")


main()
