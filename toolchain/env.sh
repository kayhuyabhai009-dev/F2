#!/usr/bin/env bash
# Source this file to get the F2 Android RE toolchain on your PATH:
#     source toolchain/env.sh
#
# All tools are installed outside the git repo (default /opt/tools) because they
# are heavy binaries; run toolchain/install.sh to (re)create them.

export TOOLS_DIR="${TOOLS_DIR:-/opt/tools}"

export JAVA_HOME="$TOOLS_DIR/jdk17/jre"          # full JDK 17 (javac, jar, keytool, jarsigner)
export JRE21_HOME="$TOOLS_DIR/jre21"             # JRE 21 (for tools that need a newer JVM, e.g. Ghidra)
export JRE25_HOME="$TOOLS_DIR/jre25"

export PATH="$JAVA_HOME/bin:$TOOLS_DIR/bin:$TOOLS_DIR/platform-tools:$TOOLS_DIR/radare2/bin:$TOOLS_DIR/venv/bin:$PATH"
export LD_LIBRARY_PATH="$TOOLS_DIR/radare2/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

export APKTOOL_JAR="$TOOLS_DIR/apktool/apktool.jar"        # apktool 2.9.3
export APKSIGNER_JAR="$TOOLS_DIR/apktool/apksigner.jar"    # Android apksig / apksigner CLI
export JADX_JAR="$TOOLS_DIR/jadx/jadx-core-modern.jar"     # modern jadx-core (API driver)
export JADX_OLD="$TOOLS_DIR/jadx/jadx-1.1.0/bin/jadx"      # bundled jadx 1.1.0 CLI
export TEST_KEYSTORE="$TOOLS_DIR/keys/test.keystore"       # test signing key (pass: android)
export GHIDRA_DECOMPILER_WASM="$TOOLS_DIR/npm/node_modules/@mauricelam/ghidra-decompiler-wasm"

# Convenience wrappers
apktool()  { java -jar "$APKTOOL_JAR" "$@"; }
apksigner(){ java -jar "$APKSIGNER_JAR" "$@"; }
jadx()     { "$TOOLS_DIR/bin/jadx" "$@"; }
jadx-old() { "$JADX_OLD" "$@"; }
