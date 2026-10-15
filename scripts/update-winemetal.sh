#!/usr/bin/env bash
# Download DXMT winemetal and generate the import library needed to build D9MT.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT/prebuilt"
VERSION=""
REPO="3Shain/dxmt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help)
      echo 'Usage: bash scripts/update-winemetal.sh [--version v0.80] [--output-dir DIR]'
      echo 'Downloads the latest DXMT release by default and replaces local prebuilt files.'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

VERSION="${VERSION:-$(gh release view --repo "$REPO" --json tagName --jq '.tagName')}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading DXMT $VERSION..."
gh release download "$VERSION" --repo "$REPO" \
  --pattern "dxmt-$VERSION-builtin.tar.gz" --dir "$WORK"
tar -xzf "$WORK/dxmt-$VERSION-builtin.tar.gz" -C "$WORK" \
  "$VERSION/i386-windows/winemetal.dll" \
  "$VERSION/x86_64-windows/winemetal.dll" \
  "$VERSION/x86_64-unix/winemetal.so"

# DLL exports are the function names needed to generate the linker import library.
i686-w64-mingw32-objdump -p "$WORK/$VERSION/i386-windows/winemetal.dll" > "$WORK/exports"
{
  echo 'LIBRARY winemetal.dll'
  echo 'EXPORTS'
  perl -ne '
    if (/^\[Ordinal\/Name Pointer\] Table/) { $exports = 1; next; }
    next unless $exports;
    last if /^\s*$/;
    print "  " . (split)[-1] . "\n" if /^\s*\[/;
  ' "$WORK/exports"
} > "$WORK/winemetal32.def"
i686-w64-mingw32-dlltool -d "$WORK/winemetal32.def" \
  -l "$WORK/libwinemetal.a" --dllname winemetal.dll
gh api "repos/$REPO/contents/LICENSE?ref=$VERSION" \
  -H 'Accept: application/vnd.github.raw+json' > "$WORK/DXMT.LICENSE"

mkdir -p "$OUTPUT_DIR"
cp "$WORK/$VERSION/i386-windows/winemetal.dll" "$OUTPUT_DIR/winemetal32.dll"
cp "$WORK/$VERSION/x86_64-windows/winemetal.dll" "$OUTPUT_DIR/winemetal.dll"
cp "$WORK/$VERSION/x86_64-unix/winemetal.so" "$OUTPUT_DIR/winemetal.so"
cp "$WORK/"{winemetal32.def,libwinemetal.a,DXMT.LICENSE} "$OUTPUT_DIR/"
echo "$VERSION" > "$OUTPUT_DIR/dxmt-version"
# Do not leave an outdated manifest from a previous preparation.
rm -f "$OUTPUT_DIR/SHA256SUMS"
echo "Prepared DXMT $VERSION in $OUTPUT_DIR. CrossOver has not been modified."
