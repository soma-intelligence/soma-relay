#!/usr/bin/env python3
"""Soma Relay app icon: two nodes joined by an arc over a radar ring, lime on near-black.
Usage: python3 Tools/make_icon.py App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"""
import sys
from PIL import Image, ImageDraw

S = 1024
SS = 4  # supersampling
BG = (0x0C, 0x0E, 0x0D)
LIME = (0xC6, 0xF2, 0x4E)
RING = (0x2A, 0x2F, 0x2A)
N = S * SS

img = Image.new("RGB", (N, N), BG)
d = ImageDraw.Draw(img)
c = N / 2

def circle(cx, cy, r, **kw):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], **kw)

# radar rings
circle(c, c + 60 * SS, 330 * SS, outline=RING, width=14 * SS)
circle(c, c + 60 * SS, 200 * SS, outline=RING, width=14 * SS)
# arc joining the two nodes (upper half of a circle)
left = (c - 250 * SS, c + 120 * SS)
right = (c + 250 * SS, c + 120 * SS)
r = 250 * SS
d.arc([c - r, left[1] - r, c + r, left[1] + r], start=180, end=360, fill=LIME, width=44 * SS)
# nodes
for (x, y) in (left, right):
    circle(x, y, 78 * SS, fill=LIME)
    circle(x, y, 30 * SS, fill=BG)
# centre dot on the ring
circle(c, c + 60 * SS, 26 * SS, fill=LIME)

img = img.resize((S, S), Image.LANCZOS)
img.save(sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png")
