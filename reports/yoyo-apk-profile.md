# yoyo.apk — static profile (produced with the toolchain in `toolchain/`)

> Everything below was produced **inside the sandbox** with the tools installed by
> `toolchain/install.sh`. Nothing was uploaded anywhere.

## Identity

| Field | Value |
|---|---|
| Package | `com.tppart.games.yo` |
| Version | 2.3.0 (versionCode 230) |
| App label | Yono Rummy |
| Launcher activity | `org.cocos2dx.javascript.AppActivity` (Cocos2d-JS / Cocos Creator) |
| minSdkVersion | 21 |
| targetSdkVersion / compileSdk | 35 (Android 15) |
| Native ABIs | `arm64-v8a`, `armeabi-v7a` |
| Platform build | `platformBuildVersionName=15` |

## Signature (original)

```
Signer #1 certificate DN: CN=lamislot, OU=lamislot, O=lamislot, L=ls, ST=ls, C=65
Signer #1 SHA-256: 5cbb225fff2ab9db2ce018bcbadbd378151f7ed8fcbd3ec9dbeae6cc1ca8eeea
Schemes: v1 = true, v2 = true, v3 = false, v4 = false
Number of signers: 1
```

## Contents

| Part | Uncompressed |
|---|---|
| `lib/` (2 × `libcocos2djs.so`) | 40.0 MB |
| `assets/` | 25.2 MB |
| `classes.dex` (single dex) | 1.7 MB |
| `META-INF/`, `resources.arsc`, `res/` | ~1.0 MB |
| **Total** | **67.8 MB** (2476 zip entries, 35.7 MB file) |

Permissions (9): `INTERNET`, `ACCESS_NETWORK_STATE`, `VIBRATE`, `WAKE_LOCK`,
`POST_NOTIFICATIONS`, + 4 more.

## Notable findings

1. **Zipalignment: the APK is correctly 4-byte zipaligned** — official
   `zipalign -c 4 yoyo.apk` → exit 0, "Verification succesful" (316 stored entries
   aligned; the 2160 deflated entries are exempt, AOSP only aligns uncompressed data).
   *Correction:* an earlier version of this report claimed the APK was unaligned; that
   came from a check that (incorrectly) also required compressed entries to be aligned.
   The bundled `toolchain/bin/zipalign` has since been fixed to follow AOSP semantics,
   and its output is cross-verified against the official Android binary.
2. **Not 16 KB-page aligned** — `zipalign -c -P 16 16384 yoyo.apk` → exit 1. Relevant
   for 16 KB-page kernels (Android 15+ on such devices), which expect stored
   `lib/*.so` to be 16384-aligned and ideally stored uncompressed.
3. **Native libraries are compressed** (`method=8`, legacy `extractNativeLibs`
   packaging). Uncompressed `.so` is what 16 KB-page devices prefer; if you want
   page alignment, store them uncompressed and run `zipalign -f -p -P 16 16384 …`.
3. Native lib is a stripped, full-RELRO, canary+PIC+**NX** AArch64 Cocos2d-JS
   build (`Android clang 9.0.9`): `rabin2 -I` → 517 imports, 15975 exports,
   34847 strings; `r2 -c "aa; aflc"` → **17,916 functions** recovered.
4. Signing scheme v3 is absent. Re-signing with `apksigner` in this repo adds
   v1+v2+v3 (verified).

## Reproduced commands

```bash
source toolchain/env.sh
apksigner verify --print-certs yoyo.apk
aapt2 dump badging yoyo.apk
zipalign -c 4 yoyo.apk                       # exit 0: correctly 4-byte aligned
zipalign -c -P 16 16384 yoyo.apk             # exit 1: NOT 16 KB-page aligned
apktool d -f -o yoyo_apktool yoyo.apk        # 91 MB tree, smali + resources
jadx yoyo.apk yoyo_jadx --nores              # ~1.5k-1.7k .java files
rabin2 -I yoyo_apktool/lib/arm64-v8a/libcocos2djs.so
```

## Full rebuild loop (verified working)

```bash
apktool b yoyo_apktool -o yoyo_rebuilt.apk                 # decode -> rebuild
zipalign -f -p 4 yoyo_rebuilt.apk yoyo_rebuilt_aligned.apk # align (integrity-checked)
apksigner sign --ks /opt/tools/keys/test.keystore \
    --ks-pass pass:android --key-pass pass:android \
    --out yoyo_rebuilt_signed.apk yoyo_rebuilt_aligned.apk
apksigner verify --verbose yoyo_rebuilt_signed.apk         # v1+v2+v3: true
```
