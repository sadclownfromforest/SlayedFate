---
name: test
description: Run the SIP test tool's ExUnit suite in Docker with make test and diagnose failures. Use when asked to test or verify, and after editing the engine, script parser, scenarios, params or web code.
---

# Test SIP Test

1. Run `make test` from the project root (builds the image, then `mix test` with `SIPTEST_NO_WEB=1`).
2. Read failures from the top:
   * `script_test.exs` - parser, params, and "every built-in scenario parses" (fix the scenario text in `scenarios.ex`).
   * `engine_test.exs` - engine against `SipTest.FakeUas`: check `engine.ex` (expect matching, auto-ACK, auth, cleanup).
     Tests wait with `assert_receive`; the fake phone's notifications are asynchronous.
3. Fix the code (not the test) unless the test is wrong; re-run until green.
4. Manual check against a real phone: `make run`, open http://localhost:4100, enter the phone's IP and port,
   run *OPTIONS ping*; open the *SIP trace* pop-up to see the messages.

When adding a scenario, add it to `Scenarios.all/0` and, if it needs new engine behaviour, an engine test with the fake UAS.
Report concisely: tests passed/failed and, for failures, the test name and root cause.
