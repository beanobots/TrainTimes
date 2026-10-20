#!/usr/bin/env python3
"""Draws the app's icons: each line's bullet, which the app shows for the
default widget's line.

    python3 tools/make_app_icons.py ios/App/Assets.xcassets

Each is an icon set in the asset catalog with a light, a dark and a tinted
version. The R's is AppIcon, the main icon; the others are alternate icons named
for their bullet: AppIcon-7, AppIcon-S for the three shuttles, AppIcon-SI for
Staten Island. The bullets and their colors are the app's, read from
ios/Shared/Lines.swift (see line_styles.py), and like the app's bullets the
label is centred on its capitals. Needs Pillow and the DejaVu Sans Bold font
(fonts-dejavu-core on Debian and Ubuntu).
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

from line_styles import BULLETS

FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
SIZE = 1024
CIRCLE = (150, 150, 874, 874)
BACKGROUND = (17, 17, 17)
# One letter or number, and two (SI), in proportion as LineBullet sizes them
FONT_SIZES = {1: 470, 2: round(470 * 0.45 / 0.62)}
# The tinted icon is gray, for iOS to tint: a light bullet with a dark label
TINTED_BULLET = (235, 235, 235)
TINTED_LABEL = (20, 20, 20)

CONTENTS = """{
  "images": [
    { "filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" },
    {
      "appearances": [{ "appearance": "luminosity", "value": "dark" }],
      "filename": "icon-dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"
    },
    {
      "appearances": [{ "appearance": "luminosity", "value": "tinted" }],
      "filename": "icon-tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"
    }
  ],
  "info": { "author": "xcode", "version": 1 }
}
"""


def rgb(hex_color):
    return (hex_color >> 16 & 0xFF, hex_color >> 8 & 0xFF, hex_color & 0xFF)


def draw(label, background, bullet, text):
    """The bullet on `background`, or on nothing when it's None."""
    image = Image.new("RGBA", (SIZE, SIZE), (*background, 255) if background else (0, 0, 0, 0))
    canvas = ImageDraw.Draw(image)
    canvas.ellipse(CIRCLE, fill=bullet)
    font = ImageFont.truetype(FONT, FONT_SIZES[len(label)])
    cap_height = -font.getbbox("H", anchor="ls")[1]
    canvas.text((SIZE // 2, SIZE // 2 + cap_height // 2), label, font=font, fill=text, anchor="ms")
    # The light icon can't be transparent
    return image.convert("RGB") if background else image


def main(catalog):
    for label, (color, dark_text) in BULLETS.items():
        text = (0, 0, 0) if dark_text else (255, 255, 255)
        folder = os.path.join(catalog, "AppIcon.appiconset" if label == "R" else f"AppIcon-{label}.appiconset")
        os.makedirs(folder, exist_ok=True)
        draw(label, BACKGROUND, rgb(color), text).save(os.path.join(folder, "icon.png"))
        draw(label, None, rgb(color), text).save(os.path.join(folder, "icon-dark.png"))
        draw(label, None, TINTED_BULLET, TINTED_LABEL).save(os.path.join(folder, "icon-tinted.png"))
        with open(os.path.join(folder, "Contents.json"), "w") as file:
            file.write(CONTENTS)
    print(f"Wrote {len(BULLETS)} icon sets to {catalog}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
