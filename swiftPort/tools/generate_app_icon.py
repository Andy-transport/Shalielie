"""Generate the flattened icon and editable Icon Composer layers. Requires Pillow."""
from pathlib import Path
import json
import math
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 4
GRID = 5
ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Resources" / "Assets.xcassets"
SOURCE = ROOT / "IconSources" / "Palettify.icon"
ACCENT = (1, 3)  # second row, fourth column; keep its original size
DOT_RADIUS = 0.022
ACCENT_RADIUS = 0.036
# Aurora mesh: explicit gold/mint/aqua bridges avoid mixing complementary
# coral and teal directly into a muddy gray. Each row runs left to right.
MESH = [
    (0.00, [(200, 210, 202), (211, 207, 188), (232, 125, 133)]),
    (0.27, [(147, 177, 173), (182, 190, 174), (207, 171, 149)]),
    (0.50, [(98, 145, 148), (125, 160, 151), (153, 166, 143)]),
    (0.74, [(41, 85, 88), (55, 100, 95), (64, 99, 88)]),
    (1.00, [(22, 45, 47), (27, 55, 53), (24, 49, 47)]),
]


def blend(a, b, t):
    t = (1 - math.cos(math.pi * t)) / 2
    return tuple(x * (1 - t) + y * t for x, y in zip(a, b))


def row_color(colors, u):
    # Warm light enters from above and the right, with cool light on the left.
    if u <= 0.5:
        return blend(colors[0], colors[1], u * 2)
    return blend(colors[1], colors[2], (u - 0.5) * 2)


def background():
    small = 256
    image = Image.new("RGB", (small, small))
    pixels = image.load()
    for y in range(small):
        v = y / (small - 1)
        for x in range(small):
            u = x / (small - 1)
            for (v0, colors0), (v1, colors1) in zip(MESH, MESH[1:]):
                if v <= v1:
                    color = blend(row_color(colors0, u), row_color(colors1, u), (v-v0)/(v1-v0))
                    pixels[x,y] = tuple(round(c) for c in color)
                    break
    return image.resize((SIZE, SIZE), Image.Resampling.BICUBIC)


def centers():
    for row in range(GRID):
        for col in range(GRID):
            yield row, col, SIZE * (0.24 + col * 0.13), SIZE * (0.24 + row * 0.13)


def svg(accent):
    circles = []
    for row, col, x, y in centers():
        if ((row, col) == ACCENT) == accent:
            radius = SIZE * (ACCENT_RADIUS if accent else DOT_RADIUS)
            circles.append(f'<circle id="dot-r{row+1}-c{col+1}" cx="{x:.3f}" cy="{y:.3f}" r="{radius:.3f}" fill="white"/>')
    return '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">' + ''.join(circles) + '</svg>\n'


def layers():
    n = SIZE * SS
    ordinary = Image.new("RGBA", (n, n))
    accent = Image.new("RGBA", (n, n))
    glow = Image.new("RGBA", (n, n))
    for row, col, x, y in centers():
        selected = (row, col) == ACCENT
        radius = n * (ACCENT_RADIUS if selected else DOT_RADIUS)
        cx, cy = x * SS, y * SS
        ImageDraw.Draw(accent if selected else ordinary).ellipse((cx-radius, cy-radius, cx+radius, cy+radius), fill="white")
        if selected:
            r = n * 0.044
            ImageDraw.Draw(glow).ellipse((cx-r, cy-r, cx+r, cy+r), fill=(255,255,255,90))
    mask = glow.getchannel("A").filter(ImageFilter.GaussianBlur(n * 0.017))
    glow = Image.new("RGBA", (n, n), (255, 255, 255, 0))
    glow.putalpha(mask)
    return [layer.resize((SIZE,SIZE), Image.Resampling.LANCZOS) for layer in (glow, ordinary, accent)]


def main():
    source_assets = SOURCE / "Assets"
    source_assets.mkdir(parents=True, exist_ok=True)
    base = background()
    glow, ordinary, accent = layers()
    base.save(source_assets / "01-aurora-background.png", optimize=True)
    glow.save(source_assets / "02-accent-white-glow.png", optimize=True)
    (source_assets / "03-small-dots.svg").write_text(svg(False), encoding="utf-8")
    (source_assets / "04-accent-dot.svg").write_text(svg(True), encoding="utf-8")
    composite = base.convert("RGBA")
    for layer in (glow, ordinary, accent):
        composite = Image.alpha_composite(composite, layer)
    for path in (ASSETS / "AppIcon.appiconset/icon-1024.png", ASSETS / "AboutIcon.imageset/about-icon.png"):
        composite.convert("RGB").save(path, optimize=True)
        print(path)
    groups = []
    for name, filename in [("Aurora background", "01-aurora-background.png"), ("Accent glow", "02-accent-white-glow.png"), ("Small dots", "03-small-dots.svg"), ("Accent dot", "04-accent-dot.svg")]:
        groups.append({"name": name, "specular": False, "shadow": {"kind": "neutral", "opacity": 0}, "layers": [{"name": name, "image-name": filename, "glass": False, "position": {"scale": 1, "translation-in-points": [0,0]}}]})
    manifest = {"color-space-for-untagged-svg-colors":"srgb", "fill":{"solid":"srgb:0.09412,0.19216,0.19216,1.00000"}, "groups":groups, "supported-platforms":{"squares":"shared"}}
    (SOURCE / "icon.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

if __name__ == "__main__":
    main()
