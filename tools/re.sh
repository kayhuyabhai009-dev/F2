#!/usr/bin/env bash
# ============================================================
#  re.sh — Android RE + APK patching one-shot helper
#  Usage: bash tools/re.sh <command> [args]
#
#  Commands:
#    info    <apk>                → badging, permissions, signer, libs, dex
#    decode  <apk> [outdir]       → apktool decode (smali + res + assets)
#    build   <dir> [out.apk]      → apktool rebuild
#    sign    <apk> [out.apk]      → zipalign + apksigner (v1+v2+v3)
#    cycle   <apk> [out.apk]      → decode→build→sign→verify (no edit round-trip test)
#    java    <apk> [outdir]       → jadx decompile to .java
#    dex     <apk> [outdir]       → baksmali (.smali)
#    assets  <apk> [outdir]       → sirf assets/ + lib/ + manifest nikaalo
#    verify  <apk>                → signature + alignment check
#    ksgen   <name>               → naya signing keystore banao
# ============================================================
set -u

RE_TOOLS="${RE_TOOLS:-/home/user/tools}"
export JAVA_HOME="${JAVA_HOME:-$RE_TOOLS/jdk}"
BT="$RE_TOOLS/android/build-tools"
export LD_LIBRARY_PATH="$BT/lib64:${LD_LIBRARY_PATH:-}"
APKTOOL="$RE_TOOLS/apktool.jar"
JADX="$RE_TOOLS/jadx/bin/jadx"
KS="${DEBUG_KEYSTORE:-$RE_TOOLS/keystores/debug.keystore}"
KSPASS="android"; KSALIAS="androiddebugkey"
WORK="${WORK:-/home/user/work}"
mkdir -p "$WORK"

C="\033[1;36m"; G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; N="\033[0m"
say() { printf "\n${C}==> %s${N}\n" "$*"; }
ok()  { printf "${G}   ok${N}  %s\n" "$*"; }
warn(){ printf "${Y}   !!${N}  %s\n" "$*"; }
die() { printf "${R}   xx${N}  %s\n" "$*"; exit 1; }
need(){ [ -e "$1" ] || die "not found: $1"; }

cmd="${1:-help}"; shift || true

case "$cmd" in

# ---------------------------------------------------------------- info
info)
  APK="${1:?usage: re.sh info <apk>}"; need "$APK"
  say "APK INFO — $APK"
  echo "  size    : $(du -h "$APK" | cut -f1)"
  echo "  sha256  : $(sha256sum "$APK" | cut -d' ' -f1)"
  say "badging (aapt2)"
  "$BT/aapt2" dump badging "$APK" 2>/dev/null | grep -E "^(package|application-label|launchable-activity|sdkVersion|targetSdkVersion|uses-permission|native-code)" | head -30
  say "signer"
  "$JAVA_HOME/bin/java" -jar "$BT/lib/apksigner.jar" verify --print-certs -v "$APK" 2>/dev/null | grep -Ev "^WARNING" | grep -E "^(Verifies|Verified using|Number|Signer #1 certificate DN|Signer #1 certificate SHA-256)" 
  say "native libs"
  unzip -l "$APK" | grep -E "\.so$" | awk '{printf "  %10d  %s\n",$1,$4}'
  say "dex"
  unzip -l "$APK" | grep -E "classes.*\.dex$" | awk '{printf "  %10d  %s\n",$1,$4}'
  say "entry counts"
  echo "  total entries : $(unzip -l "$APK" | tail -1 | awk '{print $2}')"
  for d in assets lib res META-INF; do
    echo "  $d/ : $(unzip -l "$APK" | grep -c " $d/")"
  done
  ;;

# ---------------------------------------------------------------- decode
decode)
  APK="${1:?usage: re.sh decode <apk> [outdir]}"
  OUT="${2:-$WORK/$(basename "${APK%.apk}")_apktool}"; need "$APK"
  say "apktool decode → $OUT"
  "$JAVA_HOME/bin/java" -Xmx3g -jar "$APKTOOL" d "$APK" -o "$OUT" -f 2>&1 | grep -E "^(I:|W:|E:)" | tail -8
  ok "decoded: $(du -sh "$OUT" | cut -f1)  — $(find "$OUT/smali" -name '*.smali' 2>/dev/null | wc -l) smali files"
  echo "   edit karo:  $OUT/AndroidManifest.xml, $OUT/smali/, $OUT/assets/, $OUT/res/"
  echo "   phir:       bash tools/re.sh build \"$OUT\""
  ;;

# ---------------------------------------------------------------- build
build)
  DIR="${1:?usage: re.sh build <project-dir> [out.apk]}"
  OUT="${2:-$WORK/$(basename "$DIR")_patched.apk}"; need "$DIR"
  say "apktool build → $OUT"
  "$JAVA_HOME/bin/java" -Xmx3g -jar "$APKTOOL" b "$DIR" -o "$OUT" -f 2>&1 | grep -E "^(I:|W:|E:)" | tail -8
  [ -f "$OUT" ] && ok "built: $(du -h "$OUT" | cut -f1)" || die "build failed"
  echo "$OUT"
  ;;

