// Render the editable SVG directly; no separate color or gradient calculation.
const fs = require("node:fs");
const path = require("node:path");
let sharp;
try { sharp = require(process.env.PALETTIFY_SHARP_PATH || "sharp"); }
catch (error) {
  console.error("Install sharp in swiftPort (npm install --no-save sharp), or set PALETTIFY_SHARP_PATH to its module directory.");
  process.exit(1);
}
const source = process.argv[2] || path.join(__dirname, "../IconSources/Palettify-aurora-background-editable.svg");
const output = process.argv[3] || source.replace(/\.svg$/i, ".png");
sharp(fs.readFileSync(source)).resize(1024, 1024).png().toFile(output)
  .then(() => console.log(output))
  .catch(error => { console.error(error.message); process.exitCode = 1; });
