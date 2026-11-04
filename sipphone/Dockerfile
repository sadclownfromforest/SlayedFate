# SIP phone - zero Hex dependencies, so the build only needs the base image.
# Elixir >= 1.18 is required (built-in JSON module).
FROM elixir:1.18-alpine

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    WEB_BIND=127.0.0.1 \
    WEB_PORT=4000 \
    SIPPHONE_DATA=/data \
    RTP_PORT_MIN=40000 \
    RTP_PORT_MAX=40039

WORKDIR /app

COPY mix.exs Makefile Dockerfile README.md CLAUDE.md ./
COPY lib lib
COPY priv priv
COPY test test
COPY .claude/skills .claude/skills

RUN mix compile

VOLUME /data
EXPOSE 4000

CMD ["mix", "run", "--no-halt"]
