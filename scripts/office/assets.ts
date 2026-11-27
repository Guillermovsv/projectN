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
fs.writeFileSync(out, JSON.stringify({ messages, defaultLayout: layout }));
