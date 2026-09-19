# F2 Android RE toolchain

Everything requested was pulled into the sandbox and **verified working end-to-end**
on the real `yoyo.apk`. This folder makes the whole setup reproducible and documents
the few pieces that are genuinely impossible to fetch from here.

```bash
bash toolchain/install.sh                # recreate the toolchain (~5 min)
bash toolchain/install.sh --with-radare2 # + radare2 from source (~20 min, gcc+make)
bash toolchain/verify.sh                 # status table  <- run this first
source toolchain/env.sh                  # put everything on PATH
```

> **Persistence:** tools are installed outside the git repo (`/opt/tools`) because they
> are hundreds of MB. Only this folder (scripts, source, notes) is committed. After a
> fresh sandbox/clone, re-run `install.sh` — it is idempotent and re-downloads from the
> reachable hosts (GitHub + PyPI + npm), so nothing needs to be re-uploaded unless it is
> in the "blocked" table below.

---

## 1. What is installed and verified

| Area | Tool | Version | Proof |
|---|---|---|---|
| Java compile/run | **JDK 17** (`javac`, `java`, `jar`, `javadoc`, `javap`, `jshell`, `jlink`, `jmod`, `jpackage`) | 17.0.8 (Temurin) | compiled + ran + packaged a jar |
| Java runtime | **JRE 21 / JRE 25** (jdk4py) | 21.0.8 / 25.0.2 | `java -version` |
| APK inspection | **aapt** | 2.19-7832930 | `aapt dump badging yoyo.apk` |
| APK inspection | **aapt2** | build-tools (ibotpe) | `aapt2 dump badging/permissions` |
| APK decode/rebuild | **apktool** | 2.9.3 (bundles linux `aapt`) | decoded `yoyo.apk` → 91 MB tree, rebuilt → 34 MB APK |
| Decompiler | **jadx** modern jadx-core (shaded, driven via `jadx.api` API) | recent 1.x | 1490 `.java` from `classes.dex`, 1718 from the APK |
| Decompiler | **jadx CLI 1.1.0** (bundled dist) | 1.1.0 | decoded full APK |
| Dex tooling | **baksmali/smali** (inside apktool), **dx 1.16** | — | smali round-trip via apktool |
| APK signing | **apksigner** (Android `apksig`) | 0.9 | signed + `verify` v1/v2/v3 = true |
| APK signing | **apk_sign_ts** (pure JS v1/v2/v3) | 1.0.1 | optional, Node |
| APK alignment | **zipalign (official binary, imported from build-tools 35)** | 35.0.0 | `zipalign -c 4` PASS on `yoyo.apk`; cross-verified against the bundled implementation |
| APK alignment | **zipalign** (own pure-Python AOSP-semantics reimplementation) | 1.1 | `toolchain/bin/zipalign` — stored-entry alignment + CRC-verified rewrite, output accepted by the official tool |
| Keys/certs | **keytool** + generated **PKCS12 test keystore** | JDK 17 | `/opt/tools/keys/test.keystore` (pass `android`, alias `testkey`) |
| Android SDK | **platform-tools / adb** | 1.0.41 (36.0.0) | daemon starts; no device attached |
| Native analysis | **radare2** (built from GitHub source) | 6.2.2 | `rabin2 -I`, `r2 -c "aa; aflc"` → 17,916 functions in `libcocos2djs.so` |
| Native analysis | **LIEF, capstone, unicorn, keystone, pyelftools** | lief 1.0, capstone 5.0.6, unicorn 2.1.4 | import + API tests |
| Native analysis | **Ghidra SLEIGH/p-code** via **pypcode** | 3.3.3 (192 languages) | AArch64/x86 decode tests |
| Native analysis | **Ghidra decompiler compiled to WASM** | 0.0.4 (`@mauricelam/ghidra-decompiler-wasm`) | shipped in npm helpers |
| Native analysis | **angr** (+ cle, pyvex, claripy) | 9.2.213 | installed |
| APK static analysis | **androguard** | 4.1.4 | installed |
| APK static analysis | **apkid** (packer detection), **quark-engine** (behaviour score), **pyaxmlparser**, **apkutils** | latest | installed |
| Dynamic/runtime | **frida** + **frida-tools**, **objection** | 17.18.0 / 14.10.4 / 1.12.5 | host tools installed (need a device) |
| Scripting | **Python 3.11** + venv, **Node.js 22.22** + npm 10.9.8 | — | — |
| Build tooling | **gcc 12.2, make, binutils** (`objdump`, `readelf`, `nm`, `strings`, `ar`, `ld`) | — | used to build radare2 |

## 2. Blocked in this sandbox (and the offline workaround)

**Network reality here:** the only reachable hosts are `github.com`, `api.github.com`,
`codeload.github.com`, `pypi.org` / `files.pythonhosted.org` and `registry.npmjs.org`.
Blocked (TLS refused): `dl.google.com` / `maven.google.com`, `repo1.maven.org`,
`objects.githubusercontent.com` + `release-assets.githubusercontent.com` (**all GitHub
release assets**), `raw.githubusercontent.com`, Debian mirrors (so **no `apt-get`**),
Docker Hub, jsDelivr/unpkg/CDNJS, archive.org.

