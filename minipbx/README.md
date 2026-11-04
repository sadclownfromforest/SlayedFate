# MiniPBX (Elixir) - a small Asterisk-like PBX with a web UI

Phones register, call each other through the PBX, and every call is written to a call log (CDR) with date and time.
Numbers can be rerouted to other numbers and each phone can forward calls. Pure Elixir 1.18, **no Hex dependencies**,
runs in Docker. SIP (RFC 3261) over UDP.

## Run

```sh
make test         # ExUnit inside the image
make run          # Linux: host networking, UI http://localhost:4200, SIP on udp/5060
make run-bridge   # Docker Desktop (macOS/Windows): published ports; set "Address phones use to reach the PBX" in Settings
make logs | stop | shell | clean
```

Data (phones, routes, settings, call log) is kept in the Docker volume `minipbx-data` (`/data`).

## Use it

1. Open http://localhost:4200, press **Add** under *Phones*: number (the user name), name, password.
2. In a softphone (e.g. the sibling `sipphone` project, Zoiper, Linphone) register with server = the *SIP address* shown at the
   top (`ip:5060`), user name = the number, the same password. The dot next to the phone turns green.
3. Call another registered number: it rings, and when answered the media flows directly between the phones.
4. **Call log** lists every call: date/time (your local time), caller, dialed number, phone that rang, result
   (ANSWERED / NO ANSWER / BUSY / FAILED), talk time and the reason. Filter, **Export CSV**, **Clear**.
5. **Reroute numbers**: "when the dialed number matches X call Y instead". Order matters (first match wins, use the arrows).
   Patterns: `100`, `_1XX` (X = 0-9, Z = 1-9, N = 2-9), `_9.` (anything after the 9); `${EXTEN}` in the target = the dialed number.
6. **Phone > Edit > Call forwarding**: always, when busy, no answer (after the ring time in Settings), not registered.
7. **Live calls** shows calls in progress; **Hang up** ends one.

## How it works

A call is a back-to-back user agent: the caller's INVITE is answered by the PBX, the number is resolved
(routes, then "always" forward), then the PBX sends its own INVITE to the callee's registered address and relays
180/183/200, ACK, BYE, CANCEL and re-INVITE (hold/resume). SDP is passed through unchanged. A phone that is in a call or being
rung is *busy*. When the call ends one CDR record is written (`data/cdr.jsonl`).

* Passwords are never stored, only the digest HA1 (`MD5(number:realm:password)`) in `data/pbx.json` (mode 600).
* REGISTER and INVITE use digest authentication (MD5, qop=auth) with server-made nonces; 10 failed attempts from one address
  block it for 5 minutes. Unknown numbers get the same answers as known ones. "Require a password to place calls" can be switched off in Settings.
* The web UI binds to `127.0.0.1`, answers only `localhost`/`127.0.0.1`/`[::1]` (+ `ALLOWED_HOSTS`) and checks the WebSocket `Origin`.
  The SIP port listens on all interfaces: only expose it to a network you trust.
* Environment: `WEB_PORT` (4200), `WEB_BIND` (127.0.0.1), `SIP_PORT` (5060, `0` = random), `SIP_BIND` (0.0.0.0),
  `DATA_DIR` (`data`), `ALLOWED_HOSTS`, `MINIPBX_NO_WEB=1`.

## Not implemented

TCP/TLS/SRTP, IPv6, trunks or calls to outside numbers, voicemail, conferences, transfers (REFER), multiple registrations per number
(the latest wins), retransmission of our BYE, media handling (no RTP through the PBX, so phones behind different NATs need
to reach each other directly), SHA-256 digest.

## Layout

```
lib/minipbx/transport.ex   the UDP socket; routes REGISTER / new INVITE / in-dialog messages / responses
lib/minipbx/registrar.ex   REGISTER (RFC 3261 s.10), bindings in ETS with expiry
lib/minipbx/auth.ex        digest challenge/verify, nonces, brute-force limit
lib/minipbx/call.ex        one process per call (B2BUA): routing, forwarding, ringing, relaying, CDR
lib/minipbx/dialplan.ex    pure number patterns and route resolution
lib/minipbx/store.ex       phones, routes, settings (JSON file)
lib/minipbx/cdr.ex         call log, CSV export
lib/minipbx/{message,digest}.ex   SIP message and digest (shared with the sibling projects)
lib/minipbx/web/           HTTP + WebSocket server and browser session; views.ex = JSON snapshots
priv/static/               UI
test/                      dial plan, digest/auth and CDR tests
.claude/                   skills (/build, /test) and the git guard hook
```

## Status

Written without a compiler available: the first `make build` may report a few compile errors/warnings to fix.
There is no automated end-to-end call test yet (see `.claude/skills/test`).
