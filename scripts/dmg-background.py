#!/usr/bin/env python3
"""Renders the DMG window background from design/dmg-background-source.webp.

Adds the icon frames, light plates under the labels (Finder always draws
labels in dark text) and the arrow, and writes dmg/background.png (660x440)
and dmg/background@2x.png (1320x880). Needs Pillow. The layout constants must
match scripts/make-dmg.sh.
"""
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "design" / "dmg-background-source.webp"
OUT = ROOT / "dmg"

WIDTH, HEIGHT = 660, 440          # window content size, pt
ICON_Y = 210                      # icon centres, pt
APP_X, APPS_X = 180, 480
ICON = 112                        # icon size, pt
FRAME = 124                       # frame around each icon, pt; leaves room for the alias badge
LABEL_Y = 285                     # Finder label centre, pt
LABEL_W, LABEL_H = 96, 18         # plate under each label, pt
SS = 4                            # render scale: 2x output, 2x supersampling

VIOLET = (104, 38, 255)
CYAN = (0, 214, 255)


def gradient(size):
    """Horizontal violet-to-cyan gradient across the whole window, like the rings."""
    w, h = size
    row = Image.new("RGB", (w, 1))
    for x in range(w):
        t = x / (w - 1)
        row.putpixel((x, 0), tuple(round(a + (b - a) * t) for a, b in zip(VIOLET, CYAN)))
    return row.resize((w, h))


def fill_corners(im):
    """Paints over the black rounded-corner mask of the source with the colour just inside it."""
    w, h = im.size
    r = round(w * 0.03)
    inside = Image.new("L", im.size, 0)
    ImageDraw.Draw(inside).rounded_rectangle((0, 0, w - 1, h - 1), radius=r, fill=255)
    for cx, cy in [(0, 0), (w - r, 0), (0, h - r), (w - r, h - r)]:
        sample = (r if cx == 0 else w - r - 1, r if cy == 0 else h - r - 1)
        patch = Image.new("RGB", (r, r), im.getpixel(sample))
        im.paste(patch, (cx, cy), ImageChops.invert(inside.crop((cx, cy, cx + r, cy + r))))
    return im


def main():
    s = SS
    size = (WIDTH * s, HEIGHT * s)
    base = fill_corners(Image.open(SOURCE).convert("RGB")).resize(size, Image.LANCZOS)

    mask = Image.new("L", size, 0)
    d = ImageDraw.Draw(mask)
    half = FRAME / 2 * s
    for x in (APP_X, APPS_X):
        box = (x * s - half, ICON_Y * s - half, x * s + half, ICON_Y * s + half)
        d.rounded_rectangle(box, radius=26 * s, outline=255, width=round(1.5 * s))

    # Arrow: a shaft with a chevron head, centred between the frames.
    x0, x1, y = (APP_X + FRAME / 2 + 34) * s, (APPS_X - FRAME / 2 - 34) * s, ICON_Y * s
    stroke, head = round(3 * s), 14 * s
    d.line((x0, y, x1, y), fill=255, width=stroke)
    d.line((x1 - head, y - head, x1, y, x1 - head, y + head), fill=255, width=stroke, joint="curve")
    for px, py in [(x0, y), (x1, y), (x1 - head, y - head), (x1 - head, y + head)]:
        r = stroke / 2
        d.ellipse((px - r, py - r, px + r, py + r), fill=255)

    colour = gradient(size)
    glow = mask.filter(ImageFilter.GaussianBlur(7 * s)).point(lambda v: min(255, v * 2))
    out = Image.composite(colour, base, glow.point(lambda v: v * 0.55))
    out = Image.composite(colour, out, mask)

    plates = Image.new("L", size, 0)
    d = ImageDraw.Draw(plates)
    for x in (APP_X, APPS_X):
        box = ((x - LABEL_W / 2) * s, (LABEL_Y - LABEL_H / 2) * s,
               (x + LABEL_W / 2) * s, (LABEL_Y + LABEL_H / 2) * s)
        d.rounded_rectangle(box, radius=LABEL_H / 2 * s, fill=255)
    plate_glow = plates.filter(ImageFilter.GaussianBlur(6 * s)).point(lambda v: v * 0.5)
    out = Image.composite(colour, out, plate_glow)
    tint = Image.blend(colour, Image.new("RGB", size, (255, 255, 255)), 0.82)
    out = Image.composite(tint, out, plates)

    OUT.mkdir(exist_ok=True)
    out.resize((WIDTH * 2, HEIGHT * 2), Image.LANCZOS).save(OUT / "background@2x.png")
    out.resize((WIDTH, HEIGHT), Image.LANCZOS).save(OUT / "background.png")


if __name__ == "__main__":
    main()
