# F2 — Android RE / APK Patching Toolchain

`yoyo.apk` (Cocos Creator game, `com.tppart.games.yo`) ke reverse engineering aur
patching ke liye poora offline toolchain. Sab kuch is repo ke andar se ya
PyPI/npm se aata hai.

## Install (ek command)

```bash
bash tools/setup-toolchain.sh      # ~2 min, idempotent
source /home/user/tools/env.sh     # PATH set karo
```

## Kya-kya installed hai

| Tool | Version | Source | Kaam |
|---|---|---|---|
| Temurin JDK | 25.0.2 | PyPI `jdk4py` | sab Java tools chalane ke liye |
| apktool | 3.0.3 | `apktool_3.0.3.jar` (repo) | decode / rebuild APK |
| jadx | 1.1.0 | npm `@mishguru/jadx-node` | dex → java |
| baksmali / smali | 2.3.4 | jadx ke jars | dex ↔ smali |
| aapt2 | 2.19 | `build-tools_r35_linux.zip` (repo) | resource compile / badging |
| apksigner | 0.9 | build-tools (repo) | APK sign + verify (v1/v2/v3) |
| zipalign | r35 | build-tools (repo) | 4-byte alignment |
| d8 / dexdump | r35 | build-tools (repo) | dex banana / dekhna |
| cmdline-tools | 19.0 | 5 split parts (repo) | sdkmanager, apkanalyzer |
| androguard, LIEF, capstone, quark | latest | PyPI | python based analysis |
| frida / frida-tools | 17.18 | PyPI | runtime hooking (device chahiye) |

> **Note:** is sandbox me `release-assets.githubusercontent.com` (GitHub release
> downloads) aur `deb.debian.org` blocked hain. Isliye JDK/jadx GitHub releases ki
> jagah **PyPI + npm** se aate hain, aur Android tools repo me pehle se rakhe
> zips se.

## Usage

```bash
R="bash tools/re.sh"

$R info   yoyo.apk              # package, permissions, signer, libs, dex
$R decode yoyo.apk              # → work/yoyo_apktool/  (smali + res + assets)
  # ... ab AndroidManifest.xml / smali / assets edit karo ...
$R build  work/yoyo_apktool     # → patched apk
$R sign   work/yoyo_apktool_patched.apk
$R verify work/yoyo_apktool_patched_signed.apk

$R java   yoyo.apk              # jadx → .java sources
$R dex    yoyo.apk              # baksmali → .smali
$R assets yoyo.apk              # sirf assets/ + lib/ nikaalo
$R cycle  yoyo.apk              # full round-trip test (decode→build→sign)
$R ksgen  mykey                 # apna signing keystore
```

## Traffic capture — app ka network traffic dekhna

```bash
bash tools/setup-toolchain.sh              # mitmproxy bhi install ho jata hai
bash tools/capture.sh ca                   # mitmproxy CA banao (hash + file bata dega)

# phone rooted hai:
bash tools/capture.sh adb-ca               # CA → device ke SYSTEM trust store me
bash tools/capture.sh adb-proxy            # device ka proxy set karo

# phone non-rooted hai (koi root ki zaroorat nahi, APK bhi same rehta hai):
bash tools/capture.sh emu                  # emulator + adb root + CA + proxy (10.0.2.2)
# phir mitmweb chalao → WebSocket frames bhi dikhenge (decoder: -s tools/yono-proto.py)
```

Poori guide: **[CAPTURE-GUIDE.md](CAPTURE-GUIDE.md)**

> **Zaroori:** APK modify karne ki **zaroorat nahi**. System-CA wala tareeka device level pe kaam
> karta hai — APK waisa hi rehta hai, re-sign nahi hota, isliye signature/clone detection ka
> koi lafda nahi aata.
>
> **HTTPCanary kaam nahi karega** — app ka game traffic raw WebSocket hai, HTTPCanary
> HTTP-only tool hai. Aur user-installed CA ko Android 7+ pe ye app trust nahi karta
> (`network_security_config.xml` me `<certificates src="user"/>` nahi hai).

## Protocol decode — captured traffic ko padhna

Capture kar liya, par frames binary hain? `yono-proto.py` unhe readable banata hai —
app ke andar se recover kiya gaya format: **8-byte header + msgpack(JSON)**.

```bash
python3 tools/yono-proto.py --self-test        # checksum + frame + crypto round-trip

# live: mitmproxy addon (decoded frames terminal + work/traffic/*.jsonl)
export YONO_P_K='...' YONO_P_AK='...'          # encrypted HTTP responses ke liye (optional)
mitmdump -s tools/yono-proto.py --listen-port 8080

# offline
python3 tools/yono-proto.py --hex '0029 1742 6aae5653 d927 7b22...'
python3 tools/yono-proto.py --pack '{"c":11}'                    # apna frame banao
python3 tools/yono-proto.py --cent-sign 'http://host/x' --uid 1  # HTTP auth header
python3 tools/yono-proto.py --decrypt-response '{"data":...}'    # encrypted response
```

Protocol spec (frame layout, checksum, command ids, HTTP auth, encrypted responses):
**[PROTOCOL.md](PROTOCOL.md)** · keys/endpoints `work/PROTOCOL-LOCAL.md` (gitignored).

## yoyo.apk ke andar kya hai

```
com.tppart.games.yo            Cocos Creator JS game
├── classes.dex                1.7 MB  (1718 java classes)
├── lib/arm64-v8a/libcocos2djs.so    22 MB   ← game engine
├── lib/armeabi-v7a/libcocos2djs.so  17.5 MB
├── assets/src/settings.jsc    2.4 MB  ← XXTEA-encrypted gzip → JS (decrypt: work/)
├── assets/main.js             7.8 KB
├── assets/jsb-adapter/*.js    JS engine glue
└── assets/res/import/*.json   1766 game data files
```

`.jsc` assets **XXTEA** se encrypted hain aur andar **gzip** hai (11.5 MB JS total).
Key native library me hardcoded hai; decrypt karne ke baad poora client logic readable ho jaata hai.
Decrypt recipe + keys: `work/PROTOCOL-LOCAL.md` (local-only, public repo me nahi).

Signer: `CN=lamislot` · v1+v2 signed · targetSdk 35

## Signing

Debug keystore: `/home/user/tools/keystores/debug.keystore`
(pass `android`, alias `androiddebugkey`). Play Store pe daalne ke liye apna
keystore banao: `$R ksgen mykey` — aur wahi keystore sambhal ke rakho, warna
update push nahi kar paoge.
