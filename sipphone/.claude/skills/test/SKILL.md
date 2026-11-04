---
name: test
description: Run the SIP phone ExUnit suite in Docker with make test and diagnose failures. Use when asked to test, verify, check a change, or after editing SIP, media, accounts, files or web code.
---

# Test the SIP phone

## Steps

1. From the project root run `make test`. It builds the image, then runs `mix test` in a throwaway container
   with `SIPPHONE_NO_WEB=1` (no web listener) and a temporary data dir.
2. Read failures from the top. Typical causes:
   * `sip_test.exs` - parser, digest (RFC 2617 vector), SDP, G.711 units: a logic bug in `lib/sipphone/sip/*` or `g711.ex`.
   * `call_test.exs` - end-to-end INVITE/180/200/ACK/BYE/CANCEL/603 between two accounts on UDP 15060/15061:
     inspect `lib/sipphone/account.ex` (transactions, dialogs) and `media.ex` (RTP port allocation).
   * `files_test.exs` - the project file viewer's privacy rules; never weaken a rule to make a test pass.
3. Fix the code (not the test) unless the test itself is wrong, then re-run `make test` until green.
4. For manual checks use `make run`, open http://localhost:4000, create two accounts without a registrar and call
   `127.0.0.1:<other account port>`; the "SIP log" pop-up shows the exchanged messages.

## When adding behaviour

* Add a unit test for pure logic (parsing, digest, SDP, validation) and an end-to-end case in `call_test.exs`
  for call-flow changes.
* Tests that open sockets must use ports outside 5070-5079 and 40000-40039.
* Report concisely: number of tests passed/failed, and for failures the test name and root cause.
