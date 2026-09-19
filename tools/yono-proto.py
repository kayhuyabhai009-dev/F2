#!/usr/bin/env python3
"""
yono-proto.py — Yono Rummy (com.tppart.games.yo) WebSocket protocol decoder + live mitmproxy addon.

Yeh tool app ke WebSocket protocol ko REVERSE-ENGINEER karke samajhne ke liye hai
(apne hi app ka traffic analysis). Frame format JS source se recover kiya gaya hai.

════════════════════════════════════════════════════════════════════════════
FRAME FORMAT  (har WebSocket binary message)
════════════════════════════════════════════════════════════════════════════
  offset  size  field        notes
  ------  ----  -----------  ------------------------------------------------
  0       2     payload_len  uint16 BIG-ENDIAN = payload ka byte length
  2       2     checksum     uint16 BIG-ENDIAN = srcSum(payload[:128])
  4       4     timestamp    uint32 BIG-ENDIAN = seconds (client clock)
  8       N     payload      msgpack-encoded STRING (andar JSON hota hai)

  • checksum algo: init 0xFFFF, per byte: i ^= b; i = (i&1) ? (i>>1)^0x70B1 : i>>1
  • payload = msgpack(JSON.stringify(msgObject))  → decode se JSON string milti hai
  • msgObject fields (common):
        c      uint   command id (MsgId table dekho)
        c_ts   uint   client timestamp ms
        c_idx  uint   incrementing sequence
        uid    uint   player id (login ke baad)
        language str  "en"/"in" etc.
  • LOGIN (c=1) frame me extra field:
        x = md5( str(c_ts) + <salt> )      ← salt app ke JS me hota hai
  • HEARTBEAT cmd = 11, timeout ~4s, interval ~5s

════════════════════════════════════════════════════════════════════════════
USAGE
════════════════════════════════════════════════════════════════════════════
  1) LIVE CAPTURE (mitmproxy addon — decoded traffic terminal me dikhega):
        mitmdump -s tools/yono-proto.py --listen-port 8080
        # ya mitmweb ke paath ke saath:
        mitmweb -s tools/yono-proto.py --listen-port 8080

     Decoded traffic JSONL me bhi save hota hai: work/traffic/yono-<ts>.jsonl

  2) OFFLINE CLIENT — msgpack library ki zaroorat NAHI hai:
        # raw hex string se
        python3 tools/yono-proto.py --hex '2211a1ff65a3f1c2a2...'

  3) PACK/ENCODE (apna test frame banane ke liye):
        python3 tools/yono-proto.py --pack '{"c":11}'

  4) SELF-TEST:
        python3 tools/yono-proto.py --self-test

════════════════════════════════════════════════════════════════════════════
ENCRYPTED HTTP RESPONSES  (charge/response-decrypt module)
════════════════════════════════════════════════════════════════════════════
  Kuch HTTP responses plain JSON ki jagah aise aate hain:
        {"data": "<base64>", "timestamp": 1700000000, "signature": "<hex>"}
  Scheme (JS source se):
        1. timestamp app ke ±300 s andar hona chahiye
        2. signature == HMAC_SHA256( key = P_K , msg = data + str(timestamp) )   (hex)
        3. base64(data) = IV(12 byte) || AES-GCM ciphertext(+tag)
           AES key = P_AK ke bytes (Latin-1 charCode, 32 char => AES-256)

  Keys tool me hardcode NAHI hain — env se aate hain:
        export YONO_P_K='<32-char hmac key>'
        export YONO_P_AK='<32-char aes key>'
        python3 tools/yono-proto.py --decrypt-response '{"data":"...","timestamp":123,"signature":"..."}'

  mitmproxy addon in keys ke saath live HTTP responses ko bhi auto-decrypt karta hai.

  HTTP auth headers (JS: getUPHead) — server-side replay/verify ke liye:
        CENT-TIMESTAMP = server time (seconds)
        CENT-SIGN      = md5( url.substr(0,100) + CENT-TIMESTAMP + uid )
        # check karne ke liye:
        python3 tools/yono-proto.py --cent-sign 'http://host/path' --uid 12345 --ts 1700000000
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import struct
import sys
import time

DELTA_CHECKSUM = 0x70B1          # 28849 — srcSum ka polynomial
SRCSUM_BYTES = 128               # checksum sirf pehle 128 bytes par
HEADER_LEN = 8
CMD_HEARTBEAT = 11
CMD_LOGIN = 1
TIMESTAMP_TTL = 300              # encrypted response ka max clock skew (seconds)

# msgpack string prefixes (payload hamesha ek string hota hai)
#  fixstr : 0b101xxxxx            (len 0..31)
#  str8   : 0xd9 + 1-byte len
#  str16  : 0xda + 2-byte len (BE)
#  str32  : 0xdb + 4-byte len (BE)
MSGPACK_STR8, MSGPACK_STR16, MSGPACK_STR32 = 0xD9, 0xDA, 0xDB
MSGPACK_BIN8, MSGPACK_BIN16, MSGPACK_BIN32 = 0xC4, 0xC5, 0xC6


# ─────────────────────────────────────────────────────────────────────────────
# checksum (JS: Global.srcSum) + header helpers (JS: Global.jsToCByShort/Int)
# ─────────────────────────────────────────────────────────────────────────────
def src_sum(data: bytes, n: int | None = None) -> int:
    """JS Global.srcSum(e,t) ka exact port — init 0xFFFF, poly 0x70B1."""
    if n is None:
        n = min(len(data), SRCSUM_BYTES)
    acc = 0xFFFF
    for i in range(n):
        acc ^= data[i]
        acc = (acc >> 1) if (acc & 1) == 0 else ((acc >> 1) ^ DELTA_CHECKSUM)
        acc &= 0xFFFF
    return acc


def build_header(payload: bytes, timestamp: int | None = None) -> bytes:
    """8-byte header banata hai: [len BE u16][srcSum BE u16][ts BE u32]."""
    if timestamp is None:
        timestamp = int(time.time())
    return struct.pack(
        ">HHI",
        len(payload) & 0xFFFF,
        src_sum(payload),
        timestamp & 0xFFFFFFFF,
    )


def pack_frame(msg: dict | str, timestamp: int | None = None) -> bytes:
    """JSON message → poora WebSocket binary frame (header + msgpack string)."""
    if isinstance(msg, str):
        js = msg
    else:
        js = json.dumps(msg, separators=(",", ":"), ensure_ascii=False)
    raw = js.encode("utf-8")
    n = len(raw)
    if n <= 31:
        payload = bytes([0xA0 | n]) + raw
    elif n <= 0xFF:
        payload = bytes([MSGPACK_STR8, n]) + raw
    elif n <= 0xFFFF:
        payload = bytes([MSGPACK_STR16]) + struct.pack(">H", n) + raw
    else:
        payload = bytes([MSGPACK_STR32]) + struct.pack(">I", n) + raw
    return build_header(payload, timestamp) + payload


# ─────────────────────────────────────────────────────────────────────────────
# msgpack (sirf ek string — isliye library ki zaroorat nahi)
# ─────────────────────────────────────────────────────────────────────────────
def msgpack_read_string(buf: bytes) -> tuple[str, int]:
    """buf se ek msgpack string padhta hai. return (text, bytes_consumed)."""
    if not buf:
        raise ValueError("khali buffer")
    b0 = buf[0]
    if 0xA0 <= b0 <= 0xBF:                      # fixstr
        ln, off = b0 & 0x1F, 1
    elif b0 in (MSGPACK_STR8, MSGPACK_BIN8):
        ln, off = buf[1], 2
    elif b0 in (MSGPACK_STR16, MSGPACK_BIN16):
        ln, off = struct.unpack_from(">H", buf, 1)[0], 3
    elif b0 in (MSGPACK_STR32, MSGPACK_BIN32):
        ln, off = struct.unpack_from(">I", buf, 1)[0], 5
    else:
        # string nahi — generic msgpack object maan ke library try karo
        try:
            import msgpack  # type: ignore
            obj = msgpack.unpackb(buf, raw=False, strict_map_key=False)
            return json.dumps(obj, ensure_ascii=False, default=str), len(buf)
        except Exception as exc:  # pragma: no cover
            raise ValueError(f"msgpack prefix 0x{b0:02x} parse nahi hua: {exc}") from exc
    if len(buf) < off + ln:
        raise ValueError(f"truncated msgpack string (chahiye {ln} byte, mila {len(buf) - off})")
    return buf[off:off + ln].decode("utf-8", "replace"), off + ln


def msgpack_write_string(s: str) -> bytes:
    raw = s.encode("utf-8")
    n = len(raw)
    if n <= 31:
        return bytes([0xA0 | n]) + raw
    if n <= 0xFF:
        return bytes([MSGPACK_STR8, n]) + raw
    if n <= 0xFFFF:
        return bytes([MSGPACK_STR16]) + struct.pack(">H", n) + raw
    return bytes([MSGPACK_STR32]) + struct.pack(">I", n) + raw


# ─────────────────────────────────────────────────────────────────────────────
# decoder
# ─────────────────────────────────────────────────────────────────────────────
class DecodedFrame:
    __slots__ = ("length", "checksum", "checksum_ok", "timestamp", "payload_len",
                 "json_text", "obj", "error", "raw")

    def __init__(self, raw: bytes):
        self.raw = raw
        self.error: str | None = None
        self.json_text: str | None = None
        self.obj = None
        if len(raw) < HEADER_LEN:
            self.error = f"frame chhota hai ({len(raw)} byte) — header 8 byte chahiye"
            self.length = self.checksum = self.timestamp = self.payload_len = 0
            self.checksum_ok = False
            return
        self.length, self.checksum, self.timestamp = struct.unpack(">HHI", raw[:8])
        payload = raw[HEADER_LEN:]
        self.payload_len = len(payload)
        self.checksum_ok = (src_sum(payload) == self.checksum)
        try:
            text, _used = msgpack_read_string(payload)
            self.json_text = text
            try:
                self.obj = json.loads(text)
            except json.JSONDecodeError:
                self.obj = None            # JSON nahi, sirf string
        except ValueError as exc:
            self.error = str(exc)

    # ── pretty print ────────────────────────────────────────────────────────
    def cmd(self) -> int | None:
        if isinstance(self.obj, dict):
            c = self.obj.get("c")
            return int(c) if isinstance(c, (int, float)) else None
        return None

    def describe(self, msgid: dict[str, str] | None = None) -> str:
        ts = time.strftime("%H:%M:%S", time.localtime(self.timestamp)) if self.timestamp else "?"
        if self.error:
            return (f"[!] ts={ts} len={self.length} chk={'ok' if self.checksum_ok else 'BAD'} "
                    f"ERROR: {self.error}\n    raw: {self.raw[:48].hex(' ')}")
        c = self.cmd()
        name = ""
        if c is not None and msgid:
            name = f"  {msgid.get(str(c), '?')}"
        head = f"[{'✓' if self.checksum_ok else '✗chk'}] ts={ts} cmd={c}{name} len={self.length}"
        if isinstance(self.obj, dict):
            return head + "\n" + json.dumps(self.obj, ensure_ascii=False, indent=2, default=str)
        return head + f"\n  (non-JSON string) {self.json_text!r}"


# ─────────────────────────────────────────────────────────────────────────────
# encrypted HTTP response (charge/response-decrypt) — HMAC-SHA256 + AES-256-GCM
# ─────────────────────────────────────────────────────────────────────────────
def hmac_sha256_hex(key: str, msg: str) -> str:
    """JS: HmacSHA256(msg, key).toString(Hex) — key/message UTF-8 strings."""
    return hmac.new(key.encode("utf-8"), msg.encode("utf-8"), hashlib.sha256).hexdigest()


def aes_key_bytes(ak: str) -> bytes:
    """JS importAESKey: i[n] = 255 & e.charCodeAt(n)  → Latin-1 bytes."""
    return bytes(ord(ch) & 0xFF for ch in ak)


def aes_gcm_decrypt(ak: str, b64_data: str, aad: bytes | None = None) -> str:
    """base64(data) = IV(12) || ciphertext+tag  → AES-GCM plaintext (UTF-8)."""
    blob = base64.b64decode(b64_data)
    if len(blob) <= 12 + 16:
        raise ValueError(f"data bahut chhota hai ({len(blob)} byte) — IV(12)+tag(16) chahiye")
    iv, ct = blob[:12], blob[12:]
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError as exc:  # pragma: no cover
        raise ValueError("`cryptography` package chahiye: pip install cryptography") from exc
    return AESGCM(aes_key_bytes(ak)).decrypt(iv, ct, aad).decode("utf-8")


def looks_encrypted(obj) -> bool:
    """JS isEncryptedResponse(): data(str) + timestamp(num) + signature(str)."""
    return (isinstance(obj, dict)
            and isinstance(obj.get("data"), str)
            and isinstance(obj.get("timestamp"), (int, float))
            and isinstance(obj.get("signature"), str))


def decrypt_response(obj: dict, k: str | None, ak: str | None,
                     check_ttl: bool = True) -> tuple[dict, list[str]]:
    """Encrypted response dict → plaintext JSON. return (result, notes)."""
    notes: list[str] = []
    data, ts, sig = obj["data"], int(obj["timestamp"]), obj["signature"]

    if not k or not ak:
        raise ValueError("keys missing — YONO_P_K / YONO_P_AK env set karo (ya --key-k/--key-ak)")

    if check_ttl:
        skew = abs(int(time.time()) - ts)
        notes.append(f"timestamp skew = {skew}s  {'(TTL ke andar)' if skew <= TIMESTAMP_TTL else '(TTL se BAHAR — app reject karta)'}")

    expect = hmac_sha256_hex(k, data + str(ts))
    ok = hmac.compare_digest(expect, sig)
    notes.append(f"signature {'MATCH ✓' if ok else 'MISMATCH ✗'}"
                 f"  (expected {expect[:16]}…, got {sig[:16]}…)")
    if not ok:
        raise ValueError("signature verify fail — galat P_K ya payload tamper")

    text = aes_gcm_decrypt(ak, data)
    notes.append(f"AES-GCM decrypt ✓  ({len(text)} chars plaintext)")
    try:
        return json.loads(text), notes
    except json.JSONDecodeError:
        return {"_raw_text": text}, notes


def cent_sign(url: str, uid: int, ts: int) -> str:
    """JS getUPHead(): md5( url.substr(0,100) + serverTime + uid )."""
    return hashlib.md5(f"{url[:100]}{ts}{uid}".encode("utf-8")).hexdigest()


# ─────────────────────────────────────────────────────────────────────────────
# MsgId table — work/decrypted/msgid-table.json se auto-load (optional)
# ─────────────────────────────────────────────────────────────────────────────
def load_msgid_table(paths: list[str] | None = None) -> dict[str, str]:
    here = os.path.dirname(os.path.abspath(__file__))
    roots = paths or [
        os.path.join(here, "msgid-table.json"),
        os.path.join(here, os.pardir, "work", "decrypted", "msgid-table.json"),
    ]
    for p in roots:
        if os.path.isfile(p):
            try:
                with open(p, encoding="utf-8") as fh:
                    data = json.load(fh)
                tbl = data.get("by_cmd", data)
                return {str(k): str(v) for k, v in tbl.items()}
            except Exception:
                continue
    return {str(CMD_HEARTBEAT): "HEARTBEAT", str(CMD_LOGIN): "LOGIN"}


# ─────────────────────────────────────────────────────────────────────────────
# mitmproxy addon
# ─────────────────────────────────────────────────────────────────────────────
class YonoProtoAddon:
    """mitmdump/mitmweb -s tools/yono-proto.py ke saath chalta hai."""

    def __init__(self):
        self.tbl = load_msgid_table()
        self.seen = 0
        self.k = os.environ.get("YONO_P_K") or None
        self.ak = os.environ.get("YONO_P_AK") or None
        self.log_path: str | None = None
        self.log_fh = None

    def _ensure_log(self):
        """Log file sirf pehle message par banao (CLI mode me files na banein)."""
        if self.log_fh is not None:
            return
        here = os.path.dirname(os.path.abspath(__file__))
        out_dir = os.path.join(here, os.pardir, "work", "traffic")
        os.makedirs(out_dir, exist_ok=True)
        self.log_path = os.path.join(out_dir, f"yono-{time.strftime('%Y%m%d-%H%M%S')}.jsonl")
        self.log_fh = open(self.log_path, "a", encoding="utf-8", buffering=1)
        key_state = "keys mil gayi (HTTP responses auto-decrypt honge)" if (self.k and self.ak) \
            else "keys nahi (YONO_P_K / YONO_P_AK set karo → encrypted responses decrypt honge)"
        print(f"[yono-proto] decoded traffic log: {os.path.abspath(self.log_path)}", flush=True)
        print(f"[yono-proto] {key_state}", flush=True)

    # ── HTTP: encrypted response detect + decrypt ───────────────────────────
    def response(self, flow):
        self._ensure_log()
        try:
            ctype = flow.response.headers.get("content-type", "")
            if "json" not in ctype and not flow.response.content.startswith(b"{"):
                return
            obj = json.loads(flow.response.content)
        except Exception:
            return
        if not looks_encrypted(obj):
            return

        self.seen += 1
        print(f"\n#{self.seen} HTTP ⬅ {flow.request.pretty_host}{flow.request.path}  "
              f"[ENCRYPTED RESPONSE]", flush=True)
        self._emit(flow, "HTTP-ENC", obj, False)
        if not (self.k and self.ak):
            print("   (keys nahi — YONO_P_K / YONO_P_AK set karke dobara chalao)", flush=True)
            return
        try:
            plain, notes = decrypt_response(obj, self.k, self.ak)
        except Exception as exc:
            print(f"   ✗ decrypt fail: {exc}", flush=True)
            return
        for n in notes:
            print(f"   {n}", flush=True)
        print(json.dumps(plain, ensure_ascii=False, indent=2, default=str), flush=True)
        self._emit(flow, "HTTP-ENC-DECRYPTED", plain, False)

    # ── WebSocket messages ──────────────────────────────────────────────────
    def websocket_message(self, flow):
        self._ensure_log()
        try:
            m = flow.websocket.messages[-1]
        except Exception:
            return
        if m.is_text:
            try:
                obj = json.loads(m.text)
            except Exception:
                print(f"[yono-proto] text frame: {m.text[:400]}", flush=True)
                return
            self._emit(flow, "text", obj, True)
            return

        raw = bytes(m.content)
        fr = DecodedFrame(raw)
        direction = "S→C" if m.from_client is False else "C→S"
        self.seen += 1
        print(f"\n#{self.seen} {direction} {flow.request.pretty_host}", flush=True)
        print(fr.describe(self.tbl), flush=True)

        rec = {
            "n": self.seen,
            "dir": direction,
            "host": flow.request.pretty_host,
            "path": flow.request.path,
            "ts": fr.timestamp,
            "cmd": fr.cmd(),
            "cmd_name": self.tbl.get(str(fr.cmd()), "") if fr.cmd() is not None else "",
            "checksum_ok": fr.checksum_ok,
            "error": fr.error,
            "msg": fr.obj if fr.obj is not None else fr.json_text,
            "raw_hex": raw.hex() if (fr.error or fr.obj is None) else None,
        }
        self._emit(flow, direction, rec, False)

    def _emit(self, flow, direction, payload, is_text):
        if self.log_fh is None:
            return
        self.log_fh.write(json.dumps({
            "dir": direction, "host": flow.request.pretty_host,
            "path": flow.request.path, "payload": payload, "is_text": is_text,
        }, ensure_ascii=False, default=str) + "\n")

    def done(self):
        try:
            self.log_fh.close()
        except Exception:
            pass


addons = [YonoProtoAddon()]


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────
def _hex_to_bytes(h: str) -> bytes:
    h = h.strip().replace(" ", "").replace("\n", "").replace("0x", "")
    if len(h) % 2:
        raise SystemExit("hex string ka length even nahi hai")
    return bytes.fromhex(h)


def self_test() -> int:
    print("── self-test: checksum ──")
    # reference values JS semantics se:  init 0xFFFF, poly 0x70B1
    assert src_sum(b"") == 0xFFFF, src_sum(b"")
    assert 0 <= src_sum(bytes(range(200))) <= 0xFFFF
    print(f"   srcSum(b'')                    = 0x{src_sum(b''):04X}")
    print(f"   srcSum(b'hello world')         = 0x{src_sum(b'hello world'):04X}")
    print(f"   srcSum(bytes(range(200)))      = 0x{src_sum(bytes(range(200))):04X}  (sirf pehle 128 byte)")

    print("── self-test: round-trip pack → decode ──")
    cases = [
        {"c": 11, "c_ts": 1700000000000, "c_idx": 7, "uid": 12345, "language": "in"},
        {"c": 1, "c_ts": 1700000000000, "c_idx": 1, "x": "deadbeef" * 4, "phone": "9999999999"},
        {"c": 100059, "c_ts": 1700000000000, "c_idx": 99},
        {"c": 44, "slot": "rummy", "bet": 10, "unicode": "\u0939\u093f\u0928\u094d\u0926\u0940 \U0001F600"},
    ]
    for case in cases:
        frame = pack_frame(case)
        fr = DecodedFrame(frame)
        assert fr.obj == case, (fr.obj, case)
        assert fr.checksum_ok, "checksum mismatch"
        assert fr.cmd() == case["c"], (fr.cmd(), case["c"])
        extra = f", cmd_name={load_msgid_table().get(str(case['c']), '-')}"
        print(f"   ✓ c={case['c']:<7} frame={len(frame):>4}B payload={fr.payload_len:>4}B "
              f"chk=0x{fr.checksum:04X}{extra}")

    print("── self-test: encrypted HTTP response round-trip ──")
    try:
        import os as _os
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        k = "K" * 32
        ak = "abcdefghijklmnopqrstuvwxyz012345"
        plain = {"code": 200, "coin": 123456, "c": 1, "note": "हिन्दी ✓"}
        iv = _os.urandom(12)
        ct = AESGCM(aes_key_bytes(ak)).encrypt(iv, json.dumps(plain, ensure_ascii=False).encode(), None)
        b64 = base64.b64encode(iv + ct).decode()
        ts = int(time.time())
        enc = {"data": b64, "timestamp": ts, "signature": hmac_sha256_hex(k, b64 + str(ts))}
        assert looks_encrypted(enc)
        back, notes = decrypt_response(enc, k, ak)
        assert back == plain, (back, plain)
        for n in notes:
            print(f"   • {n}")
        # tamper test — galat key se signature fail hona chahiye
        bad = dict(enc, signature=hmac_sha256_hex("W" * 32, b64 + str(ts)))
        try:
            decrypt_response(bad, k, ak)
            print("   ✗ tamper detection FAIL")
            return 1
        except ValueError:
            print("   ✓ tamper/galt-key detection kaam karta hai")
        print("   ✓ AES-256-GCM + HMAC-SHA256 round-trip PASS")
    except ImportError:
        print("   (skip — `cryptography` package nahi mila)")

    print("\n✅ self-test PASS — protocol + crypto implementation sahi hai")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Yono Rummy WebSocket protocol decoder / mitmproxy addon",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("--hex", metavar="HEX", action="append", default=[],
                    help="raw frame hex string (multiple baar de sakte ho)")
    ap.add_argument("--file", metavar="PATH", action="append", default=[],
                    help="hex dumps ki file (ek frame per line)")
    ap.add_argument("--pack", metavar="JSON", action="append", default=[],
                    help="JSON message → frame hex print karo")
    ap.add_argument("--self-test", action="store_true", help="checksum + roundtrip test")
    ap.add_argument("--msgid", metavar="PATH", help="msgid-table.json ka custom path")
    ap.add_argument("--decrypt-response", metavar="JSON", action="append", default=[],
                    help='encrypted HTTP response: {"data":..,"timestamp":..,"signature":..}')
    ap.add_argument("--decrypt-file", metavar="PATH", action="append", default=[],
                    help="encrypted response JSON ki file")
    ap.add_argument("--key-k", metavar="STR", help="HMAC key (ya env YONO_P_K)")
    ap.add_argument("--key-ak", metavar="STR", help="AES key (ya env YONO_P_AK)")
    ap.add_argument("--no-ttl-check", action="store_true", help="timestamp TTL check skip karo")
    ap.add_argument("--cent-sign", metavar="URL", help="CENT-SIGN compute karo (getUPHead)")
    ap.add_argument("--uid", type=int, default=0, help="--cent-sign ke liye uid")
    ap.add_argument("--ts", type=int, help="--cent-sign ke liye server time (default: ab)")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    k = args.key_k or os.environ.get("YONO_P_K") or None
    ak = args.key_ak or os.environ.get("YONO_P_AK") or None

    if args.cent_sign:
        ts = args.ts if args.ts is not None else int(time.time())
        print(f"url[:100]      = {args.cent_sign[:100]}")
        print(f"CENT-TIMESTAMP = {ts}")
        print(f"CENT-SIGN      = {cent_sign(args.cent_sign, args.uid, ts)}")
        return 0

    blobs = list(args.decrypt_response)
    for path in args.decrypt_file:
        with open(path, encoding="utf-8") as fh:
            blobs.append(fh.read())
    if blobs:
        rc = 0
        for i, raw in enumerate(blobs, 1):
            print(f"\n═══ encrypted response {i} ═══")
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError as exc:
                print(f"  ✗ JSON parse fail: {exc}")
                rc = 1
                continue
            if not looks_encrypted(obj):
                print("  (!) ye encrypted response shape nahi hai "
                      "(data:str + timestamp:num + signature:str chahiye)")
                print(json.dumps(obj, ensure_ascii=False, indent=2, default=str)[:1500])
                continue
            print(f"  data      : {len(obj['data'])} base64 chars")
            print(f"  timestamp : {obj['timestamp']}")
            print(f"  signature : {obj['signature'][:24]}… ({len(obj['signature'])} hex chars)")
            try:
                plain, notes = decrypt_response(obj, k, ak, check_ttl=not args.no_ttl_check)
            except Exception as exc:
                print(f"  ✗ {exc}")
                rc = 1
                continue
            for n in notes:
                print(f"  • {n}")
            print("  ── plaintext ──")
            print(json.dumps(plain, ensure_ascii=False, indent=2, default=str))
        return rc

    tbl = load_msgid_table([args.msgid] if args.msgid else None)

    if args.pack:
        for js in args.pack:
            frame = pack_frame(js)
            print(f"── frame ({len(frame)} bytes) ──")
            print(frame.hex(" "))
            print()
        return 0

    frames: list[bytes] = []
    for h in args.hex:
        frames.append(_hex_to_bytes(h))
    for path in args.file:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                try:
                    frames.append(_hex_to_bytes(line))
                except SystemExit as exc:
                    print(f"[skip] {path}: {exc} | {line[:60]}")

    if not frames:
        ap.print_help()
        print("\n(!) koi input nahi diya. --hex / --file / --pack / --self-test dekho.")
        return 1

    for i, raw in enumerate(frames, 1):
        fr = DecodedFrame(raw)
        print(f"\n═══ frame {i} ({len(raw)} bytes) ═══")
        print(fr.describe(tbl))
    return 0


if __name__ == "__main__":
    sys.exit(main())
