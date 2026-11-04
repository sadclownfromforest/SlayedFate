# SIP Phone (Elixir)

A browser-based SIP softphone written in Elixir (RFC 3261, UDP). The browser is the
handset (microphone + speakers over a WebSocket); the Elixir backend is the SIP user
agent and RTP endpoint. **No Hex dependencies** - it uses Elixir 1.18's built-in `JSON`
and a small hand-written HTTP/WebSocket server, so `docker build` only needs the base image.

## Run

```sh
make run          # Linux: host networking, UI at http://localhost:4000
make run-bridge   # Docker Desktop (macOS/Windows): published ports instead
make logs         # follow logs
make test         # ExUnit inside the image (incl. an end-to-end direct call)
make stop
```

Open <http://localhost:4000> (use `localhost`, not a LAN IP: microphone access requires a
secure context, and the server only answers `localhost`/`127.0.0.1` unless `ALLOWED_HOSTS` is set).

## Using it

* **Add account** (`+ Add`): name, username, password, registrar (`192.168.1.10:5060`).
  `Advanced...` opens a pop-up with auth username, SIP domain, outbound proxy, local SIP port,
  advertised address, expiry, codec, register on/off and auto-answer.
* **Several accounts** can be registered at once - each owns its own UDP port (auto-assigned from 5070).
  Choose which one to call from in **Call from**.
* **Direct calls**: leave the registrar empty (or ignore it) and dial `host:port` of any phone,
  e.g. `127.0.0.1:5071` - that is the other account's local port, or any softphone on another port.
  `sip:user@host:port` also works. An explicit port is always dialled directly, bypassing the PBX.
* Incoming calls ring in the UI (Answer / Decline). During a call: Mute, Keypad pop-up (RFC 4733 DTMF), Hang up.
* **SIP log** pop-up shows every SIP message sent/received.
* **Elixir log** pop-up shows the server's `Logger` output (last 500 lines, level and text filter, Copy). Passwords are redacted. Call setup, auth challenges and why a call ended are logged there.
* **Project files** pop-up: read-only browser for the project's own source (lib, priv, test, skills, Makefile, Dockerfile, README, CLAUDE.md).
  Private files (saved accounts, `.env*`, keys, `settings.local*`, `.git`, build output, names containing secret/password/token) are never listed or served.

### Asterisk (PJSIP) example

```ini
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0

[1001]
type=endpoint
context=default
disallow=all
allow=ulaw,alaw
auth=1001
aors=1001
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes

[1001]
type=auth
auth_type=userpass
username=1001
password=secret

[1001]
type=aor
max_contacts=1
```

Then in the UI: username `1001`, password `secret`, registrar `<asterisk-ip>:5060`.

## Networking notes

* `make run` uses `--network host`: SIP (UDP 5070+), RTP (UDP 40000-40039) and Asterisk on
  `localhost` all work without port mapping. The web UI binds to `127.0.0.1` only.
* `make run-bridge` publishes UDP 5070-5079 and 40000-40039. Set each account's
  **Advertised address** to your host's IP so the PBX can reach you; direct calls from
  inside a bridge network to the host need the host IP or `host.docker.internal`.
* Environment: `WEB_PORT`, `WEB_BIND`, `ALLOWED_HOSTS`, `RTP_PORT_MIN/MAX`, `SIPPHONE_DATA`.
* Accounts are stored in `/data/accounts.json` (Docker volume `sipphone-data`, mode 0600,
  **passwords in plain text**). The browser never receives stored passwords.

## What is implemented from RFC 3261

REGISTER with refresh and unregister, digest auth (MD5, qop=auth; 401/407), 423 handling;
INVITE/ACK/CANCEL/BYE as caller and callee; 180/183, early media, Record-Route/Route (loose routing);
client and server transactions with Timers A/B/D/E/F/G and 2xx retransmission until ACK;
`rport`/`received` (RFC 3581); OPTIONS and NOTIFY replies; re-INVITE answering (session refresh, hold);
SDP offer/answer (RFC 3264) with G.711 PCMU/PCMA and telephone-event.

Not implemented: TCP/TLS/SRTP, IPv6, SUBSCRIBE/REFER/transfer, outbound hold/re-INVITE, redirects (3xx),
SHA-256 digest, SIP over WebSocket.

## Layout

```
lib/sipphone/account.ex      SIP UA: registration, transactions, dialogs
lib/sipphone/sip/*.ex        message parser, digest, SDP
lib/sipphone/media.ex        RTP + G.711 + DTMF per call
lib/sipphone/g711.ex         codecs
lib/sipphone/accounts.ex     config store/validation/persistence
lib/sipphone/files.ex        read-only project file viewer backend (allowlist + denylist)
lib/sipphone/web/*.ex        HTTP + WebSocket server and browser session
CLAUDE.md, .claude/skills/   guidance and /build, /test skills for Claude Code
priv/static/                 UI (HTML/CSS/JS + AudioWorklet)
```
