#!/usr/bin/env bash
# Filesystem/registry integration tests using a disposable fake CrossOver bundle.
# No real Wine, Homebrew, compiler, Python, network or installed app is invoked.
set -euo pipefail

# Symlink this script to tool names to provide portable, inspectable mocks.
case "$(basename "$0")" in
  uname)
    case "${1:-}" in -s) printf 'Darwin\n' ;; -m) printf 'arm64\n' ;; *) exit 1 ;; esac
    exit 0 ;;
  file)
    case "${2:-}" in
      *64.dll|*/winemetal.dll) printf 'PE32+ executable (DLL) x86-64, for MS Windows\n' ;;
      *) printf 'PE32 executable (GUI) Intel 80386, for MS Windows\n' ;;
    esac
    exit 0 ;;
  xcrun)
    # A resolvable wrapper is not enough: execution can fail without the toolchain.
    if [[ "${FAKE_MISSING_METAL:-0}" == 1 && "$*" == *'metal --version'* ]]; then exit 1; fi
    printf '/fake/metal\n'
    exit 0 ;;
  sw_vers) printf '%s\n' "${FAKE_MACOS_VERSION:-15.0}"; exit 0 ;;
  git)
    shift 2 # -C ROOT
    case "$1" in
      rev-parse)
        if [[ "$2" == --short ]]; then echo '0000001'; else printf '%040d\n' 1; fi
        ;;
      describe) [[ "${FAKE_NO_TAG:-0}" == 0 ]] || exit 1; echo 'v0.1.0' ;;
      show-ref) [[ "${FAKE_NO_TAG:-0}" == 0 ]] || exit 1 ;;
      status) [[ "${FAKE_DIRTY:-0}" == 0 ]] || printf ' M scripts/release.sh\n' ;;
      *) exit 12 ;;
    esac
    exit 0 ;;
  gh)
    printf '%q ' "$@" >> "$FAKE_GH_LOG"
    printf '\n' >> "$FAKE_GH_LOG"
    case "$1 $2" in
      'release create') exit 0 ;;
      'release view')
        [[ "$3" == --repo ]] || exit 1
        echo 'v0.1.0'
        exit 0
        ;;
      'release download')
        shift 3 # release download TAG
        destination=''
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --dir) destination="$2"; shift 2 ;;
            --repo|--pattern) shift 2 ;;
            *) exit 13 ;;
          esac
        done
        for asset in "$FAKE_DOWNLOAD_SOURCE/"*.tar.gz*; do cp "$asset" "$destination/"; done
        if [[ "${FAKE_CORRUPT_DOWNLOAD:-0}" == 1 ]]; then
          for asset in "$destination/"*.tar.gz; do echo 'tampered' >> "$asset"; done
        fi
        exit 0
        ;;
      api\ *)
        case "$2" in
          repos/doitsujin/dxvk/contents/LICENSE*) echo 'fixture DXVK license' ;;
          repos/exception7601/d9mt/commits/*) printf '%040d\n' "${FAKE_REMOTE_NUMBER:-1}" ;;
          *) exit 13 ;;
        esac
        exit 0
        ;;
      *) exit 13 ;;
    esac ;;
  build-d9mtmetal.sh)
    [[ "$1" == --build-only && -n "$BUILD_DIR" && "$MACOSX_DEPLOYMENT_TARGET" == 15.0 ]] || exit 15
    mkdir -p "$BUILD_DIR/d9mtmetal"
    for name in d9mtmetal32.dll d9mtmetal64.dll d9mtmetal.so; do
      printf '%064dWine builtin DLL\0built %s\n' 0 "$name" > "$BUILD_DIR/d9mtmetal/$name"
    done
    exit 0 ;;
  build-dxvkfe.sh)
    [[ "$RELEASE" == 1 && "$TRACY" == 0 && "$D9MT_HUD" == 0 && -n "$BUILD_DIR" ]] || exit 16
    printf 'built driver\n' > "$BUILD_DIR/d3d9fe.dll"
    exit 0 ;;
  clang|python3|glslang|i686-w64-mingw32-gcc|i686-w64-mingw32-g++|i686-w64-mingw32-dlltool|x86_64-w64-mingw32-gcc|x86_64-w64-mingw32-dlltool)
    printf 'Unexpected compiler/interpreter invocation in fixture test\n' >&2
    exit 17 ;;
  wine)
    printf '%q ' "$@" >> "$FAKE_WINE_LOG"
    printf '\n' >> "$FAKE_WINE_LOG"
    [[ "$1" == --bottle && "$CX_BOTTLE_PATH/$2" == "$FAKE_BOTTLE" ]] || exit 9
    shift 2
    if [[ "$1" == --dll ]]; then
      [[ "$2" == 'd3d9=n;winemetal=b;d9mtmetal=b' && "$3" == start && "$4" == /unix ]] || exit 8
      exit 0
    fi
    [[ "$1" == reg ]] || exit 7
    operation="$2" key="$3"
    shift 3
    # Probe that the registry is available, without creating anything.
    [[ "$operation" != query || $# != 0 ]] || exit 0
    [[ "$1" == /v ]] || exit 6
    name="$2"
    path="$FAKE_REGISTRY/$(printf '%s:%s' "$key" "$name" | shasum -a 256 | awk '{print $1}')"
    case "$operation" in
      query)
        [[ -f "$path" ]] || exit 1
        printf '    %s    REG_SZ    %s\r\n' "$name" "$(< "$path")"
        ;;
      add)
        [[ "$3" == /t && "$4" == REG_SZ && "$5" == /d && "$7" == /f ]] || exit 5
        if [[ -f "$FAKE_FAIL_ONCE" && "$name" == d9mtmetal ]]; then rm "$FAKE_FAIL_ONCE"; exit 4; fi
        printf '%s\n' "$6" > "$path"
        ;;
      delete) rm "$path" ;;
      *) exit 3 ;;
    esac
    exit 0 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/test/scripts-test.sh"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/d9mt-scripts.XXXXXX")"
TEMP="$(cd "$TEMP" && pwd)"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/bin" "$TEMP/registry"
for tool in uname file xcrun sw_vers wine; do ln -s "$SELF" "$TEMP/bin/$tool"; done
export PATH="$TEMP/bin:$PATH"
export FAKE_WINE_LOG="$TEMP/wine.log" FAKE_REGISTRY="$TEMP/registry"
export FAKE_FAIL_ONCE="$TEMP/fail-once"
APP="$TEMP/Fake CrossOver.app"
CX="$APP/Contents/SharedSupport/CrossOver"
BOTTLE="$TEMP/Custom Bottles/Test Bottle"
export FAKE_BOTTLE="$BOTTLE"
GAME="$BOTTLE/drive_c/Game With Spaces"
PACKAGE="$TEMP/extracted release"
mkdir -p "$CX/bin" "$BOTTLE/drive_c/windows/"{syswow64,system32} "$GAME" "$PACKAGE/runtime"
ln -s "$SELF" "$CX/bin/wine"
for tree in wine dxmt; do
  for arch in i386-windows x86_64-windows x86_64-unix; do
    mkdir -p "$CX/lib/$tree/$arch"
    if [[ "$arch" == x86_64-unix ]]; then name=winemetal.so; else name=winemetal.dll; fi
    printf 'original %s %s\n' "$tree" "$arch" > "$CX/lib/$tree/$arch/$name"
  done
done
printf 'original game driver\n' > "$GAME/d3d9.dll"
printf 'original companion\n' > "$BOTTLE/drive_c/windows/syswow64/d9mtmetal.dll"
printf 'fake game\n' > "$GAME/Test Game.exe"
for name in d3d9.dll winemetal32.dll winemetal.dll winemetal.so d9mtmetal32.dll d9mtmetal64.dll d9mtmetal.so; do
  printf 'release binary %s\n' "$name" > "$PACKAGE/runtime/$name"
done
printf 'version=v0.1.0\n' > "$PACKAGE/build-info"
(cd "$PACKAGE" && shasum -a 256 runtime/* > SHA256SUMS)
GLOBAL_KEY='HKCU\Software\Wine\DllOverrides'
GAME_KEY='HKCU\Software\Wine\AppDefaults\Test Game.exe\DllOverrides'
reg_path() { printf '%s/%s' "$FAKE_REGISTRY" "$(printf '%s:%s' "$1" "$2" | shasum -a 256 | awk '{print $1}')"; }
printf 'native,builtin\n' > "$(reg_path "$GLOBAL_KEY" winemetal)"
printf 'builtin,native\n' > "$(reg_path "$GAME_KEY" d3d9)"
args=(--crossover "$APP" --bottle 'Test Bottle' --bottle-dir "$BOTTLE"
  --game-exe "$GAME/Test Game.exe" --package-dir "$PACKAGE")
run() { bash "$ROOT/scripts/setup-crossover.sh" "$1" "${args[@]}" "${@:2}"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_failure() { if "$@" > "$TEMP/expected-error" 2>&1; then fail 'Command unexpectedly succeeded'; fi; }
snapshot() {
  find "$CX" "$BOTTLE" "$FAKE_REGISTRY" -type f | LC_ALL=C sort | while IFS= read -r path; do shasum -a 256 "$path"; done
}
snapshot > "$TEMP/baseline"
run doctor > "$TEMP/doctor"
[[ ! -e "$FAKE_WINE_LOG" ]] || fail 'doctor executed Wine'
export FAKE_MISSING_METAL=1
expect_failure run doctor
unset FAKE_MISSING_METAL
export FAKE_MACOS_VERSION=14.0
expect_failure run doctor
unset FAKE_MACOS_VERSION
run install --dry-run > "$TEMP/plan"
[[ ! -e "$FAKE_WINE_LOG" ]] || fail 'dry-run executed Wine'
[[ ! -e "$CX/lib/.d9mt-backup" ]] || fail 'dry-run wrote backup'
expect_failure run install
[[ ! -e "$FAKE_WINE_LOG" ]] || fail 'install without consent executed Wine'
# A malformed package must be rejected before any Wine calls or modifications.
printf 'tampered\n' >> "$PACKAGE/runtime/d3d9.dll"
expect_failure run install --allow-bundle-modification
[[ ! -e "$FAKE_WINE_LOG" ]] || fail 'bad checksum executed Wine'
printf 'release binary d3d9.dll\n' > "$PACKAGE/runtime/d3d9.dll"

run install --allow-bundle-modification > "$TEMP/install"
[[ -f "$CX/lib/.d9mt-backup/complete" ]] || fail 'install did not complete'
cmp "$PACKAGE/runtime/d3d9.dll" "$GAME/d3d9.dll"
[[ "$(< "$(reg_path "$GLOBAL_KEY" winemetal)")" == builtin ]] || fail 'missing winemetal override'
[[ "$(< "$(reg_path "$GAME_KEY" d3d9)")" == native ]] || fail 'missing game override'
expect_failure run install --allow-bundle-modification
run launch > "$TEMP/launch"
grep -q -- '--dll' "$FAKE_WINE_LOG" || fail 'launch omitted --dll'
log_hash="$(shasum -a 256 "$FAKE_WINE_LOG")"
run restore --dry-run > "$TEMP/restore-plan"
[[ "$(shasum -a 256 "$FAKE_WINE_LOG")" == "$log_hash" ]] || fail 'restore dry-run called Wine'
expect_failure run restore
# A later bundle update must not be overwritten by restoration.
printf 'external update\n' > "$CX/lib/wine/i386-windows/winemetal.dll"
expect_failure run restore --allow-bundle-modification
[[ -d "$CX/lib/.d9mt-backup" ]] || fail 'unsafe restore removed backup'
cmp "$GAME/d3d9.dll" "$PACKAGE/runtime/d3d9.dll"
cp "$PACKAGE/runtime/winemetal32.dll" "$CX/lib/wine/i386-windows/winemetal.dll"
run restore --allow-bundle-modification > "$TEMP/restore"
snapshot > "$TEMP/after-restore"
cmp "$TEMP/baseline" "$TEMP/after-restore" || fail 'restore changed original files/registry'

# Simulate an interrupted install after file copies and one registry write.
touch "$FAKE_FAIL_ONCE"
expect_failure run install --allow-bundle-modification
[[ ! -d "$CX/lib/.d9mt-backup" ]] || fail 'rollback left a completed backup'
snapshot > "$TEMP/after-rollback"
cmp "$TEMP/baseline" "$TEMP/after-rollback" || fail 'rollback did not restore originals'
# Snapshot failure must remove its incomplete state without applying anything.
ln -s "$TEMP/nonexistent" "$CX/lib/wine/i386-windows/d9mtmetal.dll"
expect_failure run install --allow-bundle-modification
[[ ! -d "$CX/lib/.d9mt-backup" ]] || fail 'preparation failure left an unusable state'
rm "$CX/lib/wine/i386-windows/d9mtmetal.dll"
snapshot > "$TEMP/after-preparation-failure"
cmp "$TEMP/baseline" "$TEMP/after-preparation-failure" || fail 'preparation failure changed originals'

# Exercise the Makefile installer against the same disposable bundle.
MAKE_FIXTURE="$TEMP/make install"
mkdir -p "$MAKE_FIXTURE"
ln -s "$ROOT/scripts" "$MAKE_FIXTURE/scripts"
cp -R "$PACKAGE" "$TEMP/d9mt-v0.1.0-macos-apple-silicon"
tar -czf "$TEMP/install-package.tar.gz" -C "$TEMP" d9mt-v0.1.0-macos-apple-silicon
mkdir -p "$MAKE_FIXTURE/build/releases"
printf 'broken old archive\n' > "$MAKE_FIXTURE/build/releases/d9mt-old.tar.gz"
touch -t 200001010000 "$MAKE_FIXTURE/build/releases/d9mt-old.tar.gz"
cp "$TEMP/install-package.tar.gz" "$MAKE_FIXTURE/build/releases/d9mt-current.tar.gz"
make_args=(-C "$MAKE_FIXTURE" -f "$ROOT/Makefile" "CX_APP=$APP" 'BOTTLE=Test Bottle'
  "BOTTLE_DIR=$BOTTLE" "GAME_EXE=$GAME/Test Game.exe")
log_hash="$(shasum -a 256 "$FAKE_WINE_LOG")"
make "${make_args[@]}" install-dry-run > "$TEMP/make-install-plan"
[[ "$(shasum -a 256 "$FAKE_WINE_LOG")" == "$log_hash" ]] || fail 'make install-dry-run executed Wine'
[[ ! -d "$CX/lib/.d9mt-backup" ]] || fail 'make install-dry-run modified CrossOver'
make "${make_args[@]}" install > "$TEMP/make-install"
[[ -f "$CX/lib/.d9mt-backup/complete" ]] || fail 'make install did not complete'
run restore --allow-bundle-modification > "$TEMP/make-install-restore"
snapshot > "$TEMP/after-make-install"
cmp "$TEMP/baseline" "$TEMP/after-make-install" || fail 'make install/restore changed originals'
[[ -z "$(find "$MAKE_FIXTURE/build" -maxdepth 1 -type d -name 'install.*' -print)" ]] || fail 'make install left temporary files'

bash "$ROOT/scripts/release.sh" --help >/dev/null
bash "$ROOT/tools/build-d9mtmetal.sh" --help >/dev/null
expect_failure bash "$ROOT/scripts/release.sh" --version
expect_failure bash "$ROOT/scripts/release.sh" --version ../unsafe
# Exercise release orchestration in an isolated source tree with mock builders.
FIXTURE="$TEMP/source checkout"
mkdir -p "$FIXTURE/scripts" "$FIXTURE/tools" "$FIXTURE/prebuilt" "$TEMP/release-bin"
cp "$ROOT/scripts/release.sh" "$ROOT/scripts/setup-crossover.sh" "$FIXTURE/scripts/"
mkdir -p "$FIXTURE/vendor/spirv-cross"
cp "$ROOT/vendor/spirv-cross/LICENSE" "$FIXTURE/vendor/spirv-cross/LICENSE"
mkdir -p "$FIXTURE/vendor/dxvk/include"
cp "$ROOT/vendor/dxvk/DXVK-VERSION" "$FIXTURE/vendor/dxvk/DXVK-VERSION"
for path in spirv/LICENSE vulkan/LICENSES native/directx/COPYING.MinGW-w64.txt; do
  mkdir -p "$FIXTURE/vendor/dxvk/include/$(dirname "$path")"
  cp -R "$ROOT/vendor/dxvk/include/$path" "$FIXTURE/vendor/dxvk/include/$path"
done
ln -s "$SELF" "$FIXTURE/tools/build-d9mtmetal.sh"
ln -s "$SELF" "$FIXTURE/scripts/build-dxvkfe.sh"
for tool in sw_vers git gh clang python3 glslang \
  i686-w64-mingw32-gcc i686-w64-mingw32-g++ i686-w64-mingw32-dlltool \
  x86_64-w64-mingw32-gcc x86_64-w64-mingw32-dlltool; do
  ln -s "$SELF" "$TEMP/release-bin/$tool"
done
for name in winemetal32.dll winemetal.dll winemetal.so libwinemetal.a; do
  printf '%064dWine builtin DLL\0dependency %s\n' 0 "$name" > "$FIXTURE/prebuilt/$name"
done
printf 'fixture DXMT license\n' > "$FIXTURE/prebuilt/DXMT.LICENSE"
printf 'v0.80\n' > "$FIXTURE/prebuilt/dxmt-version"
export PATH="$TEMP/release-bin:$PATH" FAKE_GH_LOG="$TEMP/gh.log"
bash "$FIXTURE/scripts/release.sh" > "$TEMP/release-build"
if grep -q 'release create' "$FAKE_GH_LOG"; then fail 'local build published a release'; fi
ARCHIVE="$FIXTURE/build/releases/d9mt-v0.1.0-macos-apple-silicon.tar.gz"
[[ -s "$ARCHIVE" ]] || fail 'missing release archive'
(cd "$(dirname "$ARCHIVE")" && shasum -a 256 -c "$(basename "$ARCHIVE").sha256") > "$TEMP/archive-check"
mkdir "$TEMP/unpacked"
tar -xzf "$ARCHIVE" -C "$TEMP/unpacked"
UNPACKED="$TEMP/unpacked/d9mt-v0.1.0-macos-apple-silicon"
(cd "$UNPACKED" && shasum -a 256 -c SHA256SUMS) > "$TEMP/package-check"
[[ -s "$UNPACKED/runtime/d9mtmetal64.dll" && -s "$UNPACKED/setup-crossover.sh" ]] || fail 'incomplete runtime package'
grep -qx 'dxmt_version=v0.80' "$UNPACKED/build-info" || fail 'local DXMT version was not recorded'
# Without a tag, local builds use the commit and publication refuses to invent a tag.
export FAKE_NO_TAG=1
bash "$FIXTURE/scripts/release.sh" --output-dir "$TEMP/untagged" > "$TEMP/untagged-build"
[[ -s "$TEMP/untagged/d9mt-0000001-macos-apple-silicon.tar.gz" ]] || fail 'commit version fallback failed'
expect_failure bash "$FIXTURE/scripts/release.sh" --publish --output-dir "$TEMP/untagged-publish"
unset FAKE_NO_TAG
export FAKE_MISSING_METAL=1
expect_failure bash "$FIXTURE/scripts/release.sh" --output-dir "$TEMP/missing-metal"
[[ ! -e "$TEMP/missing-metal" ]] || fail 'missing Metal toolchain reached the build stage'
unset FAKE_MISSING_METAL
log_hash="$(shasum -a 256 "$FAKE_GH_LOG")"
export FAKE_DIRTY=1
expect_failure bash "$FIXTURE/scripts/release.sh" --publish --output-dir "$TEMP/dirty"
[[ "$(shasum -a 256 "$FAKE_GH_LOG")" == "$log_hash" ]] || fail 'dirty checkout contacted GitHub'
unset FAKE_DIRTY
export FAKE_REMOTE_NUMBER=2
expect_failure bash "$FIXTURE/scripts/release.sh" --publish --output-dir "$TEMP/wrong-tag"
unset FAKE_REMOTE_NUMBER
bash "$FIXTURE/scripts/release.sh" --publish --draft --output-dir "$TEMP/published" > "$TEMP/publish"
grep -q 'release create' "$FAKE_GH_LOG" || fail 'explicit publication did not create a release'
grep -q -- '--verify-tag' "$FAKE_GH_LOG" || fail 'publication omitted tag verification'
grep -q -- '--draft' "$FAKE_GH_LOG" || fail 'publication omitted draft flag'
# Download uses only release assets; checksum failure must leave the local cache intact.
FAKE_DOWNLOAD_SOURCE="$(dirname "$ARCHIVE")"
export FAKE_DOWNLOAD_SOURCE
bash "$ROOT/scripts/download-release.sh" --output-dir "$TEMP/download" > "$TEMP/download-log"
DOWNLOADED="$TEMP/download/$(basename "$ARCHIVE")"
cmp "$ARCHIVE" "$DOWNLOADED" || fail 'downloaded release differs from the published asset'
(cd "$TEMP/download" && shasum -a 256 -c "$(basename "$ARCHIVE").sha256") > "$TEMP/download-check"
before_download="$(shasum -a 256 "$DOWNLOADED")"
export FAKE_CORRUPT_DOWNLOAD=1
expect_failure bash "$ROOT/scripts/download-release.sh" --version v0.1.0 --output-dir "$TEMP/download"
[[ "$(shasum -a 256 "$DOWNLOADED")" == "$before_download" ]] || fail 'corrupt download overwrote the local package'
unset FAKE_CORRUPT_DOWNLOAD
printf '%s\n' 'PASS: CrossOver install/dry-run/restore/rollback, release packaging/publication guards and verified downloads (mocked)'
