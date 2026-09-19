#!/usr/bin/env bash
# =============================================================================
#  fetch-offline.sh — RUN THIS ON YOUR OWN PC (normal internet), not in the
#  sandbox. It downloads the artifacts the sandbox cannot reach, splits anything
#  over 95 MB (GitHub's per-file limit is 100 MB) and writes SHA256SUMS.txt.
#
#  Usage:
#      bash vendor/fetch-offline.sh --all          # everything (≈1.5 GB)
#      bash vendor/fetch-offline.sh --ghidra       # Ghidra only  (highest value)
#      bash vendor/fetch-offline.sh --buildtools   # Android build-tools (d8/r8/zipalign)
#      bash vendor/fetch-offline.sh --platform --cmdtools
#      bash vendor/fetch-offline.sh --ndk          # optional, ~700 MB
#
#  Then commit and push:
#      git add vendor && git commit -m "vendor: offline artifacts" && git push
# =============================================================================
set -euo pipefail

OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="$OUT/.download-cache"
SPLIT_SIZE="${SPLIT_SIZE:-90m}"
mkdir -p "$CACHE"

DO_GHIDRA=0; DO_BUILDTOOLS=0; DO_PLATFORM=0; DO_CMDTOOLS=0; DO_NDK=0
for a in "$@"; do
  case "$a" in
    --all)        DO_GHIDRA=1; DO_BUILDTOOLS=1; DO_PLATFORM=1; DO_CMDTOOLS=1; DO_NDK=1 ;;
    --ghidra)     DO_GHIDRA=1 ;;
    --buildtools) DO_BUILDTOOLS=1 ;;
    --platform)   DO_PLATFORM=1 ;;
    --cmdtools)   DO_CMDTOOLS=1 ;;
    --ndk)        DO_NDK=1 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
[ $((DO_GHIDRA+DO_BUILDTOOLS+DO_PLATFORM+DO_CMDTOOLS+DO_NDK)) -gt 0 ] || { sed -n '2,20p' "$0"; exit 2; }

have() { command -v "$1" >/dev/null 2>&1; }
have curl || { echo "curl is required"; exit 1; }

# Versions are pinned; bump if you prefer newer.
BUILD_TOOLS_URL="https://dl.google.com/android/repository/build-tools_r35-linux.zip"
PLATFORM_URL="https://dl.google.com/android/repository/platform-35_r02.zip"
CMDTOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip"
NDK_URL="https://dl.google.com/android/repository/android-ndk-r27c-linux.zip"

fetch() { # url, output name
  local url="$1" name="$2"
  if [ -f "$OUT/$name" ] || ls "$OUT/$name".part.* >/dev/null 2>&1; then
    echo "  = already present: $name"; return 0
  fi
  echo "  ↓ $name"
  curl -L --fail --retry 3 -o "$CACHE/$name" "$url" || { echo "  ! download failed: $url"; return 1; }
  publish "$CACHE/$name" "$name"
}

publish() { # file, final name  -> splits if > 95 MB, writes SHA256SUMS.txt
  local src="$1" name="$2" size
  size=$(wc -c < "$src")
  if [ "$size" -gt $((95*1024*1024)) ]; then
    echo "  ✂ splitting into ${SPLIT_SIZE} parts"
    split -b "$SPLIT_SIZE" "$src" "$OUT/$name.part."
    sha256sum "$src" | sed "s|$CACHE/|  |" >> "$OUT/SHA256SUMS.txt"
  else
    cp "$src" "$OUT/$name"
    ( cd "$OUT" && sha256sum "$name" >> SHA256SUMS.txt )
  fi
}

echo "== target: $OUT"

if [ "$DO_GHIDRA" = 1 ]; then
  echo "== Ghidra (latest public release)"
  url=""
  if have python3; then
    url=$(curl -sL https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest \
          | python3 -c "import sys,json;d=json.load(sys.stdin);print(next((a['browser_download_url'] for a in d.get('assets',[]) if a['name'].endswith('_PUBLIC.zip')),''))" 2>/dev/null || true)
  fi
  [ -n "$url" ] || url="https://github.com/NationalSecurityAgency/ghidra/releases/latest"
  fetch "$url" "$(basename "$url")" || echo "  → open $url manually and save the _PUBLIC.zip into vendor/"
fi

[ "$DO_BUILDTOOLS" = 1 ] && { echo "== Android build-tools 35"; fetch "$BUILD_TOOLS_URL" "build-tools_r35-linux.zip"; }
[ "$DO_PLATFORM"   = 1 ] && { echo "== Android platform 35 (android.jar)"; fetch "$PLATFORM_URL" "platform-35_r02.zip"; }
[ "$DO_CMDTOOLS"   = 1 ] && { echo "== Android cmdline-tools"; fetch "$CMDTOOLS_URL" "$(basename "$CMDTOOLS_URL")"; }
[ "$DO_NDK"        = 1 ] && { echo "== Android NDK r27c (~700 MB)"; fetch "$NDK_URL" "android-ndk-r27c-linux.zip"; }

# de-duplicate checksum file
[ -f "$OUT/SHA256SUMS.txt" ] && sort -u "$OUT/SHA256SUMS.txt" -o "$OUT/SHA256SUMS.txt"

echo
echo "== vendor/ now contains:"
ls -lh "$OUT" | grep -vE "^total|\.download-cache|README|fetch-offline|SHA256SUMS" | awk '{printf "   %-10s %s\n", $5, $9}'
echo
echo "== next steps"
echo "   git add vendor && git commit -m 'vendor: offline artifacts' && git push"
echo "   (do NOT use git-lfs; the .download-cache folder is ignored by git)"
