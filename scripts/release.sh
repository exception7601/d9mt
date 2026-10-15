#!/usr/bin/env bash
# Build this checkout using the winemetal already downloaded into prebuilt/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="" PUBLISH=0 DRAFT=0
REPO="exception7601/d9mt"
OUTPUT_DIR="$ROOT/build/releases"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --publish) PUBLISH=1; shift ;;
    --draft) DRAFT=1; shift ;;
    -h|--help)
      echo 'Usage: bash scripts/release.sh [--publish] [--draft] [--version VERSION]'
      echo 'Optional: --repo OWNER/REPO --output-dir DIR'
      echo 'Uses the current Git tag (or commit) and the local prebuilt/dxmt-version.'
      echo 'Publishing requires a clean checkout and an existing matching remote tag.'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --exact-match HEAD 2>/dev/null || git -C "$ROOT" rev-parse --short HEAD)}"
[[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Invalid version.' >&2; exit 1; }
[[ "$DRAFT" == 0 || "$PUBLISH" == 1 ]] || { echo '--draft requires --publish.' >&2; exit 1; }
WINEMETAL_DIR="$ROOT/prebuilt"
DXMT_VERSION="$(< "$WINEMETAL_DIR/dxmt-version")"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
DIRTY=0
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || DIRTY=1
if [[ "$PUBLISH" == 1 ]]; then
  [[ "$DIRTY" == 0 ]] || { echo 'Commit local changes separately before publishing.' >&2; exit 1; }
  git -C "$ROOT" show-ref --verify --quiet "refs/tags/$VERSION" || {
    echo 'Publishing requires an existing Git tag. Use make package for a local build.' >&2
    exit 1
  }
  REMOTE_COMMIT="$(gh api "repos/$REPO/commits/$VERSION" --jq '.sha')"
  [[ "$REMOTE_COMMIT" == "$COMMIT" ]] || { echo 'The release tag must match this checkout HEAD.' >&2; exit 1; }
  if gh release view "$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release $VERSION already exists." >&2
    exit 1
  fi
fi
xcrun --sdk macosx metal --version >/dev/null 2>&1 || {
  echo 'Install the Metal compiler: xcodebuild -downloadComponent MetalToolchain' >&2
  exit 1
}

mkdir -p "$ROOT/build" "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
WORK="$(mktemp -d "$ROOT/build/release.XXXXXX")"
cleanup() {
  if [[ "$1" == 0 ]]; then rm -rf "$WORK"; else echo "Build failed; diagnostics retained at $WORK" >&2; fi
}
trap 'cleanup "$?"' EXIT
BUILD_DIR="$WORK/build"
# Avoid inheriting the build machine OS as the minimum supported macOS.
MACOSX_DEPLOYMENT_TARGET=15.0
export BUILD_DIR WINEMETAL_DIR MACOSX_DEPLOYMENT_TARGET
bash "$ROOT/tools/build-d9mtmetal.sh" --build-only
RELEASE=1 TRACY=0 D9MT_HUD=0 bash "$ROOT/scripts/build-dxvkfe.sh"

NAME="d9mt-$VERSION-macos-apple-silicon"
PACKAGE="$WORK/$NAME"
mkdir -p "$PACKAGE/runtime" "$PACKAGE/licenses"
cp "$BUILD_DIR/d3d9fe.dll" "$PACKAGE/runtime/d3d9.dll"
cp "$BUILD_DIR/d9mtmetal/"{d9mtmetal32.dll,d9mtmetal64.dll,d9mtmetal.so} "$PACKAGE/runtime/"
cp "$WINEMETAL_DIR/"{winemetal32.dll,winemetal.dll,winemetal.so} "$PACKAGE/runtime/"
cp "$ROOT/scripts/setup-crossover.sh" "$PACKAGE/setup-crossover.sh"
cp "$WINEMETAL_DIR/DXMT.LICENSE" "$PACKAGE/licenses/DXMT.LICENSE"
DXVK_VERSION="$(perl -ne 'print $1 if /^Tag:\s+(\S+)/' "$ROOT/vendor/dxvk/DXVK-VERSION")"
gh api "repos/doitsujin/dxvk/contents/LICENSE?ref=$DXVK_VERSION" \
  -H 'Accept: application/vnd.github.raw+json' > "$PACKAGE/licenses/DXVK.LICENSE"
cp "$ROOT/vendor/spirv-cross/LICENSE" "$PACKAGE/licenses/SPIRV-Cross.LICENSE"
cp "$ROOT/vendor/dxvk/include/spirv/LICENSE" "$PACKAGE/licenses/SPIRV-Headers.LICENSE"
cp -R "$ROOT/vendor/dxvk/include/vulkan/LICENSES" "$PACKAGE/licenses/Vulkan-Headers"
cp "$ROOT/vendor/dxvk/include/native/directx/COPYING.MinGW-w64.txt" "$PACKAGE/licenses/MinGW-w64.LICENSE"
{
  echo "version=$VERSION"
  echo "commit=$COMMIT"
  echo "dirty=$DIRTY"
  echo "dxmt_version=$DXMT_VERSION"
  echo 'configuration=release'
  echo 'game_architecture=i386'
  echo 'macos_minimum=15.0'
} > "$PACKAGE/build-info"
(
  cd "$PACKAGE"
  find runtime licenses -type f | LC_ALL=C sort | while IFS= read -r path; do shasum -a 256 "$path"; done > SHA256SUMS
  shasum -a 256 setup-crossover.sh build-info >> SHA256SUMS
)
ARCHIVE="$OUTPUT_DIR/$NAME.tar.gz"
tar -czf "$ARCHIVE" -C "$WORK" "$NAME"
(cd "$OUTPUT_DIR" && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
echo "Built: $ARCHIVE"
if [[ "$PUBLISH" == 1 ]]; then
  NOTES="Precompiled D9MT for 32-bit D3D9 games on Apple Silicon, macOS 15+.
Built from commit $COMMIT with DXMT $DXMT_VERSION winemetal.
Includes setup-crossover.sh; run it with --help before installing.

*Posted by Claude (Opus 4.6) on behalf of @exception7601 with approval.*"
  args=(release create "$VERSION" "$ARCHIVE" "$ARCHIVE.sha256" --repo "$REPO"
    --verify-tag --title "$VERSION" --notes "$NOTES")
  [[ "$DRAFT" == 0 ]] || args+=(--draft)
  gh "${args[@]}"
fi
