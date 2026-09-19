#!/usr/bin/env bash
# =============================================================================
#  vendor-import.sh — import offline artifacts dropped into vendor/
# =============================================================================
#  Detects: Ghidra, Android build-tools, cmdline-tools, platform (android.jar),
#  NDK, frida-server, and standalone jars (apktool / jadx / apksigner / d8 / r8).
#  Handles split files (split -b, 7z -v, HJSplit) and optional SHA256SUMS.txt.
#
#  Usage:
#      bash toolchain/vendor-import.sh [--list] [--force]
#
#  Env: TOOLS_DIR (default /opt/tools), VENDOR_DIR (default <repo>/vendor)
# =============================================================================
set -euo pipefail

TOOLS_DIR="${TOOLS_DIR:-/opt/tools}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${VENDOR_DIR:-$REPO_DIR/vendor}"
STAGE="$TOOLS_DIR/cache/vendor"
LIST_ONLY=0
FORCE=0
for a in "$@"; do
  case "$a" in
    --list) LIST_ONLY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
  esac
done

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!\033[0m %s\n' "$*"; }
bad()  { printf '   \033[1;31m✘\033[0m %s\n' "$*"; }

mkdir -p "$TOOLS_DIR/bin" "$STAGE"
mkdir -p "$TOOLS_DIR"/{apktool,jadx,platform-tools,build-tools,android-platform,cmdline-tools,ndk,frida,keys,work}
JDK="$TOOLS_DIR/jdk17/jre"
JRE21="$TOOLS_DIR/jre21"
[ -x "$JDK/bin/java" ] || warn "JDK 17 not found in $TOOLS_DIR — run toolchain/install.sh first"
[ -x "$JRE21/bin/java" ] || warn "JRE 21 not found — Ghidra needs Java 21+"

if [ ! -d "$VENDOR_DIR" ]; then bad "no vendor dir at $VENDOR_DIR"; exit 1; fi

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

check_sums() { # $1 = joined file, $2 = original name
  local sums="$VENDOR_DIR/SHA256SUMS.txt" want got
  [ -f "$sums" ] || return 0
  want="$(grep -E "[[:space:]]\*?${2//./\\.}$" "$sums" 2>/dev/null | awk '{print $1}' | head -1)"
  [ -n "$want" ] || { warn "no checksum entry for $2 (skipping verify)"; return 0; }
  got="$(sha_of "$1")"
  if [ "$want" = "$got" ]; then ok "sha256 verified: $2"; else bad "sha256 MISMATCH for $2 (expected $want, got $got)"; return 1; fi
}

# Return the ordered list of parts for a base file, or the file itself.
parts_of() { # $1 = base name (as uploaded), echoes file paths
  local base="$VENDOR_DIR/$1" p
  if [ -f "$base" ]; then echo "$base"; return; fi
  # numeric suffixes: .001 .002  /  .zip.001  /  .part.001
  p=( $(ls -1 "$base".part.[0-9][0-9][0-9] "$base".[0-9][0-9][0-9] "$base".part.[0-9][0-9] "$base".[0-9][0-9] 2>/dev/null | sort -u) )
  if [ ${#p[@]} -gt 0 ]; then printf '%s\n' "${p[@]}"; return; fi
  # alpha suffixes: .aa .ab ... / .part.aa
  p=( $(ls -1 "$base".part.[a-z][a-z] "$base".[a-z][a-z] 2>/dev/null | sort -u) )
  if [ ${#p[@]} -gt 0 ]; then printf '%s\n' "${p[@]}"; return; fi
}

join_parts() { # $1 = base name -> echoes a single joined file path
  local base="$1" out="$STAGE/${1}.joined" files
  files="$(parts_of "$base")"
  [ -n "$files" ] || return 1
  local n; n=$(printf '%s\n' "$files" | grep -c . || true)
  if [ "$n" = 1 ] && [ "$(printf '%s' "$files")" = "$VENDOR_DIR/$base" ]; then echo "$files"; return 0; fi
  local -a arr=(); while IFS= read -r line; do [ -n "$line" ] && arr+=("$line"); done <<< "$files"
  cat "${arr[@]}" > "$out"
  ok "joined $n part(s) -> $(basename "$out") ($(du -h "$out" | cut -f1))" >&2
  printf '%s\n' "$out"
}

unzip_into() { # $1 zip, $2 dest, $3 strip components
  rm -rf "$2"; mkdir -p "$2"
  unzip -q -o "$1" -d "$2" || { unzip -q -o "$1" -d "$2" 2>/dev/null; }
  if [ "${3:-0}" != 0 ]; then
    local inner; inner="$(find "$2" -mindepth 1 -maxdepth 1 | head -1)"
    if [ -n "$inner" ] && [ -d "$inner" ]; then
      shopt -s dotglob; mv "$inner"/* "$2"/ 2>/dev/null || true; shopt -u dotglob; rmdir "$inner" 2>/dev/null || true
    fi
  fi
}

install_jar() { # $1 jar, $2 target path
  local v; v="$(basename "$1")"
  cp "$1" "$2"
  ok "installed jar -> $2 (from $v)"
}

# ---------------------------------------------------------------------------
say "scanning $VENDOR_DIR"
mapfile -t FILES < <(find "$VENDOR_DIR" -maxdepth 2 -type f \
    \( -iname "*.zip" -o -iname "*.tar.gz" -o -iname "*.tar.xz" -o -iname "*.tgz" \
       -o -iname "*.jar" -o -iname "*.xz" -o -iname "*.gz" -o -iname "*.part.*" \) \
    ! -name "README.md" | sort)
[ ${#FILES[@]} -gt 0 ] || { bad "nothing to import (vendor/ has no archives/jars)"; exit 1; }

# collapse split groups into their base names
declare -A BASES FILESET PARTSET
for f in "${FILES[@]}"; do FILESET["$(basename "$f")"]=1; done
for f in "${FILES[@]}"; do
  b="$(basename "$f")"
  case "$b" in
    *.part.[0-9][0-9][0-9]) BASES["${b%.part.[0-9][0-9][0-9]}"]=1; PARTSET["${b%.part.[0-9][0-9][0-9]}"]=1 ;;
    *.part.[a-z][a-z])      BASES["${b%.part.[a-z][a-z]}"]=1;      PARTSET["${b%.part.[a-z][a-z]}"]=1 ;;
    *.[0-9][0-9][0-9])      BASES["${b%.[0-9][0-9][0-9]}"]=1;      PARTSET["${b%.[0-9][0-9][0-9]}"]=1 ;;
    *.[a-z][a-z])           BASES["${b%.[a-z][a-z]}"]=1;           PARTSET["${b%.[a-z][a-z]}"]=1 ;;
  esac
done
for f in "${FILES[@]}"; do BASES["$(basename "$f")"]=1; done

FOUND=0
for base in $(printf '%s\n' "${!BASES[@]}" | sort); do
  # skip individual split parts (their group base handles them) and stray names
  case "$base" in
    *.part.[0-9][0-9][0-9]) continue ;;
    *.part.[a-z][a-z])      continue ;;
    *.[0-9][0-9][0-9])      [ -z "${FILESET[$base]:-}" ] && continue ;;
    *.[a-z][a-z])           [ -z "${FILESET[$base]:-}" ] && continue ;;
  esac
  [ -n "${FILESET[$base]:-}" ] || [ -n "${PARTSET[$base]:-}" ] || continue
  lname="$(echo "$base" | tr 'A-Z' 'a-z')"
  kind=""
  case "$lname" in
    ghidra*public*.zip|ghidra*.zip|ghidra*.tar.gz|ghidra*.tar.xz) kind=ghidra ;;
    build-tools*linux*.zip|build-tools_r*.zip)                     kind=buildtools ;;
    commandlinetools*.zip|cmdline-tools*.zip)                      kind=cmdtools ;;
    platform-[0-9]*.zip|platform_r*.zip|android-*-platform*.zip)   kind=platform ;;
    android-ndk*.zip)                                              kind=ndk ;;
    frida-server*.xz|frida-server*.gz)                             kind=frida ;;
    apktool*.jar)                                                  kind=apktool ;;
    jadx*-all.jar|jadx*[0-9].jar)                                  kind=jadx ;;
    apksigner*.jar)                                                kind=apksigner ;;
    d8.jar)                                                        kind=d8 ;;
    r8.jar)                                                        kind=r8 ;;
    system-images*.zip)                                            kind=sysimage ;;
    *) kind=unknown ;;
  esac
  [ "$kind" = unknown ] && { warn "unrecognised: $base (left untouched)"; continue; }
  # idempotency: skip big extractions that are already installed unless --force
  if [ "$FORCE" != 1 ]; then
    case "$kind" in
      ghidra)     [ -x "$TOOLS_DIR/ghidra/support/analyzeHeadless" ] && { warn "Ghidra already imported — skipping (--force to redo)"; continue; } ;;
      buildtools) [ -L "$TOOLS_DIR/build-tools/current" ]  && { warn "build-tools already imported — skipping (--force to redo)"; continue; } ;;
      cmdtools)   [ -L "$TOOLS_DIR/cmdline-tools/current" ] && { warn "cmdline-tools already imported — skipping (--force to redo)"; continue; } ;;
      platform)   [ -L "$TOOLS_DIR/android-platform/current" ] && { warn "platform already imported — skipping (--force to redo)"; continue; } ;;
      ndk)        [ -L "$TOOLS_DIR/ndk/current" ] && { warn "NDK already imported — skipping (--force to redo)"; continue; } ;;
    esac
  fi
  FOUND=$((FOUND+1))
  printf '\n\033[1m--- %s  [%s]\033[0m\n' "$base" "$kind"
  if [ "$LIST_ONLY" = 1 ]; then ok "would import as $kind"; continue; fi

  joined="$(join_parts "$base")" || { bad "cannot read $base"; continue; }
  check_sums "$joined" "$base" || continue

  if ! ( case "$kind" in
    ghidra)
      unzip_into "$joined" "$TOOLS_DIR/ghidra" 1
      if [ -x "$TOOLS_DIR/ghidra/support/analyzeHeadless" ]; then
        chmod +x "$TOOLS_DIR/ghidra/support/"* "$TOOLS_DIR/ghidra/ghidraRun" 2>/dev/null || true
        cat > "$TOOLS_DIR/bin/ghidra-headless" <<EOF
#!/usr/bin/env bash
# Ghidra analyzeHeadless (needs Java 21+)
export JAVA_HOME="\${GHIDRA_JAVA_HOME:-$TOOLS_DIR/jre21}"
export GHIDRA_INSTALL_DIR="$TOOLS_DIR/ghidra"
exec "$TOOLS_DIR/ghidra/support/analyzeHeadless" "\$@"
EOF
        chmod +x "$TOOLS_DIR/bin/ghidra-headless"
        ok "Ghidra installed -> $TOOLS_DIR/ghidra  (wrapper: ghidra-headless)"
        ( JAVA_HOME="$TOOLS_DIR/jre21" "$TOOLS_DIR/ghidra/support/analyzeHeadless" 2>&1 | head -3 ) \
          | sed 's/^/     /' || true
      else
        bad "ghidra/support/analyzeHeadless not found after extraction"
      fi ;;
    buildtools)
      vdir="$TOOLS_DIR/build-tools/$(date +%Y%m%d-%H%M%S)"
      unzip_into "$joined" "$vdir" 1
      if [ -x "$vdir/aapt2" ] || [ -f "$vdir/aapt2" ]; then
        chmod +x "$vdir"/{aapt,aapt2,zipalign,d8,r8,apksigner,dexdump,aidl,split-select,etc1tool} 2>/dev/null || true
        [ -x "$TOOLS_DIR/bin/zipalign" ] && cp -f "$TOOLS_DIR/bin/zipalign" "$TOOLS_DIR/bin/zipalign-py" 2>/dev/null || true
        ln -sfn "$vdir" "$TOOLS_DIR/build-tools/current"
        ok "build-tools -> $vdir (symlinked as build-tools/current)"
        for b in aapt aapt2 zipalign d8 r8 apksigner dexdump; do
          [ -e "$vdir/$b" ] && ok "  $b: $("$vdir/$b" --version 2>&1 | head -1 || true)"
        done
      else
        bad "extraction does not look like Android build-tools"
      fi ;;
    cmdtools)
      vdir="$TOOLS_DIR/cmdline-tools/$(date +%Y%m%d-%H%M%S)"
      unzip_into "$joined" "$vdir" 1
      chmod +x "$vdir"/bin/* 2>/dev/null || true
      ln -sfn "$vdir" "$TOOLS_DIR/cmdline-tools/current"
      ok "cmdline-tools -> $vdir (sdkmanager/avdmanager under bin/)" ;;
    platform)
      vdir="$TOOLS_DIR/android-platform/$(date +%Y%m%d-%H%M%S)"
      unzip_into "$joined" "$vdir" 1
      jar="$(find "$vdir" -maxdepth 2 -name android.jar | head -1)"
      if [ -n "$jar" ]; then
        ln -sfn "$(dirname "$jar")" "$TOOLS_DIR/android-platform/current"
        ok "android.jar -> $jar"
      else bad "no android.jar inside zip"; fi ;;
    ndk)
      vdir="$TOOLS_DIR/ndk/$(date +%Y%m%d-%H%M%S)"
      unzip_into "$joined" "$vdir" 1
      ln -sfn "$vdir" "$TOOLS_DIR/ndk/current"
      ok "NDK -> $vdir" ;;
    frida)
      mkdir -p "$TOOLS_DIR/frida"
      case "$lname" in *.xz) xz -dk -c "$joined" > "$TOOLS_DIR/frida/$(basename "${base%.xz}")" ;;
                    *.gz) gzip -dk -c "$joined" > "$TOOLS_DIR/frida/$(basename "${base%.gz}")" ;; esac
      ok "frida-server -> $TOOLS_DIR/frida/" ;;
    apktool)   cp -f "$joined" "$TOOLS_DIR/apktool/apktool.jar"; ok "apktool $(java -jar "$TOOLS_DIR/apktool/apktool.jar" --version 2>/dev/null)" ;;
    jadx)      install_jar "$joined" "$TOOLS_DIR/jadx/jadx-all.jar" && ok "jadx CLI switch: wrapper will now use jadx-all.jar" ;;
    apksigner) install_jar "$joined" "$TOOLS_DIR/apktool/apksigner.jar" && ok "apksigner $(java -jar "$TOOLS_DIR/apktool/apksigner.jar" --version 2>/dev/null)" ;;
    d8)        install_jar "$joined" "$TOOLS_DIR/jadx/d8.jar" ;;
    r8)        install_jar "$joined" "$TOOLS_DIR/jadx/r8.jar" ;;
    sysimage)  warn "system image stored but unusable: no /dev/kvm in this sandbox" ;;
  esac ); then
    bad "import failed for $base (continuing with the next artifact)"
  fi
done

# d8/r8 wrapper if jars were provided
if [ -f "$TOOLS_DIR/jadx/d8.jar" ] || [ -f "$TOOLS_DIR/jadx/r8.jar" ]; then
  cat > "$TOOLS_DIR/bin/d8" <<EOF
#!/usr/bin/env bash
# D8 dexer (from vendor/d8.jar); usage: d8 --output <dir> <classes...>
exec "\${JAVA_HOME:-$JDK}/bin/java" -cp "$TOOLS_DIR/jadx/d8.jar" com.android.tools.r8.D8 "\$@"
EOF
  chmod +x "$TOOLS_DIR/bin/d8"
  ok "wrapper installed: d8"
fi

say "summary"
if [ "$FOUND" = 0 ]; then bad "no importable artifacts found"; exit 1; fi
if [ "$LIST_ONLY" = 1 ]; then ok "$FOUND artifact group(s) detected — run without --list to import"; else
  ok "$FOUND artifact group(s) processed"
  echo "   Next: source toolchain/env.sh  &&  bash toolchain/verify.sh"
fi
