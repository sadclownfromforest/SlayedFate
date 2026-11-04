---
name: build
description: Build the SIP phone Docker image with make and fix compile errors or warnings. Use when asked to build, compile, rebuild, or when code changed and the image must be refreshed.
---

# Build the SIP phone

The project builds only inside Docker (`elixir:1.18-alpine`); there are no Hex dependencies.

## Steps

1. From the project root run `make build` (equivalent to `docker build -t sipphone .`).
2. If compilation fails, read the first error in the output, fix the source under `lib/`, and rebuild.
   Fix warnings too (unused variables/aliases, unreachable clauses) - the code base is kept warning-free.
3. If `docker` cannot reach the daemon, say so plainly; do not try to install Elixir on the host.
4. If the base image cannot be pulled (network policy), report the blocked host and stop.
5. After a successful build, optionally start it with `make run` (Linux) or `make run-bridge`
   (Docker Desktop) and tell the user to open http://localhost:4000.

## Notes

* Never add Hex dependencies; keep `mix.exs` `deps: []`.
* Runtime knobs are environment variables: `WEB_PORT`, `WEB_BIND`, `ALLOWED_HOSTS`, `RTP_PORT_MIN/MAX`, `SIPPHONE_DATA`.
* Do not copy `data/`, `.env*`, keys, or `accounts.json` into the image (see `.dockerignore`).
* Report concisely: build succeeded/failed, and for failures the file, line and the fix.
