# MiniPBX (Elixir)

A small Asterisk-like PBX with a web UI: registrar, calls between registered phones (B2BUA, direct media), CDR with
date/time, number rerouting and per-phone forwarding. **Zero Hex dependencies** - keep it that way
(Elixir >= 1.18 built-in `JSON`, hand-written HTTP/WebSocket server).

## Commands (everything runs in Docker; Elixir is not required on the host)

```sh
make build | test | run | run-bridge | logs | stop | shell | clean
```

Skills: `/build` and `/test` in `.claude/skills/`. UI: http://localhost:4200. SIP: udp/5060.

## Layout

```
lib/minipbx/transport.ex   single UDP socket; dispatch by method / Call-ID / Via branch (Registry MiniPbx.CallReg)
lib/minipbx/registrar.ex   REGISTER, ETS bindings {number => %{dest, contact, expires_at}}
lib/minipbx/auth.ex        digest (REGISTER = 401, INVITE = 407), ETS nonces and failure counters
lib/minipbx/call.ex        GenServer per call; state = map with legs :a (caller) and :b (callee)
lib/minipbx/dialplan.ex    pure: matches?/2, resolve/2
lib/minipbx/store.ex       GenServer + data/pbx.json (phones keep HA1 only), broadcasts "dirty" events
lib/minipbx/cdr.ex         GenServer + data/cdr.jsonl, csv/0
lib/minipbx/views.ex       snapshots pushed to the browser; web/session.ex handles commands
priv/static/               index.html, style.css, app.js
```

Data flow: browser <-WebSocket JSON-> `Web.Session` -> `Store`/`Registrar`/`Calls`/`Cdr`; changes call
`Events.broadcast(%{type: "dirty", what: area})` and each session pushes `Views.snapshot(area)` (areas: config, regs, calls, cdr).

## Call engine rules worth knowing

* Registry (unique keys) `MiniPbx.CallReg`: `{:call, call_id}` (both legs), `{:branch, b}` (our outgoing requests),
  `{:busy, number}` (atomic busy claim), `{:active, id}` (value = summary shown in the UI), `{:id, id}`.
* Responses are matched only by the top Via branch; our CANCEL reuses the INVITE branch, so `on_invite_resp` checks the CSeq method.
* Routing order: routes (first match) -> "always" forward -> busy claim -> registration lookup -> INVITE.
  busy / no answer / unreachable forwards re-enter `go_dial` (max 8 hops).
* Final responses to the caller are retransmitted until the ACK (`final_tx`); the INVITE to the callee is retransmitted until a response.
* `finish/3` writes the CDR once and releases claims; the process lingers a few seconds to absorb retransmissions.
* Registrations use the Contact port when the Contact host equals the source address, otherwise the source address (`Registrar.dest_for/2`).

## Conventions

* UI: cold palette via CSS variables, simple main screen, edit forms in `<dialog>` pop-ups, DOM built with
  `textContent`/`h()` (never `innerHTML`).
* Web server answers only `localhost`/`127.0.0.1`/`[::1]` (+ `ALLOWED_HOSTS`) and checks the WebSocket `Origin`. Do not loosen.
* Never store or log passwords; only HA1. CSV export neutralises formula cells. Do not define `match?/2` (Kernel clash).
* The project was authored without a compiler: if `make build`/`make test` fails, fix compile errors and warnings first.

## Not implemented

TCP/TLS/SRTP, IPv6, trunks, voicemail, REFER, multiple bindings per number, BYE retransmission, an end-to-end call test
(a good next step: two fake UDP phones against `MiniPbx.Transport.port()`).

## Git policy (enforced by .claude/hooks/guard-git.sh)

* **Never push.** No `git push`, `gh pr create/merge`, remote-writing `gh api`, GitHub MCP writes, or scripts that do it.
  A hook blocks these; do not try to work around it (aliases, scripts, editing `.claude/` or `.git/hooks`).
  When work is ready, tell the user which branch/commits exist and let them push.
* **Always ask before committing.** Before any `git commit` (also merge, cherry-pick, revert, am, rebase, pull) call
  `AskUserQuestion` with the proposed commit message and the list of files, and commit only after an explicit yes.
  The hook additionally forces a permission prompt for these commands.
* Never commit secrets (`accounts.json`, `.env*`, keys). Stage files explicitly, not `git add -A`.
