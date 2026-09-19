#!/usr/bin/env bash
# ============================================================
#  capture.sh — Yono Rummy ka network traffic capture karne ke liye
#
#  Usage:
#    bash tools/capture.sh ca          → mitmproxy CA banao + hash + naam batao
#    bash tools/capture.sh start       → proxy start karo (mitmweb UI + mitmdump)
#    bash tools/capture.sh adb-proxy   → device ka proxy adb se set karo
#    bash tools/capture.sh adb-ca      → CA ko device me SYSTEM cert banao (root chahiye)
#    bash tools/capture.sh adb-clear   → proxy hatao
#    bash tools/capture.sh wifi        → sirf IP/host batao (manual Wi-Fi proxy ke liye)
#    bash tools/capture.sh save        → traffic ko file me save karo (flows.mitm)
# ============================================================
set -u

MITM_BIN="${HOME}/.local/bin"
export PATH="$MITM_BIN:$PATH"
CONFDIR="${MITMDIR:-$HOME/.mitmproxy}"
PORT="${MITMPORT:-8080}"

C="\033[1;36m"; G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; N="\033[0m"
say(){ printf "\n${C}==> %s${N}\n" "$*"; }
ok(){  printf "${G}   ok${N}  %s\n" "$*"; }
warn(){ printf "${Y}   !!${N}  %s\n" "$*"; }
die(){ printf "${R}   xx${N}  %s\n" "$*"; exit 1; }

need_mitm() {
  command -v mitmdump >/dev/null 2>&1 || \
    { die "mitmproxy nahi mila. install: python3 -m pip install --user mitmproxy"; }
}
lan_ip() {
  # LAN IP dhoondho — link-local (169.254) aur virtual interfaces skip karo
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  case "$ip" in
    169.254.*|127.*|"") ip="" ;;   # link-local / loopback = kaam ka nahi
  esac
  if [ -z "$ip" ]; then
    ip=$(ip -4 -o addr show scope global 2>/dev/null \
         | awk '$2!~/^(docker|veth|br-|virbr|tun|tap)/ {split($4,a,"/"); print a[1]}' \
         | grep -v '^169\.254\.' | head -1)
  fi
  printf '%s' "${ip:-}"
}
lan_ip_warn() {
  [ -n "$(lan_ip)" ] || warn "LAN IP detect nahi hui — IP_OVERRIDE=<apna PC IP> ke saath chalao"
}

case "${1:-help}" in

# ─────────────────────────────────────────────────────── CA
ca)
  need_mitm
  say "mitmproxy CA generate"
  if [ ! -f "$CONFDIR/mitmproxy-ca-cert.pem" ]; then
    timeout 8 mitmdump --set confdir="$CONFDIR" --listen-port 18099 -q >/dev/null 2>&1 || true
  fi
  [ -f "$CONFDIR/mitmproxy-ca-cert.pem" ] || die "CA generate nahi hui"
  HASH=$(openssl x509 -inform PEM -subject_hash_old -in "$CONFDIR/mitmproxy-ca-cert.pem" 2>/dev/null | head -1)
  ok "CA file : $CONFDIR/mitmproxy-ca-cert.pem"
  ok "hash    : $HASH"
  echo
  echo "   Android ko system cert ke naam se chahiye: ${HASH}.0"
  cp "$CONFDIR/mitmproxy-ca-cert.pem" "/tmp/${HASH}.0"
  ok "ready   : /tmp/${HASH}.0   (adb-ca command isko device me daal degi)"
  echo
  echo "   Phone browser se download karna ho to: http://mitm.it"
  ;;

# ─────────────────────────────────────────────────────── start
start)
  need_mitm
  IP=$(lan_ip)
  say "proxy start (port $PORT)"
  lan_ip_warn
  echo "   PC/LAN IP     : ${IP:-<detect nahi hui — IP_OVERRIDE use karo>}"
  echo "   device proxy  : ${IP:-<IP>}:$PORT"
  echo "   Web UI        : http://127.0.0.1:8081  (mitmweb)"
  echo
  echo "   ── mitmweb (browser UI, WebSocket bhi dikhta hai) ──"
  echo "   mitmweb --listen-host 0.0.0.0 --listen-port $PORT --web-port 8081 --set confdir=$CONFDIR"
  echo
  echo "   ── mitmdump (terminal + file save) ──"
  echo "   mitmdump --listen-host 0.0.0.0 --listen-port $PORT --set confdir=$CONFDIR -w flows.mitm"
  echo
  echo "   WebSocket/Socket.IO frames mitmweb me 'WebSocket' tab me milenge."
  echo "   Plain HTTP (ifs.yonorummy.in) bina CA ke bhi dikhega — CA sirf HTTPS ke liye."
  ;;

