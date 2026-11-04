---
name: test
description: Run the MiniPBX ExUnit suite in Docker with make test and diagnose failures. Use when asked to test or verify, and after editing the dial plan, auth, store, CDR, registrar or call engine.
---

# Test MiniPBX

1. Run `make test` from the project root (builds the image, then `mix test` with the web UI off, SIP on an
   ephemeral loopback port and a throw-away `DATA_DIR`).
2. Read failures from the top:
   * `dialplan_test.exs` - pattern matching and route resolution (`dialplan.ex`), digest/auth helpers (`digest.ex`, `auth.ex`),
     CDR list/CSV (`cdr.ex`).
3. Fix the code (not the test) unless the test is wrong; re-run until green.
4. There is no automated end-to-end call test yet. Check calls by hand: `make run`, open http://localhost:4200, add two
   phones, register two softphones (e.g. the sibling `sipphone` project), call, and look at *Call log*.
   A good first end-to-end test would use two fake UDP phones against `MiniPbx.Transport.port()`.

Report concisely: tests passed/failed and, for failures, the test name and root cause.
