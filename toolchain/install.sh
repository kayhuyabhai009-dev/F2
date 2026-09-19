#!/usr/bin/env bash
# =============================================================================
#  F2 Android RE toolchain installer
# =============================================================================
#  Recreates the complete toolchain used for APK / native analysis.
#
#  Everything is fetched from the only hosts reachable in this sandbox:
#      github.com (git + API + source archives), pypi.org, registry.npmjs.org
#  No root is required for the toolchain itself (default prefix /opt/tools is
#  writable in the sandbox; override with TOOLS_DIR=/some/path).
#
#  Usage:
#      bash toolchain/install.sh                 # core toolchain (~5 min)
#      bash toolchain/install.sh --with-radare2  # + radare2 from source (~20 min)
#      bash toolchain/install.sh --with-node     # + Node helper packages
#      bash toolchain/install.sh --verify-only   # just print the status table
# =============================================================================
set -euo pipefail

TOOLS_DIR="${TOOLS_DIR:-/opt/tools}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WITH_R2=0
WITH_NODE=0
VERIFY_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --with-radare2) WITH_R2=1 ;;
    --with-node)    WITH_NODE=1 ;;
    --verify-only)  VERIFY_ONLY=1 ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '   \033[1;31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

if [ "$VERIFY_ONLY" = 1 ]; then exec bash "$REPO_DIR/toolchain/verify.sh"; fi

command -v python3 >/dev/null || die "python3 required"
command -v node    >/dev/null || warn "node/npm missing – skipping JS helpers"
command -v java    >/dev/null || warn "no system java – the bundled JDK below will be used"

mkdir -p "$TOOLS_DIR"/{bin,cache,keys,work,apktool,jadx,platform-tools}
cd "$TOOLS_DIR/cache"

# -----------------------------------------------------------------------------
say "1/10  JDK (javac, jar, keytool, jarsigner, javadoc, jshell)"
# The npm package `javajre-linux-64` is actually a complete JDK 17 distribution
# (~174 MB tarball). Temurin/Adoptium download hosts are blocked in this sandbox.
if [ ! -x "$TOOLS_DIR/jdk17/jre/bin/javac" ]; then
  npm pack javajre-linux-64 --silent >/dev/null
  rm -rf "$TOOLS_DIR/jdk17" && mkdir -p "$TOOLS_DIR/jdk17"
  tar xzf javajre-linux-64-*.tgz -C "$TOOLS_DIR/jdk17" --strip-components=1
  chmod +x "$TOOLS_DIR/jdk17/jre/bin/"*
fi
"$TOOLS_DIR/jdk17/jre/bin/javac" -version && ok "JDK 17 -> $TOOLS_DIR/jdk17/jre"

# -----------------------------------------------------------------------------
say "2/10  Extra JREs 21 / 25 (for tools that require a newer JVM)"
for spec in "21.0.8.2:jre21" "25.0.2.1:jre25"; do
  ver="${spec%%:*}"; dest="${spec##*:}"
  if [ ! -x "$TOOLS_DIR/$dest/bin/java" ]; then
    td="$(mktemp -d)"
    python3 -m venv "$td/venv" >/dev/null 2>&1
    "$td/venv/bin/pip" install -q "jdk4py==$ver" >/dev/null 2>&1 || warn "jdk4py $ver install failed"
    cp -r "$td/venv/lib/python"*/site-packages/jdk4py/java-runtime "$TOOLS_DIR/$dest" 2>/dev/null || true
    rm -rf "$td"
  fi
  if [ -x "$TOOLS_DIR/$dest/bin/java" ]; then
    ok "$("$TOOLS_DIR/$dest/bin/java" -version 2>&1 | head -1) -> $TOOLS_DIR/$dest"
  else
    warn "$dest unavailable"
  fi
done

# -----------------------------------------------------------------------------
say "3/10  APK jars: apktool, apksigner, jadx, dx"
# `@postar/apktool-node` bundles apktool.jar (2.9.3) + the real Android apksigner jar
if [ ! -f "$TOOLS_DIR/apktool/apktool.jar" ]; then
  npm pack @postar/apktool-node --silent >/dev/null
  tar xzf postar-apktool-node-*.tgz -C "$TOOLS_DIR/apktool" --strip-components=2 package/lib
