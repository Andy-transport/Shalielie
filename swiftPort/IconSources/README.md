# Palettify / 盘它 — Icon Composer source

Open `Palettify.icon` in Apple Icon Composer on macOS.

Four separately editable layers use a 1024 × 1024 canvas:

1. Aurora background: a smooth gradient image only, with mist, coral, lavender, blue and deep teal washes.
2. Accent white glow: a subtle transparent white glow for the second-row, fourth-column dot only.
3. Small dots: 24 white SVG circles, without glow, glass or shadow.
4. Accent dot: its original radius is retained, without a drop shadow.

The background colors and dot radii are editable in `../tools/generate_app_icon.py`;
run it with Pillow to regenerate both the Composer layers and flattened AppIcon/AboutIcon PNGs.
SVG dot elements are named by row and column for manual editing. No rounded mask is baked in.

The source package is not wired into the app target; the app uses the matching flattened PNG.
Manual Composer changes therefore require exporting/updating the flattened icon, or wiring the
saved `.icon` into Xcode. This package has not been opened or validated in Icon Composer on this
Windows machine. Validate its appearance variants on a Mac before a proper iOS release.
