#!/usr/bin/env bash
# ============================================================
#  Android RE / APK Patching Toolchain — one-shot installer
#  Repo : kayhuyabhai009-dev/F2
#  Usage: bash tools/setup-toolchain.sh
# ============================================================
#  Kya install hota hai:
#    - Temurin JDK 25        (PyPI: jdk4py  — bundled JDK wheel)
#    - jadx 1.x CLI          (npm: @mishguru/jadx-node tarball)
#    - apktool 3.0.3         (repo root ka apktool_3.0.3.jar)
#    - Android build-tools   (repo ka build-tools_r35_linux.zip -> aapt2/apksigner/zipalign/d8)
#    - Android cmdline-tools (repo ke 5 split parts -> reassemble)
#    - baksmali/smali        (jadx ke bundled dexlib2/smali jars se)
#    - debug.keystore        (APK signing ke liye, keytool se)
#
#  Note: release-assets.githubusercontent.com block hai is sandbox me,
#        isliye JDK/jadx GitHub releases ki jagah PyPI + npm se aate hain.
#        Baaki sab kuch repo ke andar hi hai.
# ============================================================
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${RE_TOOLS:-/home/user/tools}"
PIP="${PIP:-python3 -m pip}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '   \033[1;32mok\033[0m  %s\n' "$*"; }
warn() { printf '   \033[1;33m!!\033[0m  %s\n' "$*"; }

mkdir -p "$TOOLS"/{bin,keystores,android}

# java ko PATH me rakho — jadx/apkanalyzer jaise wrapper scripts isi par depend karte hain
export JAVA_HOME="${JAVA_HOME:-$TOOLS/jdk}"
export PATH="$JAVA_HOME/bin:$TOOLS/bin:$PATH"

# ---------------------------------------------------------------- 1. JDK
say "1/7  JDK (PyPI jdk4py — bundled Temurin build)"
if [ ! -x "$TOOLS/jdk/bin/java" ]; then
  $PIP install --user --break-system-packages -q jdk4py || { warn "pip install jdk4py failed"; exit 1; }
  JH="$($PIP show jdk4py >/dev/null 2>&1; python3 -c 'import jdk4py;print(jdk4py.JAVA_HOME)')"
  cp -a "$JH" "$TOOLS/jdk"
fi
ok "$("$TOOLS/jdk/bin/java" -version 2>&1 | head -1)"

# ---------------------------------------------------------------- 2. jadx
say "2/7  jadx CLI (npm tarball — self contained, jars bundled)"
if [ ! -x "$TOOLS/jadx/bin/jadx" ]; then
  TMP=$(mktemp -d)
  VER=$(curl -sS https://registry.npmjs.org/@mishguru%2fjadx-node | \
        python3 -c 'import sys,json;print(json.load(sys.stdin)["dist-tags"]["latest"])')
  curl -sSL -o "$TMP/jadx.tgz" \
    "https://registry.npmjs.org/@mishguru/jadx-node/-/jadx-node-${VER}.tgz"
  tar xzf "$TMP/jadx.tgz" -C "$TMP"
  cp -a "$TMP/package/resources/jadx-"* "$TOOLS/jadx"
  rm -rf "$TMP"
fi
ok "jadx $("$TOOLS/jadx/bin/jadx" --version 2>&1 | tail -1)"

# ---------------------------------------------------------------- 3. apktool
say "3/7  apktool"
cp -f "$REPO_ROOT/apktool_3.0.3.jar" "$TOOLS/apktool.jar"
ok "apktool 3.0.3"

# ---------------------------------------------------------------- 4. build-tools
say "4/7  Android build-tools r35 (aapt2 / apksigner / zipalign / d8)"
BT="$TOOLS/android/build-tools"
if [ ! -x "$BT/aapt2" ]; then
  TMP=$(mktemp -d)
  unzip -q -o "$REPO_ROOT/build-tools_r35_linux.zip" -d "$TMP"
  SRC=$(find "$TMP" -maxdepth 2 -name aapt2 -printf '%h\n' | head -1)
  mkdir -p "$BT"
  for f in aapt aapt2 apksigner zipalign d8 dexdump aidl split-select \
           core-lambda-stubs.jar source.properties NOTICE.txt lib lib64; do
    [ -e "$SRC/$f" ] && cp -a "$SRC/$f" "$BT/"
  done
  # LLVM/clang bade hain aur APK patching me use nahi hote
  rm -f "$BT/lib64/libLLVM_android.so" "$BT/lib64/libclang_android.so"
  rm -rf "$TMP"
fi
ok "aapt2 $("$BT/aapt2" version 2>&1)"

