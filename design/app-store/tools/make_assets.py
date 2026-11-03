#!/usr/bin/env python3
"""Leeway's App Store artwork: banners, and screenshots framed in the icon's platform edge.

    python3 make_assets.py banners
        Writes the banners into ../banners/.

    python3 make_assets.py screenshots RAW_DIR CAPTIONS_JSON OUT_DIR [--size 1320x2868]
        Frames each raw screenshot named in CAPTIONS_JSON ({"file.png": "Headline", ...}, in
        order) under its headline, on the platform edge, at the App Store size (6.9" iPhone by
        default). Raw screenshots come straight from the simulator or a device.

Needs Pillow (pip3 install pillow). The headline face is Archivo (fonts/, SIL Open Font
License), set expanded and extra bold as in the wordmark.
"""
import json
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FONT = os.path.join(HERE, "fonts", "Archivo[wdth,wght].ttf")
ICON = os.path.join(ROOT, "icon", "AppIcon-1024.png")

# The icon's colours
STRIP = (0xFB, 0xCB, 0x0A)     # the platform's yellow strip, and its edge line
DOME = (0xE6, 0xB5, 0x00)      # its domes, a shade off the strip
CONCRETE = (0x6E, 0x69, 0x61)  # the seam and the track
FLOOR = (0x8B, 0x86, 0x7D)     # the platform's concrete, behind the strip
INK = (0x16, 0x15, 0x14)       # text on FLOOR and STRIP (5:1 and 11:1)
BEZEL = (0x0B, 0x0B, 0x0C)

SS = 2  # draw at twice the size, then scale down, for smooth curves


def font(size, weight=800, width=125):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_axes([weight, width])  # Archivo's axes: weight, then width
    return f


def tracked_width(text, f, tracking):
    return sum(f.getlength(ch) for ch in text) + tracking * (len(text) - 1)


def draw_tracked(draw, x, y, text, f, fill, tracking):
    for ch in text:
        draw.text((x, y), ch, font=f, fill=fill)
        x += f.getlength(ch) + tracking


def platform_edge(draw, x0, x1, strip_top, strip_bottom, bottom, pitch):
    """The icon's edge laid level: the domed strip from strip_top to strip_bottom, then the
    seam, the yellow edge line and the track to `bottom`. Domes sit in a true stagger: rows
    0.866 of the dome spacing apart, every other row shifted half a step."""
    r = pitch * 40 / 150
    seam, line = pitch * 30 / 150, pitch * 38 / 150
    draw.rectangle([x0, strip_top, x1, strip_bottom], fill=STRIP)
    y = strip_bottom - r - 0.42 * pitch
    i = 0
    while y - r > strip_top + 0.12 * pitch:
        off = pitch / 2 if i % 2 else 0
        cx = (x0 + x1) / 2 - math.ceil((x1 - x0) / pitch) * pitch + off
        while cx < x1 + r:
            draw.ellipse([cx - r, y - r, cx + r, y + r], fill=DOME)
            cx += pitch
        y -= pitch * math.sqrt(3) / 2
        i += 1
    draw.rectangle([x0, strip_bottom, x1, strip_bottom + seam], fill=CONCRETE)
    draw.rectangle([x0, strip_bottom + seam, x1, strip_bottom + seam + line], fill=STRIP)
    draw.rectangle([x0, strip_bottom + seam + line, x1, bottom], fill=CONCRETE)


def rounded(im, radius):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.size[0] - 1, im.size[1] - 1], radius=radius, fill=255)
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    out.paste(im, (0, 0), mask)
    return out


