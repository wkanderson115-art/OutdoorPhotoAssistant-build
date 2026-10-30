"""Generate the 1024x1024 AppIcon (RGB, no alpha, no rounded corners — iOS masks it).

Usage (bundled python with Pillow):
    python scripts/make_appicon.py
"""
from __future__ import annotations

import math
import pathlib

from PIL import Image, ImageDraw, ImageFilter

W = 1024
OUT = pathlib.Path(__file__).resolve().parent.parent / "OutdoorPhotoAssistant" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"

NAVY_TOP = (10, 22, 40)
NAVY_MID = (36, 78, 110)
AMBER = (244, 176, 94)
SUN = (255, 226, 168)
MOUNTAIN_FAR = (28, 44, 62)
MOUNTAIN_NEAR = (16, 26, 38)
GROUND = (9, 14, 22)


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def sky():
    img = Image.new("RGB", (W, W), NAVY_TOP)
    draw = ImageDraw.Draw(img)
    horizon = int(W * 0.64)
    for y in range(horizon):
        t = y / max(1, horizon)
        if t < 0.55:
            color = lerp(NAVY_TOP, NAVY_MID, t / 0.55)
        else:
            color = lerp(NAVY_MID, AMBER, (t - 0.55) / 0.45)
        draw.line([(0, y), (W, y)], fill=color)
    for y in range(horizon, W):
        t = (y - horizon) / max(1, W - horizon)
        draw.line([(0, y), (W, y)], fill=lerp((22, 30, 42), GROUND, t))
    return img


def add_glow(img, center, radius, strength=110):
    glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow)
    steps = 46
    for i in range(steps, 0, -1):
        r = radius * (i / steps) * 3.4
        alpha = int(strength * (1 - i / steps) ** 2)
        draw.ellipse(
            [center[0] - r, center[1] - r, center[0] + r, center[1] + r],
            fill=(255, 210, 150, alpha),
        )
    glow = glow.filter(ImageFilter.GaussianBlur(18))
    return Image.alpha_composite(img.convert("RGBA"), glow).convert("RGB")


def sun(img, center, radius):
    draw = ImageDraw.Draw(img)
    draw.ellipse(
        [center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius],
        fill=SUN,
    )
    return img


def mountains(img):
    draw = ImageDraw.Draw(img)
    horizon = int(W * 0.665)
    far = [
        (0, horizon),
        (150, horizon - 118),
        (300, horizon - 40),
        (470, horizon - 150),
        (640, horizon - 58),
        (820, horizon - 132),
        (W, horizon - 46),
        (W, horizon),
    ]
    draw.polygon(far, fill=MOUNTAIN_FAR)
    near = [
        (0, horizon + 30),
        (200, horizon - 34),
        (420, horizon + 26),
        (600, horizon - 14),
        (W, horizon + 40),
        (W, horizon + 60),
        (0, horizon + 60),
    ]
    draw.polygon(near, fill=MOUNTAIN_NEAR)
    return img


def thirds(img):
    """Hint at the composition-assistant theme with very subtle rule-of-thirds lines."""
    overlay = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    color = (255, 255, 255, 30)
    for i in (1, 2):
        x = round(W * i / 3)
        y = round(W * i / 3)
        draw.line([(x, 0), (x, W)], fill=color, width=3)
        draw.line([(0, y), (W, y)], fill=color, width=3)
    return Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")


def shutter_ring(img):
    """Small white ring in the lower area as a camera cue."""
    overlay = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    cx, cy = W * 0.5, W * 0.835
    r = W * 0.072
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(255, 255, 255, 210), width=10)
    return Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")


def main():
    img = sky()
    img = add_glow(img, (int(W * 0.63), int(W * 0.60)), int(W * 0.085))
    img = sun(img, (int(W * 0.63), int(W * 0.60)), int(W * 0.072))
    img = mountains(img)
    img = thirds(img)
    img = shutter_ring(img)

    # 轻微暗角，让图标更有层次
    vignette = Image.new("L", (W, W), 0)
    vdraw = ImageDraw.Draw(vignette)
    vdraw.ellipse([-W * 0.25, -W * 0.25, W * 1.25, W * 1.25], fill=255)
    vignette = vignette.filter(ImageFilter.GaussianBlur(120))
    dark = Image.new("RGB", (W, W), (0, 0, 0))
    img = Image.composite(img, dark, vignette)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.convert("RGB").save(OUT, format="PNG", optimize=True)
    print(f"wrote {OUT} size={img.size} mode=RGB bytes={OUT.stat().st_size}")


if __name__ == "__main__":
    main()
