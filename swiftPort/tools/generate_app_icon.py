"""Generate the flattened icon and editable Icon Composer layers. Requires Pillow, Node.js and sharp."""
from pathlib import Path
import json
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
# The editable SVG is the only background source. Do not duplicate its gradient in code.

def background():
    import subprocess
    source = ROOT / "IconSources" / "Palettify-aurora-background-editable.svg"
    rendered = source.with_suffix(".png")
    subprocess.run(["node", str(ROOT / "tools" / "render_icon_background.cjs"),
                    str(source), str(rendered)], check=True)
    with Image.open(rendered) as image:
        return image.convert("RGB")


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
