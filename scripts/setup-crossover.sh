#!/usr/bin/env bash
# Install an extracted release. Bundle changes are shared across bottles and
# require explicit consent. One managed installation per CrossOver bundle.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ACTION="${1:-}"
CX_APP="${CX_APP:-/Applications/CrossOver.app}"
CX_WINE="" BOTTLE_NAME="" BOTTLE_DIR="" GAME_EXE=""
PACKAGE_DIR="$SCRIPT_DIR" ALLOW_BUNDLE=0 DRY_RUN=0
STATE_CREATED=0 STATE=""
KEY='HKCU\Software\Wine\DllOverrides'

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
  printf '%s\n' \
    'Usage: bash setup-crossover.sh ACTION --bottle NAME --game-exe /path/Game.exe [OPTIONS]' \
    'Actions: doctor, install, launch, restore' \
    'Options:' \
    '  --crossover PATH              CrossOver.app (default /Applications/CrossOver.app)' \
    '  --wine PATH                   Explicit CrossOver Wine wrapper, if not in bin/wine' \
    '  --bottle-dir PATH             Custom bottle directory' \
    '  --package-dir PATH            Extracted release directory (install only)' \
    '  --allow-bundle-modification   Consent to shared bundle changes (install/restore)' \
    '  --dry-run                     Print the plan without writing or running Wine' \
    '' \
    'Close CrossOver and all bottle applications before install/restore.' \
    'Changing winemetal inside CrossOver.app may affect OTHER bottles and games.' \
    'Requires macOS 15 or newer. Only 32-bit games are supported. No game mods or DRM changes.' \
    'Restore before upgrading CrossOver or managing a different game/bottle.' \
    'This script neither downloads releases nor builds binaries.'
}
value() { [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 requires a value"; }
case "$ACTION" in
  -h|--help|'') usage; exit 0 ;;
  doctor|install|launch|restore) shift ;;
  *) die "Unknown action: $ACTION" ;;
esac
while [[ $# -gt 0 ]]; do
  case "$1" in
    --crossover) value "$@"; CX_APP="$2"; shift 2 ;;
    --wine) value "$@"; CX_WINE="$2"; shift 2 ;;
    --bottle) value "$@"; BOTTLE_NAME="$2"; shift 2 ;;
    --bottle-dir) value "$@"; BOTTLE_DIR="$2"; shift 2 ;;
    --game-exe) value "$@"; GAME_EXE="$2"; shift 2 ;;
    --package-dir) value "$@"; PACKAGE_DIR="$2"; shift 2 ;;
    --allow-bundle-modification) ALLOW_BUNDLE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || die 'Apple Silicon macOS is required.'
if [[ "$ACTION" != restore ]]; then
  [[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 15 ]] || die 'This runtime requires macOS 15 or newer.'
