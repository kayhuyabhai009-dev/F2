# Debug network-capture patch

The supplied artifact is a compiled APK, not the Android/Cocos source project. Its
network-security resource permits cleartext traffic but trusts only the platform
system CA store. On Android 7 and later, a user-installed Burp/Charles/mitmproxy
CA is therefore not necessarily trusted by the app, which prevents HTTPS traffic
capture.

`enable_network_capture.py` creates a **debug/capture-only, unsigned** APK variant
whose network-security resource trusts both `system` and `user` certificates:

```sh
python3 tools/network_capture/enable_network_capture.py \
  yoyo.apk yoyo-network-capture-unsigned.apk

# Use the Android Build Tools matching your environment:
zipalign -p -f 4 yoyo-network-capture-unsigned.apk yoyo-network-capture-aligned.apk
apksigner sign --ks /path/to/debug-or-test.keystore \
  --out yoyo-network-capture.apk yoyo-network-capture-aligned.apk
apksigner verify --verbose yoyo-network-capture.apk
```

Install the proxy CA on the test device/emulator, configure its proxy, and use
only an authorized test account. The original APK signature cannot remain valid
after modifying `res/8G.xml`; the script deliberately strips old v1 records and
rewrites the ZIP, so the result must be signed with the owner's test/debug key.
Do not ship this patch in production: trusting user CAs and retaining cleartext
support weakens transport security. The production fix is to use HTTPS and a
narrow, documented trust policy.
