# Traffic Capture Guide — Yono Rummy (`com.tppart.games.yo`)

**Goal:** app server ko kya bhejta hai, wo samajhna.
**Important:** iska detection se **koi lena-dena nahi hai** — APK modify karne ki **zaroorat nahi**.

---

## 0. Pehle 3 galatfehmiyan door

### ❌ "Non-rooted phone + HTTPCanary se ho jayega"
**TLS traffic readable nahi hoga** — aur wajah app ki "protection" nahi, Android ka trust model hai:

| Fact | Value (verified) |
|---|---|
| App `targetSdkVersion` | **35** → Android 7.0+ par **user-installed CA trust nahi hota** |
| `network_security_config.xml` | sirf `<base-config cleartextTrafficPermitted="true"/>` — **koi `<trust-anchors>` nahi**, `<certificates src="user"/>` **nahi** |
| Certificate pinning | **0 configured** (sirf bundled OkHttp library ki classes hain, app ne kuch pin nahi kiya) |

HTTPCanary non-rooted par apna CA **user store** me daalta hai. Ye app us store ko dekhta hi nahi.
Isliye HTTPCanary me `wss://` connection **dikh sakta hai, par andar ka content readable nahi hoga**
(TLS handshake uske CA se nahi hota) — ya connection hi fail hoga.

> WSS frames dikhna aur unka **readable hona** do alag cheezein hain. App-level
> encryption alag layer hai (dekho [PROTOCOL.md](PROTOCOL.md)), uske liye `yono-proto.py` hai.

### ✅ Iske 3 asli hal

| Route | Root chahiye? | APK modify? | Kaam karta hai? |
|---|---|---|---|
| **A. Emulator (Google APIs image)** | emulator ke andar haan (free) | **nahi** | ✅ best |
| **B. Apna phone root karo** | haan | **nahi** | ✅ |
| **C. App aapka hai? vendor se keystore / debug build lo** | nahi | **nahi** | ✅ cleanest |

```bash
# ── Route A: emulator (non-rooted PHONE ki zaroorat nahi) ──
bash tools/capture.sh ca        # CA banao
# emulator chalao (Google APIs image, Play Store wali nahi) → phir:
bash tools/capture.sh emu       # adb root + CA system store + proxy 10.0.2.2:8080
mitmdump -s tools/yono-proto.py --listen-port 8080
adb install yoyo.apk            # bilkul wahi APK — modify nahi, re-sign nahi
```

### ❌ "HTTPCanary se capture ho jayega"
Upar wali wajah se nahi hota (CA trust), tool ki galti nahi.
Game ka asli play traffic **raw WebSocket** hai (`ws://host/ws`, binary frames) —
mitmproxy ke **"WebSocket"** tab me alag se dikhta hai, aur `yono-proto.py` addon
use seedha **JSON** me decode kar deta hai.

### ❌ "Pehle detection hataana padega"
Zaroorat nahi — aur **hatane ko kuch hai bhi nahi**. Verified (decrypted JS + smali, dono se):

| Blocker type | Is app me |
|---|---|
| VPN / proxy detection (`tun0`, `ppp0`, `isVpnConnected`, `TRANSPORT_VPN`) | **0** |
| Root detection (`su` paths, Magisk, RootBeer) | **0** |
| Frida / Xposed / hook detection | **0** |
| Debugger / ptrace check | **0** |
| `FLAG_SECURE` / MediaProjection | **0** |
| Certificate pinning | **0 configured** |
| Play Integrity / SafetyNet | **0** |

Sirf **ek** cheez hai — aur wo capture se related nahi: `ProjUtil.checksignture()`
APK ke **signature** ko ek pinned hash se match karta hai (clone/repack detect karne ke liye).
Capture device ke network level par hota hai, APK ke andar nahi — isliye APK chhue bina
ye check kabhi fire hi nahi hota. **Ye check capture ko rok nahi raha; rokne wali
cheez sirf CA trust hai (upar dekho).**

> Ek APK ko re-sign karke chalane ka matlab hota hai us signature check ko todna —
> warna app khud "cannot run at this mode" bol ke band ho jaata hai. Agar app aapka
> hai to uski signing key bhi aapke paas hoti, aur phir kuch todna hi nahi padta —
> wahi seedha raasta hai (Route C).

---

## 1. App ka network layer — kya-kya expect karo

| Layer | Protocol | Endpoint | Capture ke liye |
|---|---|---|---|
| Game bundles (247) | **plain HTTP** | `http://ifs.yonorummy.in/GameX/1.6.8.7/<Game>` | **kuch bhi nahi chahiye** — seedha dikhta hai |
| Game rules | HTTPS | `https://ifs.yonogamebox.com/gamerule` | system CA chahiye |
| Partner site | HTTPS | `www.philslotsagent.com` | system CA chahiye |
| **Game play** | **raw WebSocket**, binary frames (native libuv/jsb) | login/node server — `wss://<host>/ws` | mitmproxy chahiye (decoder: `yono-proto.py`) |
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
WebSocket frames **"WebSocket"** tab me alag se milte hain. Binary frames ko readable banane ke liye decoder addon use karo:

```bash
mitmweb -s tools/yono-proto.py --listen-port 8080     # decoded frames + work/traffic/*.jsonl
```

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
| WebSocket handshake + frames (decoded) | ✅ mitmproxy + `yono-proto.py` addon |
| Login / bet / game events | ✅ agar WebSocket pe hain |
| Server URLs (jo `.jsc` me chhupi hain) | ✅ **yahan se hi pata chalenge** |
| Firebase/GMS traffic | ✅ dikhega, ignore karo |

⚠️ **Do cheezein block kar sakti hain capture:**
1. Kuch games **native TLS** use karte hain jo proxy ignore karta hai — us case me proxy setting bypass ho jaati hai. Tab `tcpdump`/Wireshark se raw TCP dekhna padega.
2. Server **TLS pinning** kare (client side nahi) — kam chance.

---

## 5. Ek line me summary

> HTTPCanary chhod do (WebSocket nahi dikhata). **Rooted device + mitmproxy system CA** use karo — APK bilkul chhedna nahi padta, isliye signature/clone detection ka koi lafda hi nahi aata. Play traffic raw WebSocket hai; `yono-proto.py` addon ke saath frames decoded (JSON) milenge.

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