fi
[[ -n "$BOTTLE_NAME" ]] || die 'Provide --bottle NAME.'
[[ "$BOTTLE_NAME" != */* && "$BOTTLE_NAME" != . && "$BOTTLE_NAME" != .. ]] || die 'Invalid bottle name.'
[[ -d "$CX_APP/Contents/SharedSupport/CrossOver" ]] || die "CrossOver runtime not found in $CX_APP."
CX="$(cd "$CX_APP/Contents/SharedSupport/CrossOver" && pwd)"
CX_WINE="${CX_WINE:-$CX/bin/wine}"
[[ -x "$CX_WINE" ]] || die "Wine wrapper not found: $CX_WINE. Locate your CrossOver runtime and use --wine PATH."
CX_WINE="$(cd "$(dirname "$CX_WINE")" && pwd)/$(basename "$CX_WINE")"
BOTTLE_DIR="${BOTTLE_DIR:-$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE_NAME}"
[[ -d "$BOTTLE_DIR/drive_c/windows/syswow64" && -d "$BOTTLE_DIR/drive_c/windows/system32" ]] || \
  die "A 64-bit bottle with WoW64 is required: $BOTTLE_DIR"
BOTTLE_DIR="$(cd "$BOTTLE_DIR" && pwd)"
[[ "$(basename "$BOTTLE_DIR")" == "$BOTTLE_NAME" ]] || die '--bottle must match the bottle directory name.'
[[ -f "$GAME_EXE" ]] || die 'Provide --game-exe pointing to an existing Windows executable.'
GAME_DIR="$(cd "$(dirname "$GAME_EXE")" && pwd)"
GAME_NAME="$(basename "$GAME_EXE")"
GAME_EXE="$GAME_DIR/$GAME_NAME"
[[ "$GAME_NAME" != *\\* && "$GAME_NAME" != *$'\n'* && "$GAME_DIR" != *$'\n'* ]] || die 'Unsupported game path.'
STATE="$CX/lib/.d9mt-backup"
APP_KEY="HKCU\\Software\\Wine\\AppDefaults\\$GAME_NAME\\DllOverrides"
# CX_BOTTLE_PATH also handles bottles outside the default CrossOver directory.
wine_cmd() { env CX_BOTTLE_PATH="$(dirname "$BOTTLE_DIR")" "$CX_WINE" --bottle "$BOTTLE_NAME" "$@"; }
hash() { shasum -a 256 "$1" | awk '{print $1}'; }

check_owner() {
  [[ -f "$STATE/bottle" && -f "$STATE/game" ]] || die "Incomplete backup: $STATE. Inspect it before proceeding."
  [[ "$(< "$STATE/bottle")" == "$BOTTLE_DIR" && "$(< "$STATE/game")" == "$GAME_EXE" ]] || \
    die "This bundle already has a managed installation for another bottle/game. Restore that installation first."
}
check_package() {
  [[ -d "$PACKAGE_DIR" ]] || die "Missing extracted release: $PACKAGE_DIR"
  PACKAGE_DIR="$(cd "$PACKAGE_DIR" && pwd)"
  [[ -s "$PACKAGE_DIR/SHA256SUMS" && -s "$PACKAGE_DIR/build-info" ]] || die 'Package metadata/checksums are missing.'
  for name in d3d9.dll d9mtmetal32.dll d9mtmetal64.dll d9mtmetal.so winemetal32.dll winemetal.dll winemetal.so; do
    [[ -s "$PACKAGE_DIR/runtime/$name" ]] || die "Package is missing runtime/$name."
    expected="$(awk -v path="runtime/$name" '$2 == path {count++; result=$1} END {if (count == 1) print result}' "$PACKAGE_DIR/SHA256SUMS")"
    [[ "$expected" =~ ^[[:xdigit:]]{64}$ && "$(hash "$PACKAGE_DIR/runtime/$name")" == "$expected" ]] || \
      die "Checksum mismatch or missing checksum: runtime/$name"
  done
}

# Query only the values we own. Never export/import the entire bottle registry.
query_value() {
  local key="$1" name="$2" output
  CURRENT_PRESENT=0 CURRENT_VALUE=""
  if output="$(wine_cmd reg query "$key" /v "$name" 2>/dev/null)"; then
    [[ "$output" == *REG_SZ* ]] || die "Unsupported registry value type for $name in $key."
    CURRENT_PRESENT=1
    CURRENT_VALUE="$(printf '%s\n' "$output" | tr -d '\r' | awk '
      /REG_SZ/ {sub(/^.*REG_SZ[[:space:]]*/, ""); print; exit}
    ')"
  fi
}
queue_file() {
  local src="$1" dst="$2" item
  [[ -d "$(dirname "$dst")" && -w "$(dirname "$dst")" ]] || die "Missing or unwritable destination: $dst"
  [[ ! -L "$dst" && ( ! -e "$dst" || -f "$dst" ) ]] || die "Refusing non-regular destination: $dst"
  FILE_COUNT=$((FILE_COUNT + 1))
  item="$STATE/files/$(printf '%03d' "$FILE_COUNT")"
  mkdir "$item"
  printf '%s\n' "$dst" > "$item/path"
  printf '%s\n' "$src" > "$item/source"
  hash "$src" > "$item/installed-hash"
  if [[ -f "$dst" ]]; then
    cp -p "$dst" "$item/original"
  fi
}
queue_registry() {
  local index="$1" key="$2" name="$3" desired="$4" item
  item="$STATE/registry/$index"
  mkdir "$item"
  printf '%s\n' "$key" > "$item/key"
  printf '%s\n' "$name" > "$item/name"
  printf '%s\n' "$desired" > "$item/desired"
  query_value "$key" "$name"
  if [[ "$CURRENT_PRESENT" == 1 ]]; then
    printf '%s\n' "$CURRENT_VALUE" > "$item/original"
  fi
}

