# SIP Test (Elixir)

SIPp-like SIP test tool with a web UI. Elixir backend = SIP UAC engine (RFC 3261, UDP) that runs text scenarios
against a phone/server; the browser is only the control panel. **Zero Hex dependencies** - keep it that way
(Elixir >= 1.18 built-in `JSON`, hand-written HTTP/WebSocket server).

## Commands (everything runs in Docker; Elixir is not required on the host)

```sh
make build | test | run | run-bridge | logs | stop | shell | clean
```

`make test` needs no phone: engine tests use a fake UAS (`SipTest.FakeUas` in `test/engine_test.exs`).
Skills: `/build` and `/test` in `.claude/skills/`.

## Layout

```
lib/siptest/script.ex      scenario language parser (send/ack/auth/expect/expect-request/wait/assert-*)
lib/siptest/scenarios.ex   built-in catalog; every scenario is plain script text
lib/siptest/engine.ex      UAC engine; one UDP socket per scenario; state is a plain map threaded through steps
lib/siptest/suite.ex       GenServer: one run at a time, Task per run, :stop_run message for Stop
lib/siptest/params.ex      validation/defaults for UI parameters
lib/siptest/{message,digest,sdp}.ex   copied from the sibling sipphone project (keep behaviour in sync)
lib/siptest/web/           server.ex, conn.ex (HTTP, /ws upgrade), frame.ex (RFC 6455), session.ex (commands/events)
priv/static/               index.html, style.css, app.js
```

Data flow: browser <-WebSocket JSON-> `Web.Session` -> `Suite.run` -> Task -> `Engine.run` -> events via `SipTest.Events`
(Registry `SipTest.Clients`) -> every connected browser.

## Engine rules worth knowing

* `expect CODES [METHOD]` matches responses by CSeq method (default: method of the last request sent); unlisted 1xx are
  dropped, an unlisted final response is a failure. Responses are queued in `inbox`, so check order is free.
* Final non-2xx to INVITE are ACKed automatically (also when retransmitted); the 2xx ACK is the explicit `ack` step.
* `auth` is a no-op when the last response is not 401/407 and puts that response back for the next `expect`.
* Incoming requests from the phone are answered (BYE/OPTIONS/... 200, INVITE 488, CANCEL 481, others 501) and queued for `expect-request`.
* `cleanup/1` CANCELs a pending INVITE or BYEs an established call after a scenario, so the phone is left idle.
* Stop = message `:stop_run`; `pump/2` throws `{:stopped, st}` so cleanup still runs with the current state.

## Conventions

* Add scenarios to `Scenarios.all/0` as script text; `script_test.exs` checks that every one parses. Add an engine test with the fake UAS
  when behaviour (not just text) changes.
* UI: cold palette via CSS variables, simple main screen, advanced options in `<dialog>` pop-ups, DOM built with
  `textContent`/`h()` (never `innerHTML`).
* Web server answers only `localhost`/`127.0.0.1`/`[::1]` (+ `ALLOWED_HOSTS`) and checks the WebSocket `Origin`. Do not loosen.
* The auth password lives only in the request/run; never store or log it, never put it in the export.
* Tests bind loopback UDP on ephemeral ports only.

## Gotchas

* With `make run-bridge`, a phone on the host is `host.docker.internal`; `127.0.0.1` would be the container itself.
* Phones often answer to the source address, so keep the local UDP port stable per scenario (the engine does).
* The project was authored without a compiler available; if `make test` fails, fix compile errors/warnings first.

## Not implemented

TCP/TLS/SRTP, IPv6, RTP/media checks, SIP forking or UAS scenarios (the tool never answers INVITE), SHA-256 digest.

## Git policy (enforced by .claude/hooks/guard-git.sh)

* **Never push.** No `git push`, `gh pr create/merge`, remote-writing `gh api`, GitHub MCP writes, or scripts that do it.
  A hook blocks these; do not try to work around it (aliases, scripts, editing `.claude/` or `.git/hooks`).
  When work is ready, tell the user which branch/commits exist and let them push.
* **Always ask before committing.** Before any `git commit` (also merge, cherry-pick, revert, am, rebase, pull) call
  `AskUserQuestion` with the proposed commit message and the list of files, and commit only after an explicit yes.
  The hook additionally forces a permission prompt for these commands.
* Never commit secrets (`accounts.json`, `.env*`, keys). Stage files explicitly, not `git add -A`.
