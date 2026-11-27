#!/bin/bash
# Rebuilds Office/web, the Pixel Agents interface behind the Office view, from a pinned upstream commit.
# Needs git, Node 20+ and network. The output is committed, so building ProjectN itself needs none of that.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

REPO=https://github.com/pixel-agents-hq/pixel-agents.git
COMMIT=4dd14d612fd37d89ffbbc977959f572395c4eec8

SRC="$ROOT/build/office-src"
OUT="$ROOT/Office/web"
rm -rf "$SRC"
mkdir -p "$SRC"
git -C "$SRC" init -q
git -C "$SRC" fetch -q --depth 1 "$REPO" "$COMMIT"
git -C "$SRC" checkout -q FETCH_HEAD
cd "$SRC"

# ProjectN's changes: off-duty play and sleep, and no office radio.
git apply "$ROOT/scripts/office/pixel-agents.patch"

npm ci --ignore-scripts --no-audit --no-fund
cp "$ROOT/scripts/office/furniture.mjs" ./pn-furniture.mjs
node pn-furniture.mjs webview-ui/public/assets/furniture
(cd webview-ui && npx tsc -b && npx vite build)

rm -rf "$OUT"
mkdir -p "$OUT/assets"
cp dist/webview/index.html "$OUT/"
cp dist/webview/assets/index-*.js dist/webview/assets/index-*.css "$OUT/assets/"
cp -R dist/webview/fonts "$OUT/fonts"
cp LICENSE "$OUT/LICENSE-pixel-agents.txt"
cp "$ROOT/scripts/office/assets.ts" ./pn-office-assets.mts
npx tsx pn-office-assets.mts "$OUT/office-assets.json"
cat > "$OUT/CREDITS.txt" <<CREDITS
Office view: Pixel Agents (https://github.com/pixel-agents-hq/pixel-agents), MIT, commit $COMMIT.
Character art based on MetroCity by JIK-A-4 (https://jik-a-4.itch.io/metrocity-free-topdown-character-pack).
CREDITS
echo "Built $OUT"
du -sh "$OUT"
