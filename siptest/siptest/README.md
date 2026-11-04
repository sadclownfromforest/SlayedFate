# SIP Test (Elixir) - a SIPp-like test tool with a web UI

Point it at a phone or a SIP server (IP + port), pick scenarios, press **Run**. It acts as a SIP user agent client
(RFC 3261, UDP), sends real requests and checks the answers - REGISTER and expect 200, INVITE and expect ringing,
reaction to CANCEL and BYE, error handling and more. Pure Elixir 1.18, **no Hex dependencies**, runs in Docker.

## Run

```sh
make test         # ExUnit inside the image (uses a fake phone on localhost)
make run          # Linux: host networking, UI at http://localhost:4100
make run-bridge   # Docker Desktop (macOS/Windows): published UI port, phone on the host = host.docker.internal
make logs | stop | shell | clean
```

Test the sibling `sipphone` project: run it (`make run` there), create an account without registrar (UDP port 5070),
then in SIP Test use host `127.0.0.1`, port `5070`, and run the *Phone / SIP endpoint* scenarios.

## UI

* **Target**: phone/server IP and port (`127.0.0.1:5070` in the IP field also works), and the called user.
* **Advanced...** (pop-up): our From user/display name, SIP domain, auth user and password, local UDP port,
  our address for Via/Contact, RTP port advertised in the SDP, response and ringing timeouts.
  The password is never stored; the other settings are remembered in the browser.
* **Scenarios**: tick what to run. **Script** opens a pop-up with the scenario text - edit it and **Run this script**
  to try your own variation.
* **Results**: per scenario PASS/FAIL, every step with detail and timing, the failing step with the reason.
* **SIP trace** (pop-up): every message sent/received, filterable per scenario. **Export JSON** saves the report.

Scenarios that make a real phone ring (calls) need a human: *Answered call* wants you to pick up within the ringing
timeout, *Rejected call* wants you to decline, *Phone hangs up* wants you to answer and then hang up within 60 s.
Cancel, unknown-user, bad-SDP, OPTIONS and BYE tests need nobody. Whatever happens, a scenario that ends with a ringing or
established call CANCELs / BYEs it so the phone is left idle.

## Built-in scenarios

| Group | Scenario | Checks |
|---|---|---|
| Phone | OPTIONS ping | 200 and `Allow` has INVITE |
| Phone | Max-Forwards: 0 | 483 (RFC 3261 16.3) |
| Phone | Unknown method | 501/405 (8.2.1) |
| Phone | BYE outside a dialog | 481 (15.1.2) |
| Phone | INVITE to unknown user | 404/480/484/603 |
| Phone | INVITE with broken SDP | 400/488/606 |
| Phone | INVITE, ringing, CANCEL | 180/183, then 200 for CANCEL and 487 for INVITE |
| Phone | Answered call, then BYE | 200 with SDP, ACK, BYE -> 200 |
| Phone | Rejected call | final 480/486/487/600/603 |
| Phone | Phone hangs up | BYE from the phone is received and answered |
| Registrar/PBX | REGISTER with digest auth | 401/407 challenge answered, then 200 |
| Registrar/PBX | REGISTER wrong password | rejected again |
| Registrar/PBX | REGISTER then unregister | `Expires: 0` accepted |
| Registrar/PBX | Authenticated call, CANCEL | challenge answered, ringing, CANCEL |

## Scenario language

Scenarios are plain text, one command per line (`#` = comment):

```
send METHOD [expires=N] [max-forwards=N] [to=USER] [sdp=none|bad] [dialog]
ack                          # 2xx of the last INVITE (non-2xx are ACKed automatically)
auth [wrong]                 # answer the last 401/407 with digest credentials; no-op if not challenged
expect 180 183 [METHOD] [timeout=MS|ring]    # wait for a response; other 1xx are skipped
expect-request BYE [timeout=MS|ring]         # a request sent by the phone (answered with 200)
wait MS
assert-header allow contains INVITE
assert-body contains m=audio
```

Example - "phone rings, then CANCEL":

```
send INVITE
expect 180 183 timeout=ring
send CANCEL
expect 200 CANCEL
expect 487 INVITE
```

`expect CODES [METHOD]` matches responses to the last request sent unless METHOD names another one, so the 200 for
CANCEL and the 487 for INVITE can be checked in either order. A mismatching final response fails the step at once
("expected 200 to OPTIONS, got 500 Server Error"); silence fails with a timeout and lists what *was* received.

## Notes

* UDP only; IPv4 only. Digest MD5 (qop=auth). No TLS/TCP/SRTP, no media - SDP is advertised but no RTP is sent or checked.
* One run at a time; **Stop** ends the current scenario cleanly (CANCEL/BYE) and skips the rest.
* The UI binds to `127.0.0.1` and only answers `localhost`/`127.0.0.1`/`[::1]` (+ `ALLOWED_HOSTS`); WebSocket origin is checked.
* Environment: `WEB_PORT` (4100), `WEB_BIND` (127.0.0.1), `ALLOWED_HOSTS`.

## Layout

```
lib/siptest/script.ex      scenario language parser
lib/siptest/scenarios.ex   built-in catalog (plain script text)
lib/siptest/engine.ex      UAC engine: send/expect/auth/ack, auto-ACK, answers phone requests, cleanup
lib/siptest/suite.ex       runs scenarios one by one, broadcasts events
lib/siptest/params.ex      validation of the UI parameters
lib/siptest/message.ex, digest.ex, sdp.ex   SIP message, digest auth, SDP
lib/siptest/web/           HTTP + WebSocket server and browser session
priv/static/               UI
test/                      parser, params, and engine tests against a fake phone
.claude/                   skills (/build, /test) and the git guard hook
```
