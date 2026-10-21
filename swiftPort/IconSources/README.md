# Palettify / 盘它 — Icon Composer source

Open `Palettify.icon` with Apple Icon Composer on macOS.

- Canvas fill: editable blue gradient, with a separate dark appearance.
- Back group: optional soft highlight shapes (toggle or remove to taste).
- Front group: the 25 white dots, with native glass/specular settings.
- Every SVG uses a 1024 x 1024 canvas. Each dot has a named SVG element.
- Do not bake in rounded corners: iOS supplies the icon mask.

The original flattened AppIcon and AboutIcon PNGs are untouched. This source package is
not wired into the app target yet, so manual edits do not unexpectedly change a release.
When ready, add the saved `.icon` to the app target and select its name as the app icon;
remove/rename the old same-name asset to avoid ambiguity. Icon Composer/Xcode must render
and validate final appearance variants on a Mac; the package has not been opened on this
Windows machine. SVGs are editable directly in vector editors on Windows.