# ---------------------------------------------------------------- sign
sign)
  APK="${1:?usage: re.sh sign <apk> [out.apk]}"
  OUT="${2:-${APK%.apk}_signed.apk}"; need "$APK"
  say "zipalign + sign → $OUT"
  "$BT/zipalign" -p -f 4 "$APK" "${OUT%.apk}_aligned.apk" || die "zipalign failed"
  "$JAVA_HOME/bin/java" -jar "$BT/lib/apksigner.jar" sign \
      --ks "$KS" --ks-pass "pass:$KSPASS" --key-pass "pass:$KSPASS" --ks-key-alias "$KSALIAS" \
      --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
      --out "$OUT" "${OUT%.apk}_aligned.apk" 2>/dev/null || die "sign failed"
  rm -f "${OUT%.apk}_aligned.apk"
  ok "signed: $(du -h "$OUT" | cut -f1)"
  "$JAVA_HOME/bin/java" -jar "$BT/lib/apksigner.jar" verify -v "$OUT" 2>/dev/null | grep -E "^(Verifies|Verified using)" 
  echo "$OUT"
  ;;

# ---------------------------------------------------------------- cycle
cycle)
  APK="${1:?usage: re.sh cycle <apk> [out.apk]}"
  OUT="${2:-$WORK/$(basename "${APK%.apk}")_roundtrip.apk}"
  D="$WORK/$(basename "${APK%.apk}")_cyc"
  say "round-trip test: decode → build → sign"
  "$JAVA_HOME/bin/java" -Xmx3g -jar "$APKTOOL" d "$APK" -o "$D" -f >/dev/null 2>&1 && ok "1/3 decoded"
  "$JAVA_HOME/bin/java" -Xmx3g -jar "$APKTOOL" b "$D" -o "$WORK/_rt.apk" -f >/dev/null 2>&1 && ok "2/3 rebuilt"
  "$BT/zipalign" -p -f 4 "$WORK/_rt.apk" "$WORK/_rta.apk" && ok "3/3 aligned"
  "$JAVA_HOME/bin/java" -jar "$BT/lib/apksigner.jar" sign --ks "$KS" --ks-pass "pass:$KSPASS" \
      --key-pass "pass:$KSPASS" --ks-key-alias "$KSALIAS" --out "$OUT" "$WORK/_rta.apk" 2>/dev/null && ok "signed"
  rm -f "$WORK/_rt.apk" "$WORK/_rta.apk"
  "$JAVA_HOME/bin/java" -jar "$BT/lib/apksigner.jar" verify -v "$OUT" 2>/dev/null | grep -E "^Verifies" 
  echo "   original : $(du -h "$APK" | cut -f1)"
  echo "   patched  : $(du -h "$OUT" | cut -f1)  →  $OUT"
  ;;

# ---------------------------------------------------------------- java
java)
  APK="${1:?usage: re.sh java <apk> [outdir]}"
  OUT="${2:-$WORK/$(basename "${APK%.apk}")_jadx}"; need "$APK"
  say "jadx decompile → $OUT"
  "$JADX" -d "$OUT" --show-bad-code "$APK" 2>&1 | tail -3
  ok "$(find "$OUT/sources" -name '*.java' | wc -l) java files"
  ;;

# ---------------------------------------------------------------- dex
dex)
  APK="${1:?usage: re.sh dex <apk> [outdir]}"
  OUT="${2:-$WORK/$(basename "${APK%.apk}")_smali}"; need "$APK"
  say "baksmali → $OUT"
  T=$(mktemp -d); unzip -q -o "$APK" 'classes*.dex' -d "$T"
  mkdir -p "$OUT"
  CP=$(ls "$RE_TOOLS"/jadx/lib/*.jar | tr '\n' ':')
  for d in "$T"/*.dex; do
    "$JAVA_HOME/bin/java" -cp "$CP" com.android.tools.smali.baksmali.Main d "$d" -o "$OUT/$(basename "${d%.dex}")" 2>&1 | tail -2
  done
  rm -rf "$T"
  ok "$(find "$OUT" -name '*.smali' | wc -l) smali files"
  ;;

# ---------------------------------------------------------------- assets
assets)
  APK="${1:?usage: re.sh assets <apk> [outdir]}"
  OUT="${2:-$WORK/$(basename "${APK%.apk}")_extract}"; need "$APK"
  say "extract assets/ lib/ + manifest → $OUT"
  mkdir -p "$OUT"; (cd "$OUT" && unzip -q -o "$(realpath "$APK")" 'assets/*' 'lib/*' 'AndroidManifest.xml' 'META-INF/*' 2>/dev/null)
  ok "$(du -sh "$OUT" | cut -f1) extracted"
  ls "$OUT"
  ;;

# ---------------------------------------------------------------- verify
verify)
  APK="${1:?usage: re.sh verify <apk>}"; need "$APK"
  say "signature + alignment — $APK"
  "$JAVA_HOME/bin/java" -jar "$BT/lib/apksigner.jar" verify --print-certs -v "$APK" 2>/dev/null | grep -Ev "^WARNING" | head -14
  "$BT/zipalign" -c -v 4 "$APK" >/dev/null 2>&1 && ok "zipalign 4-byte OK" || warn "zipalign FAILED"
  ;;

# ---------------------------------------------------------------- ksgen
ksgen)
  NAME="${1:?usage: re.sh ksgen <name> [pass] }"
  PASS="${2:-android}"
  KS="$RE_TOOLS/keystores/$NAME.keystore"
  say "naya keystore → $KS"
  "$JAVA_HOME/bin/keytool" -genkeypair -v -keystore "$KS" -storepass "$PASS" -keypass "$PASS" \
     -alias "$NAME" -keyalg RSA -keysize 2048 -validity 10950 \
     -dname "CN=$NAME,O=$NAME,C=IN" 2>&1 | tail -2
  ok "alias=$NAME  pass=$PASS"
  ;;

# ---------------------------------------------------------------- help
*)
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  ;;
esac
