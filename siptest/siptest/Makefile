IMAGE    ?= siptest
NAME     ?= siptest
WEB_PORT ?= 4100

.DEFAULT_GOAL := help
.PHONY: help build run run-bridge stop logs shell test clean

help:
	@echo "make build       - build the Docker image"
	@echo "make run         - run with host networking (Linux; UI at http://localhost:$(WEB_PORT))"
	@echo "make run-bridge  - run with a published UI port (Docker Desktop on macOS/Windows)"
	@echo "make test        - run the ExUnit suite (uses a fake phone on localhost) inside the image"
	@echo "make logs | stop | shell | clean"

build:
	docker build -t $(IMAGE) .

# Host networking: 127.0.0.1:<port> in the UI means the host's own loopback, so you can test a phone
# (or the sipphone project) that runs on this machine.
run: build
	-@docker rm -f $(NAME) >/dev/null 2>&1
	docker run -d --init --name $(NAME) --network host \
		-e WEB_BIND=127.0.0.1 -e WEB_PORT=$(WEB_PORT) $(IMAGE)
	@echo "Open http://localhost:$(WEB_PORT)"

# Bridge networking: only the web UI is published (to 127.0.0.1). A phone on the host is reachable as
# host.docker.internal; the phone's replies come back over the same UDP flow.
run-bridge: build
	-@docker rm -f $(NAME) >/dev/null 2>&1
	docker run -d --init --name $(NAME) \
		--add-host=host.docker.internal:host-gateway \
		-p 127.0.0.1:$(WEB_PORT):4100 \
		-e WEB_BIND=0.0.0.0 -e WEB_PORT=4100 -e ALLOWED_HOSTS=host.docker.internal $(IMAGE)
	@echo "Open http://localhost:$(WEB_PORT)"

stop:
	-docker rm -f $(NAME)

logs:
	docker logs -f $(NAME)

test: build
	docker run --rm --init -e MIX_ENV=test -e SIPTEST_NO_WEB=1 $(IMAGE) mix test

shell: build
	docker run --rm -it $(IMAGE) sh

clean: stop
	-docker rmi $(IMAGE)
