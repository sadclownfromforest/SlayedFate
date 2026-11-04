# MiniPBX - zero Hex dependencies, so the build only needs the base image.
# Elixir >= 1.18 is required (built-in JSON module).
FROM elixir:1.18-alpine

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    WEB_BIND=127.0.0.1 \
    WEB_PORT=4200 \
    SIP_PORT=5060 \
    DATA_DIR=/data

WORKDIR /app

COPY mix.exs Makefile Dockerfile README.md CLAUDE.md ./
COPY lib lib
COPY priv priv
COPY test test

RUN mix compile && mkdir -p /data

VOLUME /data
EXPOSE 4200 5060/udp

CMD ["mix", "run", "--no-halt"]
