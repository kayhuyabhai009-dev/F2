# Yoyo APK analysis outputs

The main deliverable is [`yoyo_complete_report.md`](yoyo_analysis_artifacts/complete_report.md). It contains the structured findings and the complete Java-like decompiler appendix for all classes in `yoyo.apk`.

Important machine-readable outputs are in `yoyo_analysis_artifacts/`:

- `apk_inventory.tsv`: all 2,476 APK ZIP entries, sizes, hashes, types, and parse metadata.
- `json_inventory.tsv`: all JSON/manifest parsing results and UUID-reference counts.
- `remote_game_manifests.tsv`: all embedded hot-update/content manifests and their URLs.
- `manifest_components.tsv`, `AndroidManifest.decoded.xml`, and `aapt2_*.txt`: manifest/resource analysis.
- `dex_classes.tsv`, `dex_methods.tsv`, `dex_calls.tsv`, `dex_sensitive_findings.tsv`, and `dex_strings.txt`: DEX analysis.
- `*_readelf_*.txt` and `*_strings.txt`: both native library analyses.
- `textual_assets_dump.txt`: complete dump of parseable text-like APK entries.
- Phase-2 files (`apk_signing_pairs.tsv`, `main_manifest_variants.tsv`, `embedded_scene_urls.tsv`, `feature_string_hits.tsv`, `jsc_entropy.tsv`, and `native_script_functions.txt`) contain targeted signing, update-map, scene-URL, UI-feature, bytecode, and native disassembly results.
- Phase-3 files (`ca_bundle_certificates.tsv`, `duplicate_payload_groups.tsv`, `raw_asset_import_links.tsv`, `raw_binary_and_media_metadata.tsv`, and `mp3_frame_summary.tsv`) contain certificate-bundle, deduplication, asset-linkage, and media metadata results.

The analysis was static and offline. No APK execution or remote endpoint requests were made. Binary media is represented by hashes and parser metadata; encrypted Cocos `.jsc` files are not claimed to be source-decompiled.
