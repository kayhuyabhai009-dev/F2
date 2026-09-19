# Yono Rummy — WebSocket protocol note (reverse-engineered)

Ye note is app ke apne client code se protocol samajhne ke liye hai (owner-side analysis).
Decoder: [`yono-proto.py`](yono-proto.py) — `python3 tools/yono-proto.py --self-test`.

> **Koi key/secret is file me nahi hai.** Actual keys/endpoints `work/PROTOCOL-LOCAL.md`
> me hain (wo `work/` gitignore me hai, public repo me kabhi nahi jaata).
> Tools keys environment variables se lete hain: `YONO_P_K`, `YONO_P_AK`.

---

## 1. Transport

| kya | value |
|---|---|
| Connection | `ws://<server>/ws` (address me `:` na ho to `wss://`) |
| Android + wss | client `resources/common/cert.pem` use karta hai |
| Message type | **binary** (WebSocket) |
| Encoding | 8-byte header + **msgpack** payload |
| Heartbeat | cmd `11`, interval ~5 s, timeout ~4 s |
| Auto-reconnect | 4 s delay, max 3 try |

## 2. Frame format

```
offset  size  field         endian  matlab
------  ----  ------------  ------  --------------------------------------------
0       2     payload_len   BE u16  msgpack payload ka byte length
2       2     checksum      BE u16  srcSum(payload ke pehle min(len,128) byte)
4       4     timestamp     BE u32  client clock (seconds)
8       N     payload               msgpack-encoded STRING (andar JSON)
```

**Checksum algorithm** (JS `Global.srcSum`):

```
acc = 0xFFFF
for each byte b in payload[:128]:
    acc ^= b
    acc = (acc >> 1) if (acc & 1) == 0 else ((acc >> 1) ^ 0x70B1)
    acc &= 0xFFFF
```

**Payload** = `msgpack(JSON.stringify(msgObject))` → msgpack ka ek **string** object,
jiske andar JSON text hota hai (`0xa0|len` fixstr, `0xd9` str8, `0xda` str16, `0xdb` str32).

## 3. Message object

Client → server:

| field | type | matlab |
|---|---|---|
| `c` | int | command id (neeche table) |
| `c_ts` | int | client timestamp (ms) |
| `c_idx` | int | incrementing sequence (`_idx++`) |
| `uid` | int | player id (login ke baad) |
| `language` | str | `en` / `in` |
| `x` | hex str | **sirf LOGIN (`c=1`)** me: `md5( str(c_ts) + <client salt> )` |
| *(game fields)* | — | us command ke apne params (bet, room id, etc.) |

Server → client: wahi envelope, `c` = respond karta command id, `code` = status
(`200` = OK; `2e4`/20000 bhi success maana jaata hai; `415` re-login, `500` network error,
`801` update required, `803` maintenance, `931`/`203` re-login).

## 4. Command table (MsgId)

~**670 commands** hain — `HEARTBEAT=11`, `LOGIN=1`, `LOGIN_USERID=2`, `SLOT_START=44`,
`GAME_JOINROOM=32`, `REQ_ENTER_SAFE=100`…`BANK_TAKE_INGAME=107`, `GET_JACKPOT=276`,
`REQ_WITHDRAWAL=137`, `YD_RUMMY_* 25707–29206`, notification range `100050+`.

Table decoder khud dhoondh leta hai (repo me **nahi** commit ki gayi):
`work/decrypted/msgid-table.json` (`by_name`, `by_cmd`). Iske bina decoder sirf
numeric cmd dikhata hai.

## 5. HTTP API

| kya | value |
|---|---|
| Base URL | app ke config me (obfuscated) — `work/PROTOCOL-LOCAL.md` |
| Endpoints | `/start`, `/point`, `/report`, `/gamerule` (reports/statistics) |
| Auth headers | `CENT-TIMESTAMP` = server time (s) |
| | `CENT-SIGN` = `md5( url[:100] + CENT-TIMESTAMP + uid )` |

```
python3 tools/yono-proto.py --cent-sign 'http://host/path' --uid 12345 --ts 1700000000
```

## 6. Encrypted HTTP responses

Kuch responses plain JSON ki jagah ye shape me aate hain:

```json
{"data": "<base64>", "timestamp": 1700000000, "signature": "<hex>"}
```

Client (`charge/response-decrypt` module) ye karta hai:

1. `abs(now - timestamp) <= 300` (TTL 300 s)
2. `signature == HMAC_SHA256(key = P_K, msg = data + str(timestamp))` → hex
3. `base64decode(data)` = `IV(12 byte) || AES-GCM(ciphertext + tag)`
   AES key = `P_AK` ke **Latin-1 bytes** (32-char string ⇒ AES-256)

Decoder ye sab verify + decrypt karta hai (`cryptography` package chahiye):

```
export YONO_P_K='<32-char hmac key>'
export YONO_P_AK='<32-char aes key>'
python3 tools/yono-proto.py --decrypt-response '{"data":"...","timestamp":123,"signature":"..."}'
```

## 7. Live capture ke saath use

```
# terminal 1 — decoder addon ke saath proxy
source /home/user/tools/env.sh           # ya: source tools/env.sh
export YONO_P_K='...' YONO_P_AK='...'
mitmdump -s tools/yono-proto.py --listen-port 8080

# terminal 2 — phone traffic proxy pe bhejo
bash tools/capture.sh adb-proxy           # ya: bash tools/capture.sh wifi
```

Har WS frame terminal pe decoded dikhega (cmd name + JSON), aur
`work/traffic/yono-<timestamp>.jsonl` me bhi save hoga. Encrypted HTTP responses
app ke apne scheme se verify hoke auto-decrypt honge.

## 8. Self-test

```
python3 tools/yono-proto.py --self-test
```

Ye checksum, frame round-trip, aur (AES-GCM + HMAC) response crypto ka round-trip
verify karta hai — sab pass hone chahiye.