# ─────────────────────────────────────────────────────── save
save)
  need_mitm
  IP=$(lan_ip)
  say "capture → flows.mitm  (chalta rahega, Ctrl+C se rokna)"
  exec mitmdump --listen-host 0.0.0.0 --listen-port "$PORT" --set confdir="$CONFDIR" \
       -w flows.mitm --set save_stream_file=flows.stream
  ;;

# ─────────────────────────────────────────────────────── wifi
wifi)
  IP=$(lan_ip)
  say "manual Wi-Fi proxy settings"
  lan_ip_warn
  echo "   Phone → Settings → Wi-Fi → apna network → Modify → Advanced"
  echo "     Proxy      : Manual"
  echo "     Hostname   : ${IP:-<PC ka LAN IP>}"
  echo "     Port       : $PORT"
  echo
  warn "phone aur PC same Wi-Fi pe hona chahiye"
  ;;

# ─────────────────────────────────────────────────────── adb-proxy
adb-proxy)
  command -v adb >/dev/null 2>&1 || die "adb nahi mila"
  IP="${IP_OVERRIDE:-$(lan_ip)}"
  [ -n "$IP" ] || die "LAN IP nahi mila — IP_OVERRIDE=1.2.3.4 se do"
  say "device proxy = $IP:$PORT"
  adb shell settings put global http_proxy "$IP:$PORT"
  ok "set ho gaya (verify: adb shell settings get global http_proxy)"
  echo "   mitmweb UI: http://127.0.0.1:8081"
  ;;

# ─────────────────────────────────────────────────────── adb-ca
adb-ca)
  command -v adb >/dev/null 2>&1 || die "adb nahi mila"
  [ -f "$CONFDIR/mitmproxy-ca-cert.pem" ] || die "pehle: bash tools/capture.sh ca"
  HASH=$(openssl x509 -inform PEM -subject_hash_old -in "$CONFDIR/mitmproxy-ca-cert.pem" | head -1)
  F="/tmp/${HASH}.0"
  [ -f "$F" ] || cp "$CONFDIR/mitmproxy-ca-cert.pem" "$F"
  say "CA ko system trust store me daal rahe hain (root chahiye)"
  adb push "$F" "/sdcard/${HASH}.0" || die "push fail"
  echo "   -- /system writable karo --"
  adb shell "su -c 'mount -o rw,remount /'" 2>/dev/null || true
  adb shell "su -c 'mount -o rw,remount /system'" 2>/dev/null || true
  echo "   -- copy + permission --"
  adb shell "su -c 'cp /sdcard/${HASH}.0 /system/etc/security/cacerts/${HASH}.0 && chmod 644 /system/etc/security/cacerts/${HASH}.0 && ls -l /system/etc/security/cacerts/${HASH}.0'" \
    || warn "root nahi mila ya /system read-only hai — Magisk module use karo (neeche dekho)"
  ok "ho gaya. device REBOOT karo, phir HTTPS bhi capture hoga"
  echo
  echo "   Magisk wala aasan tareeka (agar upar fail ho):"
  echo "     1) Magisk app → Modules → Install from storage"
  echo "     2) 'MagiskTrustUserCerts' module install karo"
  echo "     3) phir CA ko normally install karo (Settings → Security → Encryption → Install cert → CA)"
  echo "     4) reboot — Magisk usko automatically system store me move kar dega"
  ;;

# ─────────────────────────────────────────────────────── adb-clear
adb-clear)
  command -v adb >/dev/null 2>&1 || die "adb nahi mila"
  say "proxy hata rahe hain"
  adb shell settings put global http_proxy :0
  ok "cleared"
  ;;

*)
  sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
  ;;
esac
