#!/usr/bin/env bash
# Source this file to get the F2 Android RE toolchain on your PATH:
#     source toolchain/env.sh
#
# Tools live outside the git repo (default /opt/tools) because they are heavy
# binaries; run toolchain/install.sh to (re)create them, and
# toolchain/vendor-import.sh to wire in anything dropped into vendor/.

export TOOLS_DIR="${TOOLS_DIR:-/opt/tools}"

export JAVA_HOME="$TOOLS_DIR/jdk17/jre"          # full JDK 17 (javac, jar, keytool, jarsigner)
export JRE21_HOME="$TOOLS_DIR/jre21"             # JRE 21 (Ghidra, newer JVM tools)
export JRE25_HOME="$TOOLS_DIR/jre25"

export PATH="$JAVA_HOME/bin:$TOOLS_DIR/bin:$TOOLS_DIR/platform-tools:$TOOLS_DIR/radare2/bin:$TOOLS_DIR/venv/bin:$PATH"

# Optional components (present only after toolchain/vendor-import.sh imports them)
[ -d "$TOOLS_DIR/build-tools/current" ]    && export PATH="$TOOLS_DIR/build-tools/current:$PATH"
[ -d "$TOOLS_DIR/cmdline-tools/current/bin" ] && export PATH="$TOOLS_DIR/cmdline-tools/current/bin:$PATH"
[ -d "$TOOLS_DIR/ghidra" ]                 && export GHIDRA_INSTALL_DIR="$TOOLS_DIR/ghidra"
[ -d "$TOOLS_DIR/ndk/current" ]            && export ANDROID_NDK_HOME="$TOOLS_DIR/ndk/current"
[ -f "$TOOLS_DIR/android-platform/current/android.jar" ] && export ANDROID_JAR="$TOOLS_DIR/android-platform/current/android.jar"

export LD_LIBRARY_PATH="$TOOLS_DIR/radare2/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

export APKTOOL_JAR="$TOOLS_DIR/apktool/apktool.jar"        # apktool 2.9.3
export APKSIGNER_JAR="$TOOLS_DIR/apktool/apksigner.jar"    # Android apksig / apksigner CLI
export JADX_JAR="$TOOLS_DIR/jadx/jadx-core-modern.jar"     # modern jadx-core (API driver)
export JADX_ALL_JAR="$TOOLS_DIR/jadx/jadx-all.jar"         # optional official jadx CLI jar (vendor/)
export JADX_OLD="$TOOLS_DIR/jadx/jadx-1.1.0/bin/jadx"      # bundled jadx 1.1.0 CLI
export TEST_KEYSTORE="$TOOLS_DIR/keys/test.keystore"       # test signing key (pass: android)
export GHIDRA_DECOMPILER_WASM="$TOOLS_DIR/npm/node_modules/@mauricelam/ghidra-decompiler-wasm"

# Convenience wrappers
apktool()  { java -jar "$APKTOOL_JAR" "$@"; }
apksigner(){ java -jar "$APKSIGNER_JAR" "$@"; }
jadx()     { "$TOOLS_DIR/bin/jadx" "$@"; }
jadx-old() { "$JADX_OLD" "$@"; }
# Ghidra headless (needs Java 21+, uses the bundled JRE 21)
ghidra-headless() { JAVA_HOME="${GHIDRA_JAVA_HOME:-$JRE21_HOME}" GHIDRA_INSTALL_DIR="$TOOLS_DIR/ghidra" \
                    "$TOOLS_DIR/ghidra/support/analyzeHeadless" "$@"; }
# Compile against android.jar when a platform zip was imported
javac-android() { javac -bootclasspath "${ANDROID_JAR:?android.jar not imported}" "$@"; }

echo "toolchain ready (TOOLS_DIR=$TOOLS_DIR)"
[ -n "${GHIDRA_INSTALL_DIR:-}" ] && echo "  Ghidra:       $GHIDRA_INSTALL_DIR"
[ -n "${ANDROID_JAR:-}" ]        && echo "  android.jar:  $ANDROID_JAR"
[ -d "$TOOLS_DIR/build-tools/current" ] && echo "  build-tools:  $TOOLS_DIR/build-tools/current ($(command -v zipalign 2>/dev/null || echo 'zipalign-py only'))"