def shadow(size, radius, blur, opacity):
    pad = blur * 3
    sh = Image.new("RGBA", (size[0] + pad * 2, size[1] + pad * 2), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([pad, pad, pad + size[0], pad + size[1]], radius=radius,
                                         fill=(40, 30, 10, int(255 * opacity)))
    return sh.filter(ImageFilter.GaussianBlur(blur)), pad


def icon_tile(size):
    """The icon as iOS shows it: the 1024 artwork in its rounded mask."""
    art = Image.open(ICON).convert("RGB").resize((size, size), Image.LANCZOS)
    return rounded(art, round(size * 0.2237))


# Banners -------------------------------------------------------------------------------------

TAGLINE = "For the New Yorker without a car"


def banner(w, h, path):
    W, H = w * SS, h * SS
    im = Image.new("RGB", (W, H), FLOOR)
    d = ImageDraw.Draw(im)
    pitch = H * 0.085
    platform_edge(d, 0, W, H * 0.615, H * 0.86, H, pitch)

    tile = round(H * 0.36)
    tx, ty = round(min(H * 0.1, W * 0.06)), round((H * 0.615 - tile) / 2)
    sh, pad = shadow((tile, tile), round(tile * 0.2237), round(H * 0.02), 0.3)
    im.paste(sh, (tx - pad, ty - pad + round(H * 0.012)), sh)
    t = icon_tile(tile)
    im.paste(t, (tx, ty), t)

    x = tx + tile + round(H * 0.07)
    room = W - x - round(H * 0.08)
    size = round(H * 0.17)
    while True:
        f = font(size)
        tr = size * 0.04
        if tracked_width("LEEWAY", f, tr) <= room or size < 20:
            break
        size -= 2
    sub = font(round(size * 0.3), weight=500, width=100)
    while sub.getlength(TAGLINE) > room:
        sub = font(sub.size - 2, weight=500, width=100)
    asc = f.getbbox("LEEWAY")[1]
    block = (f.getbbox("LEEWAY")[3] - asc) + size * 0.28 + sub.size
    top = ty + (tile - block) / 2 - asc
    draw_tracked(d, x, top, "LEEWAY", f, INK, tr)
    d.text((x + size * 0.02, top + asc + (f.getbbox("LEEWAY")[3] - asc) + size * 0.28 - sub.getbbox("T")[1]),
           TAGLINE, font=sub, fill=INK)
    im.resize((w, h), Image.LANCZOS).save(path, optimize=True)
    print("wrote", path)


# Screenshots ---------------------------------------------------------------------------------

def wrap(text, f, width):
    words, lines, line = text.split(), [], ""
    for w in words:
        test = (line + " " + w).strip()
        if f.getlength(test) <= width or not line:
            line = test
        else:
            lines.append(line)
            line = w
    lines.append(line)
    return lines


def framed(raw_path, headline, path, size=(1320, 2868)):
    w, h = size
    W, H = w * SS, h * SS
    im = Image.new("RGB", (W, H), FLOOR)
    d = ImageDraw.Draw(im)
    platform_edge(d, 0, W, H * 0.70, H * 0.86, H, W * 0.11)

    # the headline, at most two lines
    margin = W * 0.08
    fs = round(W * 0.072)
    while True:
        f = font(fs)
        lines = wrap(headline, f, W - 2 * margin)
        if len(lines) <= 2 or fs < 40:
            break
        fs -= 4
    lh = fs * 1.12
    y = H * 0.055
    for ln in lines:
        d.text(((W - f.getlength(ln)) / 2, y), ln, font=f, fill=INK)
        y += lh
    text_bottom = H * 0.055 + lh * 2  # the phone sits at the same height under one line or two

    # the phone: the screenshot in a black bezel, standing on the platform's edge
    raw = Image.open(raw_path).convert("RGB")
    bezel = round(W * 0.02)
    top = text_bottom + H * 0.03
    avail_h = H - top - H * 0.025
    sw = round(min(W * 0.76, (avail_h - 2 * bezel) * raw.size[0] / raw.size[1]))
    sh_ = round(sw * raw.size[1] / raw.size[0])
    screen = rounded(raw.resize((sw, sh_), Image.LANCZOS), round(sw * 0.14))
    pw, ph = sw + 2 * bezel, sh_ + 2 * bezel
    px, py = round((W - pw) / 2), round(top)
    shd, pad = shadow((pw, ph), round(sw * 0.14) + bezel, round(W * 0.025), 0.35)
    im.paste(shd, (px - pad, py - pad + round(W * 0.02)), shd)
    body = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle([0, 0, pw - 1, ph - 1], radius=round(sw * 0.14) + bezel, fill=BEZEL)
    im.paste(body, (px, py), body)
    im.paste(screen, (px + bezel, py + bezel), screen)
    im.resize((w, h), Image.LANCZOS).save(path, optimize=True)
    print("wrote", path)


def main(argv):
    if len(argv) >= 2 and argv[1] == "banners":
        out = os.path.join(ROOT, "banners")
        os.makedirs(out, exist_ok=True)
        for w, h, name in [(1920, 1080, "leeway-banner-1920x1080.png"), (1200, 630, "leeway-banner-1200x630.png"),
                           (1500, 500, "leeway-banner-1500x500.png")]:
            banner(w, h, os.path.join(out, name))
    elif len(argv) >= 5 and argv[1] == "screenshots":
        raw_dir, captions, out = argv[2], argv[3], argv[4]
        size = (1320, 2868)
        if "--size" in argv:
            size = tuple(int(n) for n in argv[argv.index("--size") + 1].split("x"))
        os.makedirs(out, exist_ok=True)
        for i, (name, headline) in enumerate(json.load(open(captions)).items(), 1):
            framed(os.path.join(raw_dir, name), headline, os.path.join(out, f"{i:02d}-{os.path.splitext(name)[0]}.png"), size)
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