fi
# `jadx-mcp` bundles a modern shaded jadx-core; `@mishguru/jadx-node` a jadx CLI
[ -f "$TOOLS_DIR/jadx/jadx-core-modern.jar" ] || { npm pack jadx-mcp --silent >/dev/null; tar xzf jadx-mcp-*.tgz -C "$TOOLS_DIR/jadx" --strip-components=2 package/jadx-mcp.jar 2>/dev/null || true; }
if [ ! -d "$TOOLS_DIR/jadx/jadx-1.1.0" ]; then
  npm pack @mishguru/jadx-node --silent >/dev/null
  tar xzf mishguru-jadx-node-*.tgz -C "$TOOLS_DIR/jadx" --strip-components=2 package/resources || true
fi
chmod +x "$TOOLS_DIR/jadx/jadx-1.1.0/bin/"* 2>/dev/null || true
# dx: legacy class -> dex converter (fallback where d8/r8 are not obtainable)
if [ -f "$TOOLS_DIR/jadx/jadx-1.1.0/lib/dx-1.16.jar" ]; then
  cp "$TOOLS_DIR/jadx/jadx-1.1.0/lib/dx-1.16.jar" "$TOOLS_DIR/jadx/" 2>/dev/null || true
fi

# jadx Java driver (compiled here -> also proves javac works)
mkdir -p "$TOOLS_DIR/jadx/wrapper"
cp "$REPO_DIR/toolchain/bin/JadxRunner.java" "$TOOLS_DIR/jadx/wrapper/"
( cd "$TOOLS_DIR/jadx/wrapper" && "$TOOLS_DIR/jdk17/jre/bin/javac" -nowarn -cp "$TOOLS_DIR/jadx/jadx-core-modern.jar" JadxRunner.java )
cp "$REPO_DIR/toolchain/bin/jadx" "$TOOLS_DIR/bin/jadx" && chmod +x "$TOOLS_DIR/bin/jadx"
ok "apktool $( (cd "$TOOLS_DIR" && java -jar apktool/apktool.jar --version) 2>/dev/null ) | apksigner present | jadx wrapper compiled"

# -----------------------------------------------------------------------------
say "4/10  aapt, aapt2, zipalign"
mkdir -p "$TOOLS_DIR/bin"
if [ ! -x "$TOOLS_DIR/bin/aapt" ]; then
  unzip -o -q -j "$TOOLS_DIR/apktool/apktool.jar" 'prebuilt/linux/aapt' -d "$TOOLS_DIR/bin" && chmod +x "$TOOLS_DIR/bin/aapt"
fi
if [ ! -x "$TOOLS_DIR/bin/aapt2" ]; then
  python3 -m pip download aapt2 --no-deps -q -d "$TOOLS_DIR/cache/aapt2"
  python3 - "$TOOLS_DIR" <<'PY'
import glob, sys, zipfile, os
whl = glob.glob(sys.argv[1] + '/cache/aapt2/*.whl')[0]
open(sys.argv[1] + '/bin/aapt2', 'wb').write(zipfile.ZipFile(whl).read('aapt2/bin/Linux/aapt2'))
os.chmod(sys.argv[1] + '/bin/aapt2', 0o755)
PY
fi
# zipalign: pure-Python reimplementation of AOSP tools/zipalign (shipped in repo)
install -m 755 "$REPO_DIR/toolchain/bin/zipalign" "$TOOLS_DIR/bin/zipalign"
ok "aapt $("$TOOLS_DIR/bin/aapt" version | head -1) | aapt2 ok | zipalign ok"

# -----------------------------------------------------------------------------
say "5/10  adb (platform-tools)"
if [ ! -x "$TOOLS_DIR/platform-tools/adb" ]; then
  python3 -m pip download adbutils --no-deps -q -d "$TOOLS_DIR/cache/adbutils"
  python3 - "$TOOLS_DIR" <<'PY'
import glob, sys, zipfile, os
whl = [w for w in glob.glob(sys.argv[1] + '/cache/adbutils/*.whl') if 'manylinux' in w or 'linux' in w][0]
open(sys.argv[1] + '/platform-tools/adb', 'wb').write(zipfile.ZipFile(whl).read('adbutils/binaries/adb'))
os.chmod(sys.argv[1] + '/platform-tools/adb', 0o755)
PY
fi
ok "$("$TOOLS_DIR/platform-tools/adb" version | head -1) (NOTE: no device/emulator available in sandbox)"

