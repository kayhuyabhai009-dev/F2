# Traffic Capture Guide — Yono Rummy (`com.tppart.games.yo`)

**Goal:** app server ko kya bhejta hai, wo samajhna.
**Important:** iska detection se **koi lena-dena nahi hai** — APK modify karne ki **zaroorat nahi**.

---

## 0. Pehle 2 galatfehmiyan door

### ❌ "HTTPCanary se capture ho jayega"
Nahi hoga. Do kaaran:

| Problem | Detail |
|---|---|
| **WebSocket support nahi** | Game ka asli play traffic **Socket.IO / WebSocket** hai, HTTP nahi. HTTPCanary use nahi dikha sakta. Verified: `.so` me `jsb_socketio.cpp`, `jsb_websocket.cpp` + libuv raw TCP, protocol string `/socket.io/1/websocket/?EIO=2&transport=websocket&sid=` |
| **User CA trust nahi** | HTTPS ke liye app ko system CA chahiye (neeche #2) |

**Isliye HTTPCanary ki jagah `mitmproxy` use karenge** (already install ho gaya — v11.0.2). Isme WebSocket frames properly dikhte hain.

### ❌ "Pehle detection hataana padega"
Zaroorat nahi. Verified — app me **kuch bhi capture ko block nahi karta**:

| Blocker type | Is app me |
|---|---|
| VPN / proxy detection (`tun0`, `ppp0`, `isVpnConnected`, `TRANSPORT_VPN`) | **0** |
| Root detection (`su` paths, Magisk, RootBeer) | **0** |
| Certificate pinning | **0 configured** (`CertificatePinner` class sirf bundled OkHttp ke andar hai; app ne koi pin set nahi kiya) |
| `FLAG_SECURE` / MediaProjection | **0** |

Aur **signature check ka traffic capture se koi rishta nahi** — wo sirf APK re-sign hone pe fire karta hai. Proxy traffic capture device ke network level pe hota hai, APK ko chhoota bhi nahi.

---

## 1. App ka network layer — kya-kya expect karo

| Layer | Protocol | Endpoint | Capture ke liye |
|---|---|---|---|
| Game bundles (247) | **plain HTTP** | `http://ifs.yonorummy.in/GameX/1.6.8.7/<Game>` | **kuch bhi nahi chahiye** — seedha dikhta hai |
| Game rules | HTTPS | `https://ifs.yonogamebox.com/gamerule` | system CA chahiye |
| Partner site | HTTPS | `www.philslotsagent.com` | system CA chahiye |
| **Game play** | **Socket.IO / WebSocket** (native, libuv) | asli server runtime pe pata chalega | mitmproxy chahiye |
| Firebase | HTTPS | Google endpoints | capture ho sakta hai, ignore karo |

> Asli "play" server ka URL encrypted JS (`.jsc`) me hai — **isi liye capture kar rahe ho**. Wo runtime pe hi pata chalega.

---

## 2. Recommended setup — rooted device + system CA (**APK untouched**)

Ye **best raasta** hai: APK bilkul chhedo mat → re-sign nahi → signature check pass rehta hai → app normally chalta rehta hai.

### Step 1 — proxy start karo

```bash
bash tools/capture.sh start
# ya manually, WebSocket dekhne ke liye mitmweb:
~/.local/bin/mitmweb --listen-host 0.0.0.0 --listen-port 8080 --web-port 8081
```

`mitmweb` ka UI browser me: **http://127.0.0.1:8081**
WebSocket / Socket.IO frames **"WebSocket"** tab me alag se milte hain.

### Step 2 — mitmproxy ka CA banao

```bash
bash tools/capture.sh ca
```

Ye bata dega:
```
CA file : ~/.mitmproxy/mitmproxy-ca-cert.pem
hash    : c8750f0d
ready   : /tmp/c8750f0d.0
```

(Aapke system pe hash alag ho sakta hai — script khud calculate karta hai.)

### Step 3 — CA ko device me **SYSTEM** cert banao (root chahiye)

Android 7+ pe app sirf system CA trust karta hai, isliye user cert install karne se kaam nahi chalega.

```bash
bash tools/capture.sh adb-ca
```

Agar wo fail ho (system read-only), to **Magisk se** (aasan):

1. Magisk app → Modules → Install from storage → **MagiskTrustUserCerts** module
2. Reboot
3. Phir CA ko normally install karo: Settings → Security → Encryption & credentials → Install a certificate → CA certificate → `mitmproxy-ca-cert.cer`
4. Reboot — Magisk usko automatically system store me move kar dega

Ya manually (root shell se):
```bash
HASH=$(openssl x509 -inform PEM -subject_hash_old -in ~/.mitmproxy/mitmproxy-ca-cert.pem | head -1)
adb push ~/.mitmproxy/mitmproxy-ca-cert.pem /sdcard/$HASH.0
adb shell
su
mount -o rw,remount /
cp /sdcard/$HASH.0 /system/etc/security/cacerts/$HASH.0
chmod 644 /system/etc/security/cacerts/$HASH.0
reboot
```

### Step 4 — device ka proxy set karo

```bash
bash tools/capture.sh adb-proxy
# ya phone me manually: Wi-Fi → apna network → Modify → Advanced → Proxy → Manual
#   Hostname: <PC ka LAN IP>   Port: 8080
```

### Step 5 — dekhna shuru karo

App kholo, game kholo, aur mitmweb me traffic dekho.

**Kaam ke filters mitmweb me:**
```
~u yonorummy          → sirf yonorummy URLs
~u ifs\.               → asset server
~m POST               → POST requests (login, bet, etc.)
~t websocket          → WebSocket frames
~h ifs.yonorummy.in   → host filter
```

**Capture file me save karke baad me padhna:**
```bash
bash tools/capture.sh save          # → flows.mitm
# baad me:
mitmproxy -r flows.mitm
mitmdump -r flows.mitm --flow-detail 3 > traffic.txt
```

### Cleanup
```bash
bash tools/capture.sh adb-clear
```

---

## 3. Agar root nahi hai

Do option:

### Option A — Android emulator (root by default)
```bash
emulator -avd <name> -writable-system -no-snapshot
adb root && adb remount
# phir Step 3,4,5
```
Emulator pe root built-in hai — sabse aasan agar physical phone root nahi karna chahte.

### Option B — APK patch karke `network_security_config.xml` badlo
Ye **re-sign** maangta hai, aur tab signature check fire karega. Isliye:

```xml
<!-- res/xml/network_security_config.xml -->
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system" />
            <certificates src="user" />   <!-- ← ye line add karo -->
        </trust-anchors>
    </base-config>
</network-security-config>
```

**⚠️ Tradeoff:** re-sign karte ho to `ProjUtil.checksignture()` fail hoga → `isCloner()` = 1. App phir bhi chalega (check sirf flag deta hai), par JS us flag pe kya karta hai wo encrypted hai — pata nahi. Agar app block kare, to signature check bypass karna padega, jo alag kaam hai.

**Behtar alternative agar aage rebrand karna hai:** vendor ke paas keystore hai aur wapas nahi milega — matlab **aage koi bhi release naye key se hi aayega**. To `checksignture()` me pinned string (`3jMaDJlNnNJSjitwqDprP53dyxc=`) ko **apne naye key ke hash se replace** karna chahiye, hatana nahi. Isse check kaam karta rehta hai aur aapka build bhi chalta hai.

---

## 4. Kya-kya mil sakta hai (expectations)

| Traffic | Capture hoga? |
|---|---|
| Game asset downloads (`http://ifs.yonorummy.in/...`) | ✅ plaintext, bina CA |
| `https://ifs.yonogamebox.com/gamerule` | ✅ system CA ke saath |
| WebSocket / Socket.IO handshake + frames | ✅ mitmproxy me |
| Login / bet / game events | ✅ agar WebSocket pe hain |
| Server URLs (jo `.jsc` me chhupi hain) | ✅ **yahan se hi pata chalenge** |
| Firebase/GMS traffic | ✅ dikhega, ignore karo |

⚠️ **Do cheezein block kar sakti hain capture:**
1. Kuch games **native TLS** use karte hain jo proxy ignore karta hai — us case me proxy setting bypass ho jaati hai. Tab `tcpdump`/Wireshark se raw TCP dekhna padega.
2. Server **TLS pinning** kare (client side nahi) — kam chance.

---

## 5. Ek line me summary

> HTTPCanary chhod do (WebSocket nahi dikhata). **Rooted device + mitmproxy system CA** use karo — APK bilkul chhedna nahi padta, isliye signature/clone detection ka koi lafda hi nahi aata. Game ka play traffic Socket.IO hai, wo mitmweb ke WebSocket tab me milega.

---

## Quick reference

```bash
bash tools/capture.sh ca          # CA banao + hash/naam batao
bash tools/capture.sh start        # proxy kaise chalana hai (commands)
bash tools/capture.sh adb-ca       # CA → system store (root)
bash tools/capture.sh adb-proxy    # device proxy set
bash tools/capture.sh save         # capture → flows.mitm
bash tools/capture.sh adb-clear    # proxy hatao
```
