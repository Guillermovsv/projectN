// ProjectN's own furniture for the Office (beds and games), drawn here pixel by pixel. Copied into the Pixel Agents
// checkout by scripts/build-office.sh, which adds the PNGs and manifests to its furniture catalog.
import * as fs from 'node:fs';
import * as path from 'node:path';
import { PNG } from 'pngjs';

const dir = process.argv[2];

function sprite(id, name, w, h, footprintW, footprintH, backgroundTiles, draw) {
  const png = new PNG({ width: w, height: h });
  png.data.fill(0);
  const rect = (x, y, rw, rh, hex) => {
    for (let j = y; j < y + rh; j++) {
      for (let i = x; i < x + rw; i++) {
        const o = (j * w + i) * 4;
        png.data.set([1, 3, 5].map((k) => parseInt(hex.slice(k, k + 2), 16)).concat(255), o);
      }
    }
  };
  // A filled box with a one-pixel outline.
  const box = (x, y, bw, bh, fill, line = '#2b2233') => {
    rect(x, y, bw, bh, line);
    rect(x + 1, y + 1, bw - 2, bh - 2, fill);
  };
  draw(rect, box);
  const out = path.join(dir, id);
  fs.mkdirSync(out, { recursive: true });
  fs.writeFileSync(path.join(out, `${id}.png`), PNG.sync.write(png));
  const manifest = {
    id, name, category: 'misc', type: 'asset', canPlaceOnWalls: false, canPlaceOnSurfaces: false,
    backgroundTiles, width: w, height: h, footprintW, footprintH,
  };
  fs.writeFileSync(path.join(out, 'manifest.json'), JSON.stringify(manifest, null, 2));
}

sprite('BED', 'Bed', 16, 32, 1, 2, 0, (rect, box) => {
  box(0, 0, 16, 7, '#9a6a42'); // headboard
  rect(1, 1, 14, 2, '#b98452');
  box(0, 5, 16, 27, '#e8e4ee'); // mattress
  box(3, 7, 10, 8, '#ffffff', '#b9b3c9'); // pillow
  box(0, 17, 16, 13, '#3f6fc4'); // blanket
  rect(1, 18, 14, 3, '#cfdcf5');
  rect(1, 21, 14, 1, '#2f559a');
  rect(3, 24, 2, 2, '#5b8ada');
  rect(10, 26, 2, 2, '#5b8ada');
  box(0, 28, 16, 4, '#9a6a42'); // footboard
});

sprite('ARCADE', 'Arcade', 16, 32, 1, 2, 1, (rect, box) => {
  box(1, 2, 14, 30, '#7a3fb5');
  box(2, 3, 12, 6, '#ffcc4d'); // marquee
  rect(4, 5, 2, 2, '#d9435f');
  rect(7, 5, 2, 2, '#2fa7a0');
  rect(10, 5, 2, 2, '#d9435f');
  box(2, 10, 12, 10, '#10131f'); // screen
  rect(4, 12, 2, 2, '#6dff8b');
  rect(9, 13, 3, 2, '#ff6d6d');
  rect(6, 17, 4, 1, '#6dd8ff');
  box(1, 20, 14, 5, '#4a2a72'); // controls
  rect(4, 21, 1, 3, '#e8e4ee');
  rect(3, 21, 3, 1, '#d9435f');
  rect(9, 22, 2, 1, '#ffcc4d');
  rect(12, 22, 2, 1, '#6dff8b');
  rect(6, 27, 4, 3, '#2b2233'); // coin door
  rect(7, 28, 2, 1, '#ffcc4d');
});

sprite('GAME_TV', 'Game console', 32, 32, 2, 2, 1, (rect, box) => {
  box(2, 1, 28, 19, '#23252f'); // TV
  rect(4, 3, 24, 15, '#4fb4e8'); // game on screen
  rect(4, 13, 24, 5, '#4fa84a');
  rect(8, 10, 3, 3, '#d9435f');
  rect(21, 11, 3, 2, '#ffcc4d');
  rect(14, 6, 6, 2, '#ffffff');
  rect(14, 20, 4, 2, '#23252f'); // stand
  box(1, 22, 30, 9, '#9a6a42'); // cabinet
  rect(2, 23, 28, 2, '#b98452');
  box(5, 25, 10, 5, '#e8e4ee'); // console
  rect(7, 27, 4, 1, '#2f559a');
  rect(12, 27, 1, 1, '#6dff8b');
  box(19, 26, 8, 4, '#3a3d4d'); // gamepad
  rect(21, 27, 1, 1, '#d9435f');
  rect(24, 27, 1, 1, '#ffcc4d');
});
