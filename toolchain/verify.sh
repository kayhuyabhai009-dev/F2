#!/usr/bin/env bash
# Prints the status of every tool in the F2 Android RE toolchain.
#     bash toolchain/verify.sh
# Exit code: number of missing *required* tools (0 = all good).
TOOLS_DIR="${TOOLS_DIR:-/opt/tools}"
JDK="$TOOLS_DIR/jdk17/jre"
export PATH="$JDK/bin:$TOOLS_DIR/bin:$TOOLS_DIR/platform-tools:$TOOLS_DIR/radare2/bin:$TOOLS_DIR/venv/bin:$PATH"
export LD_LIBRARY_PATH="$TOOLS_DIR/radare2/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
V="$TOOLS_DIR/venv/bin/python"
miss=0

row() { # name, status(ok/miss/warn), detail
  case "$2" in
    ok)   sym=$'\033[1;32m✔\033[0m' ;;
    warn) sym=$'\033[1;33m~\033[0m' ;;
    *)    sym=$'\033[1;31m✘\033[0m'; miss=$((miss+1)) ;;
  esac
  printf '  %s %-34s %s\n' "$sym" "$1" "$3"
}
try() { # command -> first line of output
  out="$("$@" 2>&1 | head -1)"; [ -n "$out" ] && echo "$out" || echo "failed"
}
have() { command -v "$1" >/dev/null 2>&1; }

echo "=============================================================="
echo " F2 Android RE toolchain status   (TOOLS_DIR=$TOOLS_DIR)"
echo "=============================================================="
echo "Java / JDK"
[ -x "$JDK/bin/javac" ] && row "JDK 17 (javac/java/jar)" ok "$(try "$JDK/bin/javac" -version)" || row "JDK 17" miss "not installed"
have keytool  && row "keytool"        ok "$(try keytool -help | head -1)" || row "keytool" miss "n/a"
have jarsigner && row "jarsigner"     ok "present"                        || row "jarsigner" miss "n/a"
[ -x "$TOOLS_DIR/jre21/bin/java" ] && row "JRE 21 (jdk4py)" ok "$(try "$TOOLS_DIR/jre21/bin/java" -version)" || row "JRE 21" warn "optional"
[ -x "$TOOLS_DIR/jre25/bin/java" ] && row "JRE 25 (jdk4py)" ok "$(try "$TOOLS_DIR/jre25/bin/java" -version)" || row "JRE 25" warn "optional"

echo "APK inspection / decode / rebuild"
[ -f "$TOOLS_DIR/apktool/apktool.jar" ] && row "apktool" ok "v$(java -jar "$TOOLS_DIR/apktool/apktool.jar" --version 2>/dev/null)" || row "apktool" miss "missing"
[ -x "$TOOLS_DIR/bin/aapt" ]  && row "aapt"  ok "$(try "$TOOLS_DIR/bin/aapt" version)"  || row "aapt"  miss "missing"
[ -x "$TOOLS_DIR/bin/aapt2" ] && row "aapt2" ok "$(try "$TOOLS_DIR/bin/aapt2" version)" || row "aapt2" miss "missing"
[ -x "$TOOLS_DIR/bin/jadx" ]  && row "jadx (modern jadx-core driver)" ok "$([ -f "$TOOLS_DIR/jadx/jadx-core-modern.jar" ] && echo jar-present)" || row "jadx (modern)" miss "missing"
[ -x "$TOOLS_DIR/jadx/jadx-1.1.0/bin/jadx" ] && row "jadx CLI 1.1.0 (bundled)" ok "v$("$TOOLS_DIR/jadx/jadx-1.1.0/bin/jadx" --version 2>/dev/null | head -1)" || row "jadx CLI 1.1.0" warn "optional"
[ -f "$TOOLS_DIR/jadx/dx-1.16.jar" ] && row "dx 1.16 (class -> dex fallback)" ok "present" || row "dx" warn "optional"
have d8 && row "d8 (modern dexer)" ok "present" || row "d8 / r8 (modern dexer)" warn "NOT available: dl.google.com + Maven Central blocked"

echo "Signing / alignment"
[ -f "$TOOLS_DIR/apktool/apksigner.jar" ] && row "apksigner (Android apksig)" ok "v$(java -jar "$TOOLS_DIR/apktool/apksigner.jar" --version 2>/dev/null)" || row "apksigner" miss "missing"
[ -x "$TOOLS_DIR/bin/zipalign" ] && row "zipalign (pure-python impl.)" ok "ok" || row "zipalign" miss "missing"
[ -f "$TOOLS_DIR/keys/test.keystore" ] && row "test keystore (PKCS12)" ok "$TOOLS_DIR/keys/test.keystore" || row "test keystore" miss "missing"

echo "Native / low-level analysis"
have r2 && row "radare2" ok "$(try r2 -v)" || row "radare2" warn "not built (run install.sh --with-radare2)"
[ -x "$V" ] && row "python venv" ok "$("$V" --version 2>&1)" || row "python venv" miss "missing"
for p in androguard lief capstone angr unicorn keystone-engine pypcode frida objection apkid quark-engine pyaxmlparser; do
  mod="${p//-/_}"
  case "$p" in keystone-engine) mod=keystone ;; quark-engine) mod=quark ;; esac
  if [ -x "$V" ] && "$V" -c "import importlib,sys; importlib.import_module('$mod')" >/dev/null 2>&1; then
    ver="$("$V" -c "import importlib.metadata as m; print(m.version('$p'))" 2>/dev/null)"
    row "python: $p" ok "${ver:-installed}"
  else
    row "python: $p" miss "not installed"
  fi
done
if [ -f "$TOOLS_DIR/npm/node_modules/@mauricelam/ghidra-decompiler-wasm/dist/ghidra_decompiler.wasm" ]; then
  row "Ghidra decompiler (WASM)" ok "present"
else
  row "Ghidra decompiler (WASM)" warn "run install.sh --with-node"
fi
have ghidraRun && row "Ghidra (full install)" ok "present" || row "Ghidra (full install)" warn "BLOCKED: needs a GitHub release asset (~400 MB) — see toolchain/README.md"

echo "Runtime testing"
[ -x "$TOOLS_DIR/platform-tools/adb" ] && row "adb / platform-tools" ok "$(try "$TOOLS_DIR/platform-tools/adb" version)" || row "adb" miss "missing"
[ -x "$TOOLS_DIR/venv/bin/frida" ] && row "frida (host tools)" ok "$(try "$TOOLS_DIR/venv/bin/frida" --version)" || row "frida" miss "missing"
[ -e /dev/kvm ] && row "emulator (/dev/kvm)" ok "kvm present" || row "emulator" warn "IMPOSSIBLE: no /dev/kvm + dl.google.com blocked"
have node && row "node" ok "$(try node --version)" || row "node" miss "missing"
have npm  && row "npm"  ok "$(try npm --version)"  || row "npm"  miss "missing"

echo "=============================================================="
[ "$miss" = 0 ] && echo " All required tools present." || echo " $miss required tool(s) missing."
echo " Reminder: tools live outside the git repo; re-run toolchain/install.sh"
echo " after a fresh sandbox/clone to restore them."
echo "=============================================================="
exit "$miss"
