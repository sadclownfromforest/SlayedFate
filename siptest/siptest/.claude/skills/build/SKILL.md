---
name: build
description: Build the SIP test tool Docker image with make and fix compile errors or warnings. Use when asked to build, compile, rebuild, or after code changes.
---

# Build SIP Test

The project builds only inside Docker (`elixir:1.18-alpine`); there are no Hex dependencies.

1. From the project root run `make build` (= `docker build -t siptest .`).
2. If compilation fails, read the first error, fix the source under `lib/`, rebuild. Fix warnings too
   (unused variables/aliases, clauses that cannot match) - the code base is kept warning-free.
3. If `docker` cannot reach the daemon or the base image cannot be pulled, say so plainly and stop;
   do not try to install Elixir on the host.
4. After a successful build, optionally `make run` (Linux) or `make run-bridge` (Docker Desktop) and tell the
   user to open http://localhost:4100.

Never add Hex dependencies (`deps: []` in `mix.exs`). Do not commit or push - see the Git policy in CLAUDE.md.
