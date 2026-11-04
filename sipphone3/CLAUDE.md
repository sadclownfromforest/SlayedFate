# SIP Phone (Elixir)

Browser-based SIP softphone. Elixir backend = SIP user agent (RFC 3261, UDP) + RTP/G.711 endpoint;
the browser is the handset (mic/speakers over a WebSocket). **Zero Hex dependencies** - keep it that way
(uses Elixir >= 1.18 built-in `JSON`, hand-written HTTP/WebSocket server).

## Commands (everything runs in Docker; Elixir is not required on the host)

```sh
make build        # docker build
make test         # ExUnit inside the image (unit tests + real localhost call between two accounts)
make run          # Linux, host networking, UI at http://localhost:4000
make run-bridge   # Docker Desktop (macOS/Windows), published ports
make logs | stop | shell | clean
```

Skills: `/build` and `/test` in `.claude/skills/`.

## Layout

```
lib/sipphone/account.ex     SIP UA per account (own UDP port): REGISTER+digest, INVITE/CANCEL/BYE,
                            client/server transactions, 2xx retransmit, dialogs
lib/sipphone/sip/           message.ex (parse/serialize), digest.ex, sdp.ex
lib/sipphone/media.ex       RTP session per call, G.711, RFC 4733 DTMF
lib/sipphone/g711.ex        codecs
lib/sipphone/accounts.ex    config store: validation, persistence (/data/accounts.json), process mgmt
lib/sipphone/files.ex       read-only project file viewer backend (allowlist + denylist)
lib/sipphone/log_buffer.ex  :logger handler -> last 500 Elixir log lines (secrets redacted) for the "Elixir log" panel
lib/sipphone/web/           server.ex (listener), conn.ex (HTTP, /ws upgrade), frame.ex (RFC 6455), session.ex (browser session/commands)
priv/static/                index.html, style.css, app.js, audio-worklet.js, favicon.svg
test/                       sip_test.exs (pure units), call_test.exs (end-to-end, ports 15060/15061)
```

Data flow: browser <-WebSocket(JSON text + binary PCM)-> `Web.Session` <-> `Account` (SIP) / `Media` (RTP).
UI events fan out through `SipPhone.Events` (Registry `SipPhone.Clients`).

## Conventions

* UI: cold palette (navy/ice/cyan) defined as CSS variables in `style.css`; simple main screen,
  advanced options live in `<dialog>` pop-ups. Build DOM with `textContent` / the `h()` helper - never `innerHTML`.
* Web server only answers `localhost`, `127.0.0.1`, `[::1]` (+ `ALLOWED_HOSTS`) and checks WebSocket `Origin`.
  Do not loosen this; it blocks DNS-rebinding / cross-site access to the phone and the SIP log.
* Audio on the wire to the browser: 8 kHz signed 16-bit little-endian mono PCM, 20 ms = 160 samples = 320 bytes.
* Keep SIP behaviour RFC 3261 compliant; cite section numbers in comments when adding transaction logic.
* Direct calls: a target with an explicit port (`host:port`, `sip:user@host:port`) bypasses the registrar/proxy.

## Privacy rules (important)

* `/data/accounts.json` holds SIP passwords in plain text. Never send passwords to the browser
  (`Accounts.build_views/1` strips them), never log them, never commit/zip them.
* The "Project files" panel is **read only** and served by `SipPhone.Files`: an allowlist of folders/extensions
  plus a denylist (env files, keys, accounts.json, data dir, .git, build output, settings.local, names containing
  secret/password/token...). If you add a new kind of file or folder, decide deliberately whether it may be shown;
  extend `test/files_test.exs` when changing the rules. Never make the viewer write files or accept free-form paths.
* The "Elixir log" panel shows `Logger` output via `SipPhone.LogBuffer`, which redacts `password/secret/token` values (crash reports
  print GenServer state). Never log passwords on purpose; extend `LogBuffer.redact/1` + its test if you add other secret names.
* Do not add the SIP log, Elixir log or file viewer to any non-localhost listener.

## Gotchas

* Each account needs a unique UDP port (default from 5070); RTP uses even ports in `RTP_PORT_MIN..MAX` (40000-40039).
* In bridge-network Docker, set the account's *Advertised address* to the host IP or the PBX cannot reach you.
* Microphone only works on a secure context: open the UI as `http://localhost:4000`, not a LAN IP.
* `call_test.exs` binds UDP 15060/15061 and RTP ports; do not run it concurrently with another copy.
* The project was authored without a compiler available; if `make test` fails, fix compile errors/warnings first.

## Not implemented

TCP/TLS/SRTP, IPv6, SUBSCRIBE/REFER/transfer, outbound hold, 3xx redirects, SHA-256 digest, SIP over WebSocket.

## Git policy (enforced by .claude/hooks/guard-git.sh)

* **Never push.** No `git push`, `gh pr create/merge`, remote-writing `gh api`, GitHub MCP writes, or scripts that do it.
  A hook blocks these; do not try to work around it (aliases, scripts, editing `.claude/` or `.git/hooks`).
  When work is ready, tell the user which branch/commits exist and let them push.
* **Always ask before committing.** Before any `git commit` (also merge, cherry-pick, revert, am, rebase, pull) call
  `AskUserQuestion` with the proposed commit message and the list of files, and commit only after an explicit yes.
  The hook additionally forces a permission prompt for these commands.
* Never commit secrets (`accounts.json`, `.env*`, keys). Stage files explicitly, not `git add -A`.
