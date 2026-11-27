// Decodes Pixel Agents' PNG assets into the messages its own host sends on `webviewReady`, so ProjectN can
// replay them without Node at run time. Copied into the Pixel Agents checkout and run by scripts/build-office.sh.
import * as fs from 'node:fs';
import * as path from 'node:path';

import { buildAssetIndex, buildFurnitureCatalog } from './core/src/assets/build.ts';
import { decodeAllCarpets, decodeAllFloors, decodeAllFurniture, decodeAllWalls } from './core/src/assets/loader.ts';
import { DEFAULT_CHARACTER_PROFILES } from './core/src/defaultCharacterProfiles.ts';
import { loadPetSprites } from './server/src/assetLoader.ts';

const out = process.argv[2];
const dir = path.resolve('webview-ui/public/assets');
const catalog = buildFurnitureCatalog(dir);
const index = buildAssetIndex(dir);
const pets = await loadPetSprites(path.resolve('webview-ui/public'));
if (!index.defaultLayout) throw new Error('no default layout');
const layout = JSON.parse(fs.readFileSync(path.join(dir, index.defaultLayout), 'utf-8'));
// ProjectN's break room, added to the upstream office: games along the top wall of the lounge, beds at the bottom.
const extra: Array<[string, number, number]> = [
  ['ARCADE', 12, 10], ['GAME_TV', 15, 10], ['BED', 11, 18], ['BED', 13, 18], ['BED', 15, 18],
];
layout.furniture.push(...extra.map(([type, col, row], i) => ({ uid: `pn-${i}`, type, col, row })));

// Same order as the upstream host: cast, sprites, tiles, furniture. The layout goes last, sent by ProjectN.
const messages = [
  { type: 'characterProfilesLoaded', profiles: DEFAULT_CHARACTER_PROFILES },
  { type: 'characterSpritesLoaded', characters: [] },
  ...(pets ? [{ type: 'petSpritesLoaded', pets: pets.pets, petNames: pets.manifests.map((m) => m.name) }] : []),
  { type: 'floorTilesLoaded', sprites: decodeAllFloors(dir) },
  { type: 'wallTilesLoaded', sets: decodeAllWalls(dir) },
  { type: 'carpetTilesLoaded', sets: decodeAllCarpets(dir) },
  { type: 'furnitureAssetsLoaded', catalog, sprites: decodeAllFurniture(dir, catalog) },
];
addMeetingRooms(layout);
fs.writeFileSync(out, JSON.stringify({ messages, defaultLayout: layout }));

// Two meeting rooms to the right of the lounge, each with a table and six chairs. Their floor is an Area named
// "Meeting 1" / "Meeting 2": that name is how ProjectN seats a project's agents together (OfficeBridge.swift),
// so any area painted with it in the Layout editor works as that room.
function addMeetingRooms(l: any) {
  const cols = 28, rows = l.rows;
  const at = (c: number, r: number) => r * l.cols + c;
  const VOID = 255, WALL = 0;
  const wallColour = l.tileColors[at(19, 12)];
  const floor = l.tiles[at(15, 15)], floorColour = l.tileColors[at(15, 15)];
  if (l.tiles[at(19, 12)] !== WALL || floor === WALL || floor === VOID) throw new Error('default layout changed');
  const tiles: number[] = [], tileColors: unknown[] = [], areaTiles: Array<string | null> = [];
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      const old = c < l.cols && r < l.rows;
      tiles.push(old ? l.tiles[at(c, r)] : VOID);
      tileColors.push(old ? l.tileColors[at(c, r)] : null);
      areaTiles.push(null);
    }
  }
  const set = (c: number, r: number, tile: number, colour: unknown, area: string | null = null) => {
    tiles[r * cols + c] = tile;
    tileColors[r * cols + c] = colour;
    areaTiles[r * cols + c] = area;
  };
  // Like the lounge, the lower room has no bottom wall.
  for (let r = 10; r <= 20; r++) {
    for (let c = 19; c <= 27; c++) {
      const wall = c === 19 || c === 27 || r === 10 || r === 16;
      if (wall) set(c, r, WALL, wallColour);
    }
  }
  for (const [name, top, depth] of [['Meeting 1', 11, 5], ['Meeting 2', 17, 4]] as const) {
    for (let r = top; r < top + depth; r++) for (let c = 20; c <= 26; c++) set(c, r, floor, floorColour, name);
    // Door from the lounge.
    set(19, top + 1, floor, floorColour);
    set(19, top + 2, floor, floorColour);
    const n = name.slice(-1);
    l.furniture.push({ uid: `pn-table-${n}`, type: 'TABLE_FRONT', col: 22, row: top });
    for (let i = 0; i < 3; i++) {
      l.furniture.push({ uid: `pn-chair-${n}-l${i}`, type: 'CUSHIONED_CHAIR_SIDE', col: 21, row: top + 1 + i });
      l.furniture.push({ uid: `pn-chair-${n}-r${i}`, type: 'CUSHIONED_CHAIR_SIDE:left', col: 25, row: top + 1 + i });
    }
  }
  Object.assign(l, {
    cols, rows, tiles, tileColors, areaTiles,
    areas: [{ label: 'Meeting 1', color: '#6aa9ff' }, { label: 'Meeting 2', color: '#ffb86a' }],
  });
  delete l.carpetTiles;
}