| # | Item | Why it's blocked | Impact | What to upload to our GitHub |
|---|---|---|---|---|
| 1 | **Ghidra (full install, `analyzeHeadless`/GUI)** | Only ships as a GitHub **release asset** (~400 MB) → redirected to a blocked host | No full Ghidra. Substitutes already working: r2 + angr + LIEF + capstone + pypcode + **Ghidra decompiler‑as‑WASM** | `ghidra_11.x_PUBLIC_*.zip`, split: `split -b 90m ghidra_*.zip gh.part.` → commit under `vendor/ghidra/`. I reassemble with `cat gh.part.* > ghidra.zip` |
| 2 | ~~Android SDK build-tools 35, cmdline-tools~~ | — | **RESOLVED**: imported from `main` (`build-tools_r35_linux.zip`, `commandlinetools-linux-*` split parts). Real `aapt2` 2.19, `zipalign`, **`d8` 8.6.2**, **`r8` 9.3.16**, `apksigner`, `dexdump`, `sdkmanager` 22.0 now installed | — |
| 3 | **Android SDK platform / `android.jar`** | `dl.google.com` blocked | cannot compile Android framework code (`javac` against android.jar) | `platform-35_r0*.zip` |
| 4 | **Android emulator + system images** | `dl.google.com` blocked **and no `/dev/kvm`** in the sandbox | Runtime/behaviour testing is **impossible here** — uploading files won't fix the missing hypervisor. Use your own PC (Android Studio emulator / real device over USB) | nothing (not useful) |
| 5 | **Gradle/Maven dependency resolution** | Maven Central + Google Maven blocked | Can't run a normal Gradle/Android build from source in here; plain `javac`/`jar` builds work fine | if you need it: your `~/.gradle/caches` (large) |
| 6 | **frida-server / frida-gadget binaries** | GitHub release assets blocked | Frida cannot attach to anything (also: no device here) | only needed once you have a device: `frida-server-17.x-android-arm64.xz` |
| 7 | **Newest apktool (2.11.x) / jadx (1.5.x) / apksigner** | Release assets + Maven Central blocked | 2.9.3 / modern jadx-core already decode current APKs; newest builds handle bleeding‑edge resources better | optional: `apktool_2.11.1.jar`, `jadx-1.5.3-all.jar` |
| 8 | **Debian packages (`apt`)** via `sudo apt-get` | Debian mirrors blocked | Everything needed was obtained from PyPI/npm/GitHub/source instead | not needed |

### How to unblock them — the `vendor/` drop-in (already wired)

Anything you download on your own PC goes into **`vendor/`**; the importer does the rest:

```bash
bash vendor/fetch-offline.sh --all      # (on YOUR PC) downloads + splits + hashes
git add vendor && git commit -m "vendor: offline artifacts" && git push

bash toolchain/vendor-import.sh --list  # (in the sandbox) dry run
bash toolchain/vendor-import.sh         # join parts, verify sha256, extract, wire wrappers
```

`vendor-import.sh` understands Ghidra, build-tools, cmdline-tools, platform
(`android.jar`), NDK, frida-server and standalone jars (apktool / jadx-all / apksigner /
d8 / r8), auto-joins `split`/7-zip/HJSplit parts, verifies `vendor/SHA256SUMS.txt`,
skips what is already installed and is safe to re-run (`--force` to redo). Details and
the exact upload list: **`vendor/README.md`**.

> **Never commit Git LFS pointers** for these files — LFS objects are served from a host
> that is blocked here, so pointers are useless. Commit real bytes (split if > 95 MB).

## 3. Layout

```
/opt/tools/                     (git-ignored location, recreated by install.sh)
├── jdk17/jre/                  full JDK 17
├── jre21/ , jre25/             extra JREs
├── apktool/apktool.jar         apktool 2.9.3
├── apktool/apksigner.jar       Android apksig apksigner
├── jadx/jadx-core-modern.jar   modern jadx-core
├── jadx/jadx-1.1.0/            jadx CLI dist
├── jadx/wrapper/JadxRunner.*   jadx.api driver (compiled with javac)
├── bin/{aapt,aapt2,zipalign,jadx}
├── platform-tools/adb
├── radare2/                    r2 6.2.2 (--with-radare2)
├── venv/                       python analysis stack
├── npm/node_modules/           JS helpers (--with-node)
├── keys/test.keystore          test signing key
└── work/                       scratch space for decodes/sec analysis

F2/
├── toolchain/{install.sh,verify.sh,env.sh,bin/…}
└── reports/yoyo-apk-profile.md
```

## 4. Verified pipelines on `yoyo.apk`

```bash
source toolchain/env.sh
apktool d -f -o /tmp/dec yoyo.apk                  # decode (manifest+res+smali+libs)
jadx yoyo.apk /tmp/src --nores                     # decompile to Java
zipalign -c 4 yoyo.apk                             # exit 0 (correctly 4-byte aligned)
zipalign -c -P 16 16384 yoyo.apk                   # exit 1 (not 16 KB-page aligned)
apksigner sign --ks $TEST_KEYSTORE --ks-pass pass:android \
    --key-pass pass:android --out /tmp/signed.apk /tmp/aligned.apk
apksigner verify --verbose /tmp/signed.apk         # v1+v2+v3 = true
apktool b /tmp/dec -o /tmp/rebuilt.apk             # rebuild from the decoded tree
rabin2 -I yoyo_apktool/lib/arm64-v8a/libcocos2djs.so
r2 -q -c 'aa; aflc' yoyo_apktool/lib/arm64-v8a/libcocos2djs.so
```

See `reports/yoyo-apk-profile.md` for what these produced for your APK.