preflight_restore() {
  local item dst current original name key desired
  [[ -f "$STATE/prepared" ]] || die "Backup preparation was incomplete: $STATE. No install should have been applied."
  for item in "$STATE"/files/*; do
    dst="$(< "$item/path")"
    [[ ! -L "$dst" ]] || die "Refusing to restore over a symlink: $dst"
    if [[ -f "$dst" ]]; then
      current="$(hash "$dst")"
      original=""
      [[ ! -f "$item/original" ]] || original="$(hash "$item/original")"
      [[ "$current" == "$(< "$item/installed-hash")" || "$current" == "$original" ]] || \
        die "File changed after installation: $dst. Backup retained at $STATE; refusing to overwrite."
    elif [[ -e "$dst" ]]; then
      die "Destination is no longer a regular file: $dst"
    fi
  done
  wine_cmd reg query 'HKCU\Software\Wine' >/dev/null
  for item in "$STATE"/registry/*; do
    key="$(< "$item/key")" name="$(< "$item/name")" desired="$(< "$item/desired")"
    query_value "$key" "$name"
    if [[ "$CURRENT_PRESENT" == 1 && "$CURRENT_VALUE" != "$desired" ]]; then
      [[ -f "$item/original" && "$CURRENT_VALUE" == "$(< "$item/original")" ]] || \
        die "Registry override changed after installation: $name. Backup retained; refusing to overwrite."
    fi
  done
}
restore_state() {
  local item dst key name failed=0
  for item in "$STATE"/files/*; do
    dst="$(< "$item/path")"
    if [[ -f "$item/original" ]]; then
      cp -p "$item/original" "$dst" || failed=1
    else
      rm -f "$dst" || failed=1
    fi
  done
  for item in "$STATE"/registry/*; do
    key="$(< "$item/key")" name="$(< "$item/name")"
    if [[ -f "$item/original" ]]; then
      wine_cmd reg add "$key" /v "$name" /t REG_SZ /d "$(< "$item/original")" /f >/dev/null || failed=1
    else
      if wine_cmd reg query "$key" /v "$name" >/dev/null 2>&1; then
        wine_cmd reg delete "$key" /v "$name" /f >/dev/null || failed=1
      fi
    fi
  done
  [[ "$failed" == 0 ]] || { say "Restore failed. Backup retained: $STATE" >&2; return 1; }
  rm -rf "$STATE"
}
install_failed() {
  local status="$1"
  trap - ERR INT TERM EXIT
  if [[ "$STATE_CREATED" == 1 ]]; then
    if [[ -f "$STATE/prepared" ]]; then
      say 'Installation interrupted. Restoring original files and registry values...' >&2
      # Leave the backup available if the rollback itself fails.
      restore_state || true
    else
      rm -rf "$STATE"
    fi
  fi
  exit "$status"
}

if [[ "$ACTION" != restore ]]; then
  description="$(file -b "$GAME_EXE")"
  [[ "$description" == *'PE32 executable'* ]] || die "Only 32-bit PE games are supported ($description)."
fi
case "$ACTION" in
  doctor)
    say "CrossOver runtime: $CX"
    say "Wine wrapper: $CX_WINE"
    say "Bottle: $BOTTLE_DIR"
    say "32-bit game: $GAME_EXE"
    for arch in i386-windows x86_64-windows x86_64-unix; do
      [[ -d "$CX/lib/wine/$arch" ]] || die "Missing CrossOver architecture directory: lib/wine/$arch"
    done
    xcrun --sdk macosx metal --version >/dev/null 2>&1 || \
      die 'Metal compiler is unavailable. Run: xcodebuild -downloadComponent MetalToolchain'
    if [[ -d "$STATE" ]]; then
      check_owner
      say "Managed backup: $STATE"
    fi
    say 'Filesystem checks passed. This does not prove runtime compatibility.'
    say 'If the game renders black, disable in-game MSAA. Release builds do not produce d3d9fe.log.'
    ;;
  launch)
    [[ -f "$STATE/complete" ]] || die 'No completed managed installation; run install first.'
    check_owner
    if [[ "$DRY_RUN" == 1 ]]; then
      printf 'Would launch: %q --bottle %q --dll %q start /unix %q\n' \
        "$CX_WINE" "$BOTTLE_NAME" 'd3d9=n;winemetal=b;d9mtmetal=b' "$GAME_EXE"
      exit 0
    fi
    cd "$GAME_DIR"
    # The CrossOver wrapper may discard WINEDLLOVERRIDES from the environment.
    wine_cmd --dll 'd3d9=n;winemetal=b;d9mtmetal=b' start /unix "$GAME_EXE"
    ;;
  restore)
    [[ -d "$STATE" ]] || die 'No managed backup exists.'
    check_owner
    if [[ "$DRY_RUN" == 1 ]]; then
      say "Would restore files and registry values using $STATE (no Wine calls)."
      exit 0
    fi
    [[ "$ALLOW_BUNDLE" == 1 ]] || die 'Restoring shared bundle files requires --allow-bundle-modification.'
    preflight_restore
    restore_state
    say 'Original files and registry values restored.'
    ;;
  install)
    check_package
    if [[ -d "$STATE" ]]; then
      check_owner
      die 'A managed installation already exists. Restore it before reinstalling; the original backup is unchanged.'
    fi
    say 'WARNING: this updates shared winemetal files inside CrossOver.app and can affect other bottles.'
    say 'Close CrossOver and all running bottle applications before continuing.'
    if [[ "$DRY_RUN" == 1 ]]; then
      say "Would back up bundle/bottle/game files into $STATE."
      say "Would install runtime DLLs into $CX/lib/wine and existing lib/dxmt architecture directories."
      say "Would install the game driver at $GAME_DIR/d3d9.dll."
      say "Would set bottle builtins for winemetal/d9mtmetal and a per-game d3d9 override for $GAME_NAME."
      exit 0
    fi
    [[ "$ALLOW_BUNDLE" == 1 ]] || die 'Explicit consent required: --allow-bundle-modification.'
    [[ -w "$CX/lib" ]] || die 'CrossOver lib directory is not writable. Do not run this script with sudo.'
    xcrun --sdk macosx metal --version >/dev/null 2>&1 || \
      die 'Metal compiler is unavailable. Run: xcodebuild -downloadComponent MetalToolchain'
    # Confirm registry access before interpreting missing individual overrides.
    wine_cmd reg query 'HKCU\Software\Wine' >/dev/null
    mkdir "$STATE"
    STATE_CREATED=1
    trap 'install_failed $?' EXIT
    trap 'install_failed 130' INT
    trap 'install_failed 143' TERM
    mkdir "$STATE/files" "$STATE/registry"
    printf '%s\n' "$BOTTLE_DIR" > "$STATE/bottle"
    printf '%s\n' "$GAME_EXE" > "$STATE/game"
    FILE_COUNT=0
    for tree in wine dxmt; do
      if [[ "$tree" == dxmt && ! -d "$CX/lib/dxmt" ]]; then continue; fi
      for arch in i386-windows x86_64-windows x86_64-unix; do
        dest="$CX/lib/$tree/$arch"
        [[ -d "$dest" ]] || die "Missing architecture directory: $dest"
        case "$arch" in
          i386-windows) bridge=winemetal32.dll; companion=d9mtmetal32.dll ;;
          x86_64-windows) bridge=winemetal.dll; companion=d9mtmetal64.dll ;;
          x86_64-unix) bridge=winemetal.so; companion=d9mtmetal.so ;;
        esac
        if [[ "$arch" == x86_64-unix ]]; then
          queue_file "$PACKAGE_DIR/runtime/$bridge" "$dest/winemetal.so"
          queue_file "$PACKAGE_DIR/runtime/$companion" "$dest/d9mtmetal.so"
        else
          queue_file "$PACKAGE_DIR/runtime/$bridge" "$dest/winemetal.dll"
          queue_file "$PACKAGE_DIR/runtime/$companion" "$dest/d9mtmetal.dll"
          if [[ "$tree" == wine ]]; then
            queue_file "$PACKAGE_DIR/runtime/d9mtmetal.so" "$dest/d9mtmetal.so"
          fi
        fi
      done
    done
    for arch in syswow64 system32; do
      if [[ "$arch" == syswow64 ]]; then bridge=winemetal32.dll; companion=d9mtmetal32.dll
      else bridge=winemetal.dll; companion=d9mtmetal64.dll; fi
      queue_file "$PACKAGE_DIR/runtime/$bridge" "$BOTTLE_DIR/drive_c/windows/$arch/winemetal.dll"
      queue_file "$PACKAGE_DIR/runtime/$companion" "$BOTTLE_DIR/drive_c/windows/$arch/d9mtmetal.dll"
    done
    queue_file "$PACKAGE_DIR/runtime/d3d9.dll" "$GAME_DIR/d3d9.dll"
    queue_registry 1 "$KEY" winemetal builtin
    queue_registry 2 "$KEY" d9mtmetal builtin
    queue_registry 3 "$APP_KEY" d3d9 native
    # All originals are saved before the first managed file or override changes.
    touch "$STATE/prepared"
    for item in "$STATE"/files/*; do
      cp "$(< "$item/source")" "$(< "$item/path")"
    done
    for item in "$STATE"/registry/*; do
      wine_cmd reg add "$(< "$item/key")" /v "$(< "$item/name")" /t REG_SZ /d "$(< "$item/desired")" /f >/dev/null
    done
    cp "$PACKAGE_DIR/build-info" "$STATE/build-info"
    touch "$STATE/complete"
    STATE_CREATED=0
    trap - ERR INT TERM EXIT
    say "Installed. Original files and override values are backed up at $STATE."
    say 'Use launch to pass explicit DLL overrides through the CrossOver wrapper.'
    ;;
esac