# -----------------------------------------------------------------------------
say "6/10  Python analysis stack (venv)"
[ -d "$TOOLS_DIR/venv" ] || python3 -m venv "$TOOLS_DIR/venv"
"$TOOLS_DIR/venv/bin/pip" install -q --upgrade pip wheel >/dev/null
"$TOOLS_DIR/venv/bin/pip" install -q \
  androguard apkutils pyaxmlparser apkid quark-engine adbutils frida objection \
  lief capstone pyelftools r2pipe unicorn keystone-engine pypcode pyghidra-lite \
  cryptography pycryptodome requests lxml asn1crypto colorlog pygments
"$TOOLS_DIR/venv/bin/pip" install -q angr || warn "angr install failed (optional)"
ok "python venv ready: $TOOLS_DIR/venv"

# -----------------------------------------------------------------------------
say "7/10  Node helper packages"
if [ "$WITH_NODE" = 1 ] && command -v npm >/dev/null; then
  mkdir -p "$TOOLS_DIR/npm" && cd "$TOOLS_DIR/npm"
  npm init -y >/dev/null 2>&1
  npm install --silent @mauricelam/ghidra-decompiler-wasm @devicefarmer/adbkit \
                        apk_sign_ts @chromeos/android-package-signer >/dev/null
  ok "node helpers -> $TOOLS_DIR/npm/node_modules"
else
  warn "skipped (use --with-node)"
fi

# -----------------------------------------------------------------------------
say "8/10  radare2"
if [ "$WITH_R2" = 1 ]; then
  if [ ! -x "$TOOLS_DIR/radare2/bin/r2" ]; then
    mkdir -p "$TOOLS_DIR/src" && cd "$TOOLS_DIR/src"
    TAG=6.2.2
    curl -sSL -o "r2-$TAG.tar.gz" "https://codeload.github.com/radareorg/radare2/tar.gz/refs/tags/$TAG"
    rm -rf r2build && mkdir r2build && tar xzf "r2-$TAG.tar.gz" -C r2build --strip-components=1
    ( cd r2build && ./configure --prefix="$TOOLS_DIR/radare2" >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null )
  fi
  echo "$TOOLS_DIR/radare2/lib" | sudo tee /etc/ld.so.conf.d/radare2.conf >/dev/null 2>&1 && sudo ldconfig 2>/dev/null || true
  LD_LIBRARY_PATH="$TOOLS_DIR/radare2/lib" "$TOOLS_DIR/radare2/bin/r2" -v | head -1
  ok "radare2 -> $TOOLS_DIR/radare2/bin (export LD_LIBRARY_PATH=$TOOLS_DIR/radare2/lib)"
else
  warn "skipped (use --with-radare2; needs gcc+make, ~20 min on 2 cores)"
fi

# -----------------------------------------------------------------------------
say "9/10  test signing key"
if [ ! -f "$TOOLS_DIR/keys/test.keystore" ]; then
  "$TOOLS_DIR/jdk17/jre/bin/keytool" -genkeypair -keystore "$TOOLS_DIR/keys/test.keystore" \
    -storetype PKCS12 -alias testkey -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass android -keypass android \
    -dname "CN=Test Key, OU=Dev, O=F2 Sandbox, L=Patna, ST=Bihar, C=IN" >/dev/null 2>&1
fi
ok "test keystore: $TOOLS_DIR/keys/test.keystore (storepass/keypass = android, alias = testkey)"

# -----------------------------------------------------------------------------
say "10/10 vendor/ artifacts (if any were uploaded)"
if [ -n "$(find "$REPO_DIR/vendor" -maxdepth 2 -type f \( -iname '*.zip' -o -iname '*.jar' -o -iname '*.xz' -o -iname '*.tar.*' -o -iname '*.part.*' \) 2>/dev/null | head -1)" ]; then
  bash "$REPO_DIR/toolchain/vendor-import.sh" || warn "vendor import reported problems"
else
  warn "nothing in vendor/ yet — see vendor/README.md for what to upload"
fi

# -----------------------------------------------------------------------------
say "done — status"
exec bash "$REPO_DIR/toolchain/verify.sh"
