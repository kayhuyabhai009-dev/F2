# `vendor/` — drop-in folder for offline artifacts

This folder is scanned by **`toolchain/vendor-import.sh`**, which auto-detects what you
upload, reassembles split files, verifies checksums, extracts them into the toolchain
(`/opt/tools`) and wires up wrappers. Nothing else is needed from you — just commit the
file(s) here.

```bash
bash toolchain/vendor-import.sh --list    # show what was detected (dry run)
bash toolchain/vendor-import.sh           # import + wire everything found
```

## ⚠️ Rules

1. **Do NOT use Git LFS.** LFS objects are served from a host that is blocked in the
   sandbox, so a pointer file is useless. Commit the real bytes.
2. **Max 100 MB per file** (GitHub hard limit). Bigger files must be split — see below.
3. Keep the **original file name** (auto-detection is name based). Split parts keep the
   base name plus a numeric/alpha suffix, e.g. `ghidra_11.3.2_PUBLIC.zip.part.aa`.
4. Optional but recommended: add `vendor/SHA256SUMS.txt` with `<sha256>  <filename>` lines
   (the *original* file name) and the importer will verify before extracting.

## What to upload (priority order)

| Priority | File | Where to get it | Effect once imported |
|---|---|---|---|
| 1 | `ghidra_11.x_PUBLIC_*.zip` (~400 MB → split into 5 parts) | github.com/NationalSecurityAgency/ghidra/releases (works from your PC) | full Ghidra: `ghidra-headless`, `analyzeHeadless`, `pyghidra` start working |
| 2 | `build-tools_r35-linux.zip` (~60 MB) | dl.google.com/android/repository/build-tools_r35-linux.zip | real `aapt2`, `zipalign`, **`d8`/`r8` dexers**, `dexdump`, `apksigner` |
| 3 | `commandlinetools-linux-*_latest.zip` (~150 MB) | dl.google.com/android/repository/commandlinetools-linux-*_latest.zip | `sdkmanager`, `avdmanager` (needs network for package installs — mostly for show) |
| 4 | `platform-35_r0*.zip` (~60 MB) | dl.google.com/android/repository/platform-35_r02.zip | `android.jar` → compile Android framework code with `javac` |
| 5 | `android-ndk-r26d-linux.zip` (~700 MB, optional) | dl.google.com/android/repository/android-ndk-r26d-linux.zip | NDK clang → build native libs for the APK |
| 6 | `apktool_2.11.1.jar`, `jadx-1.5.x-all.jar`, `apksigner.jar` (optional, newer) | github releases / maven (from your PC) | newer decoders than the bundled 2.9.3 / jadx-core |
| 7 | `frida-server-17.x-android-arm64.xz` | github.com/frida/frida/releases | only useful when you test on a real device |

### Splitting a big file

```bash
# Linux/macOS — 90 MB parts (keeps the original name as the prefix)
split -b 90m ghidra_11.3.2_PUBLIC.zip ghidra_11.3.2_PUBLIC.zip.part.
ls   # ghidra_11.3.2_PUBLIC.zip.part.aa, .ab, .ac ...
# commit ALL parts (the .zip itself must NOT be committed)
```
Windows (PowerShell): `7z a -v90m ghidra_11.3.2_PUBLIC.zip.part ghidra_11.3.2_PUBLIC.zip`
→ produces `.part.001`, `.part.002` … (also supported).
HJSplit / `split -n` suffixes such as `.001`, `.aa`, `.000` are all supported.

### Checksums (optional)

```bash
sha256sum ghidra_11.3.2_PUBLIC.zip build-tools_r35-linux.zip > SHA256SUMS.txt
# commit SHA256SUMS.txt next to the parts
```

## What happens after the import

| Tool | Path / command |
|---|---|
| Ghidra | `/opt/tools/ghidra`, wrapper `ghidra-headless`, `GHIDRA_INSTALL_DIR` exported by `toolchain/env.sh` |
| Build-tools | `/opt/tools/build-tools/current/{aapt2,zipalign,d8,r8,apksigner,…}` and added to `PATH`; the official `zipalign` then takes over from the bundled Python one (kept as `zipalign-py`) |
| Platform | `/opt/tools/android-platform/current/android.jar` |
| cmdline-tools | `/opt/tools/cmdline-tools/current/{sdkmanager,avdmanager}` |
| NDK | `/opt/tools/ndk/current` |
| frida-server | `/opt/tools/frida/` |

Everything is idempotent: re-running the importer re-checks and only installs what is
missing or newer.
