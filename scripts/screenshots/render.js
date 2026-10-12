// Render terminal output (24-bit SGR colors only) to a PNG "screenshot": ANSI -> SVG -> PNG via
// resvg. Used by scripts/screenshots.sh for the README images; not part of any image.
// Usage: node render.js <in.ansi> <out.png> <font.ttf> <font family>
const fs = require("fs");
const { Resvg } = require("@resvg/resvg-js");

const [input, output, fontFile, fontFamily] = process.argv.slice(2);
const cellWidth = 9.6;
const lineHeight = 21;
const pad = 24;
const top = pad + 34; // below the window buttons
const background = "#22272e";
const foreground = "#abb2bf";

const lines = fs.readFileSync(input, "utf8").replace(/\r/g, "").split("\n");
while (lines.length && !lines[lines.length - 1].trim()) lines.pop();

const xml = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
const rgb = (p, i) => `rgb(${p[i + 2]},${p[i + 3]},${p[i + 4]})`;
const shapes = [];
let columns = 0;

lines.forEach((line, row) => {
  let col = 0;
  let fg = foreground;
  let bg = null;
  const tokens = /\x1b\[([0-9;]*)m|([^\x1b]+)/g;
  let m;
  while ((m = tokens.exec(line))) {
    if (m[1] !== undefined) {
      const p = m[1].split(";").map(Number);
      for (let i = 0; i < p.length; i++) {
        if (p[i] === 38 && p[i + 1] === 2) {
          fg = rgb(p, i);
          i += 4;
        } else if (p[i] === 48 && p[i + 1] === 2) {
          bg = rgb(p, i);
          i += 4;
        } else if (p[i] === 39) {
          fg = foreground;
        } else if (p[i] === 49) {
          bg = null;
        } else if (p[i] === 0) {
          fg = foreground;
          bg = null;
        }
      }
      continue;
    }
    for (const ch of m[2]) {
      const x = pad + col * cellWidth;
      const y = top + row * lineHeight;
      if (bg)
        shapes.push(`<rect x="${x}" y="${y - 15.5}" width="${cellWidth + 0.5}" height="${lineHeight}" fill="${bg}"/>`);
      if (ch !== " ") shapes.push(`<text x="${x}" y="${y}" fill="${fg}">${xml(ch)}</text>`);
      col++;
    }
  }
  columns = Math.max(columns, col);
});

const width = Math.ceil(pad * 2 + columns * cellWidth);
const height = pad * 2 + 30 + lines.length * lineHeight;
const buttons = ["#ff5f57", "#febc2e", "#28c840"]
  .map((c, i) => `<circle cx="${pad + 6 + i * 20}" cy="${pad - 4}" r="6" fill="${c}"/>`)
  .join("");
const svg =
  `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">` +
  `<rect width="100%" height="100%" rx="12" fill="${background}"/>${buttons}` +
  `<g font-family="${fontFamily}" font-size="16" xml:space="preserve">${shapes.join("")}</g></svg>`;

const png = new Resvg(svg, {
  font: { fontFiles: [fontFile], loadSystemFonts: false, defaultFontFamily: fontFamily },
  fitTo: { mode: "zoom", value: 2 },
})
  .render()
  .asPng();
fs.writeFileSync(output, png);
console.log(`screenshots: ${output} (${width}x${height}, ${Math.round(png.length / 1024)} KiB)`);