# ---------------------------------------------------------------- 5. cmdline-tools
say "5/7  Android commandline-tools (optional)"
# sdkmanager ko network (dl.google.com) chahiye jo yahan blocked hai — isliye
# default me sirf apkanalyzer nikalte hain. Poora set chahiye to:
#   WITH_CMDLINE_TOOLS=1 bash tools/setup-toolchain.sh
if [ "${WITH_CMDLINE_TOOLS:-0}" = "1" ] || [ ! -x "$TOOLS/android/cmdline-tools/bin/apkanalyzer" ]; then
  if compgen -G "$REPO_ROOT/commandlinetools-linux-15859902_latest.zip.a?" >/dev/null; then
    TMP=$(mktemp -d)
    cat "$REPO_ROOT"/commandlinetools-linux-15859902_latest.zip.a? > "$TMP/ct.zip"
    unzip -q -o "$TMP/ct.zip" -d "$TMP"
    SRC=$(find "$TMP" -maxdepth 2 -name apkanalyzer -printf '%h\n' | head -1)
    if [ -n "$SRC" ]; then
      mkdir -p "$TOOLS/android"
      rm -rf "$TOOLS/android/cmdline-tools"
      cp -a "$(dirname "$SRC")" "$TOOLS/android/cmdline-tools"
    fi
    rm -rf "$TMP"
  fi
fi
[ -x "$TOOLS/android/cmdline-tools/bin/apkanalyzer" ] \
  && ok "apkanalyzer available" || warn "apkanalyzer skip (optional)"

# ---------------------------------------------------------------- 6. wrappers
say "6/7  wrappers + env.sh"
for t in apktool jadx aapt aapt2 apksigner zipalign d8 dexdump baksmali smali; do
  cat > "$TOOLS/bin/$t" <<WRAP
#!/usr/bin/env bash
export JAVA_HOME="\${JAVA_HOME:-$TOOLS/jdk}"
export RE_TOOLS="$TOOLS"
export LD_LIBRARY_PATH="$TOOLS/android/build-tools/lib64:\${LD_LIBRARY_PATH:-}"
case "$t" in
  apktool)   exec "\$JAVA_HOME/bin/java" -Xmx3g -jar "$TOOLS/apktool.jar" "\$@" ;;
  jadx)      exec "$TOOLS/jadx/bin/jadx" "\$@" ;;
  apksigner) exec "\$JAVA_HOME/bin/java" -jar "$TOOLS/android/build-tools/lib/apksigner.jar" "\$@" ;;
  baksmali|smali)
             CP=\$(ls "$TOOLS"/jadx/lib/*.jar | tr '\n' ':')
             [ "$t" = baksmali ] && M=org.jf.baksmali.Main || M=org.jf.smali.Main
             exec "\$JAVA_HOME/bin/java" -cp "\$CP" \$M "\$@" ;;
  aapt|aapt2|zipalign|d8|dexdump)
             exec "$TOOLS/android/build-tools/$t" "\$@" ;;
esac
WRAP
  chmod +x "$TOOLS/bin/$t"
done

if [ -x "$TOOLS/android/cmdline-tools/bin/apkanalyzer" ]; then
  cat > "$TOOLS/bin/apkanalyzer" <<'WRAP'
#!/usr/bin/env bash
export JAVA_HOME="${JAVA_HOME:-/home/user/tools/jdk}"
exec /home/user/tools/android/cmdline-tools/bin/apkanalyzer "$@"
WRAP
  chmod +x "$TOOLS/bin/apkanalyzer"
fi

cat > "$TOOLS/env.sh" <<ENV
# source this:  source $TOOLS/env.sh
export RE_TOOLS="$TOOLS"
export JAVA_HOME="\$RE_TOOLS/jdk"
export ANDROID_HOME="\$RE_TOOLS/android"
export PATH="\$RE_TOOLS/bin:\$JAVA_HOME/bin:\$ANDROID_HOME/build-tools:\$PATH"
export APKTOOL_JAR="\$RE_TOOLS/apktool.jar"
export DEBUG_KEYSTORE="\$RE_TOOLS/keystores/debug.keystore"
ENV
chmod +x "$TOOLS/env.sh"
ok "wrappers: $(ls "$TOOLS/bin" | tr '\n' ' ')"

# ---------------------------------------------------------------- 7. keystore
say "7/7  debug keystore (APK signing)"
KS="$TOOLS/keystores/debug.keystore"
if [ ! -f "$KS" ]; then
  "$TOOLS/jdk/bin/keytool" -genkeypair -v -keystore "$KS" \
    -storepass android -keypass android -alias androiddebugkey \
    -keyalg RSA -keysize 2048 -validity 10950 \
    -dname "CN=Android Debug,O=Android,C=US" 2>&1 | tail -2
fi
ok "keystore: $KS  (pass: android / alias: androiddebugkey)"

say "DONE — toolchain ready at $TOOLS"
echo "   use karo:  source $TOOLS/env.sh"
