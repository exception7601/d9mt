#!/usr/bin/env bash
# Download a precompiled D9MT release; no build tools or winemetal update needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="exception7601/d9mt"
VERSION=""
OUTPUT_DIR="$ROOT/build/releases"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help)
      echo 'Usage: bash scripts/download-release.sh [--version TAG] [--repo OWNER/REPO] [--output-dir DIR]'
      echo 'Downloads the latest precompiled D9MT release by default into build/releases/.'
      echo 'Checks SHA-256 before replacing local packages. Does not build or install anything.'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

VERSION="${VERSION:-$(gh release view --repo "$REPO" --json tagName --jq '.tagName')}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading precompiled D9MT $VERSION..."
gh release download "$VERSION" --repo "$REPO" \
  --pattern 'd9mt-*-macos-apple-silicon.tar.gz*' --dir "$WORK"
(cd "$WORK" && shasum -a 256 -c ./*.tar.gz.sha256)
mkdir -p "$OUTPUT_DIR"
cp "$WORK/"*.tar.gz "$WORK/"*.tar.gz.sha256 "$OUTPUT_DIR/"
echo "Downloaded to $OUTPUT_DIR. Use make install to install into CrossOver."
