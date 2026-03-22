#!/usr/bin/env python3
"""Generate the DMG installer background image for CYFR Porta.

Usage:
    python3 scripts/gen_dmg_bg.py

Output:
    icons/dmg-background.png  (660x400)

The background has:
- Dark gradient matching CYFR theme
- Prominent right-pointing arrow between icon positions
- Subtle instructional text
"""

from PIL import Image, ImageDraw, ImageFont
import os

# DMG window size (from tauri.conf.json)
WIDTH = 660
HEIGHT = 400

# Icon positions (from tauri.conf.json) — app left, Applications right
APP_X = 180
APPS_X = 480
ICON_Y = 170

# Colors
BG_TOP = (15, 15, 26)       # #0f0f1a
BG_BOTTOM = (26, 26, 46)    # #1a1a2e
ARROW_COLOR = (99, 102, 241) # #6366f1
ARROW_GLOW = (99, 102, 241, 40)
TEXT_COLOR = (148, 163, 184)  # #94a3b8
TITLE_COLOR = (226, 232, 240) # #e2e8f0


def lerp_color(c1, c2, t):
    """Linear interpolation between two RGB colors."""
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


def draw_gradient(img):
    """Draw vertical gradient from BG_TOP to BG_BOTTOM."""
    draw = ImageDraw.Draw(img)
    for y in range(HEIGHT):
        t = y / HEIGHT
        color = lerp_color(BG_TOP, BG_BOTTOM, t)
        draw.line([(0, y), (WIDTH, y)], fill=color)


def draw_arrow(draw):
    """Draw a prominent right-pointing arrow between icon positions."""
    center_x = (APP_X + APPS_X) // 2
    center_y = ICON_Y

    # Arrow dimensions — large and bold like the OpenRocket example
    shaft_len = 90
    shaft_half_h = 10
    head_len = 36
    head_half_h = 28

    # Shaft (rectangle)
    sx = center_x - shaft_len // 2 - head_len // 4
    draw.rectangle(
        [sx, center_y - shaft_half_h, sx + shaft_len, center_y + shaft_half_h],
        fill=ARROW_COLOR
    )

    # Arrowhead (triangle pointing right)
    tip_x = sx + shaft_len + head_len
    draw.polygon(
        [
            (sx + shaft_len, center_y - head_half_h),
            (tip_x, center_y),
            (sx + shaft_len, center_y + head_half_h),
        ],
        fill=ARROW_COLOR
    )


def draw_glow(img):
    """Draw a subtle glow behind the arrow area."""
    overlay = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    center_x = (APP_X + APPS_X) // 2
    center_y = ICON_Y

    # Soft elliptical glow
    for r in range(80, 0, -2):
        alpha = int(12 * (1 - r / 80))
        draw.ellipse(
            [center_x - r * 2, center_y - r, center_x + r * 2, center_y + r],
            fill=(99, 102, 241, alpha)
        )

    img.paste(Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB"))


def draw_text(draw):
    """Draw instructional text below the icons."""
    text = "Drag to Applications to install"
    # Use system font or fallback
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 14)
    except (IOError, OSError):
        try:
            font = ImageFont.truetype("/System/Library/Fonts/SFNSText.ttf", 14)
        except (IOError, OSError):
            font = ImageFont.load_default()

    bbox = draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    text_x = (WIDTH - text_w) // 2
    text_y = ICON_Y + 65

    draw.text((text_x, text_y), text, fill=TEXT_COLOR, font=font)


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    output_path = os.path.join(script_dir, "..", "icons", "dmg-background.png")

    img = Image.new("RGB", (WIDTH, HEIGHT), BG_TOP)
    draw_gradient(img)
    draw_glow(img)

    draw = ImageDraw.Draw(img)
    draw_arrow(draw)
    draw_text(draw)

    img.save(output_path, "PNG")
    print(f"Generated: {os.path.abspath(output_path)}")


if __name__ == "__main__":
    main()
