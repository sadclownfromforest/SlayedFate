IMAGE    ?= sipphone
NAME     ?= sipphone
WEB_PORT ?= 4000

.DEFAULT_GOAL := help
.PHONY: help build run run-bridge stop logs shell test clean

help:
	@echo "make build       - build the Docker image"
	@echo "make run         - run with host networking (Linux; web UI on http://localhost:$(WEB_PORT))"
	@echo "make run-bridge  - run with published ports (Docker Desktop on macOS/Windows)"
	@echo "make logs        - follow container logs"
	@echo "make stop        - stop and remove the container"
	@echo "make test        - run the ExUnit suite inside the image"
	@echo "make shell       - open a shell in the image"
	@echo "make clean       - remove container, image and saved accounts volume"

build:
	docker build -t $(IMAGE) .

# Host networking: the SIP/RTP sockets live directly on the host, so Asterisk on
# localhost or the LAN and "direct calls" to other phones on localhost just work.
run: build
	-@docker rm -f $(NAME) >/dev/null 2>&1
	docker run -d --init --name $(NAME) --network host \
		-e WEB_BIND=127.0.0.1 -e WEB_PORT=$(WEB_PORT) \
		-v sipphone-data:/data $(IMAGE)
	@echo "Open http://localhost:$(WEB_PORT)"

# Bridge networking: only the web UI is bound to 127.0.0.1; SIP ports 5070-5079
# and RTP ports 40000-40039 are published. Set the account's "Advertised
# address" to your host IP, and use host.docker.internal / host IP to reach
# services on the host.
run-bridge: build
	-@docker rm -f $(NAME) >/dev/null 2>&1
	docker run -d --init --name $(NAME) \
		-p 127.0.0.1:$(WEB_PORT):4000 \
		-p 5070-5079:5070-5079/udp \
		-p 40000-40039:40000-40039/udp \
		-e WEB_BIND=0.0.0.0 -e WEB_PORT=4000 \
		-e ALLOWED_HOSTS=host.docker.internal \
		-v sipphone-data:/data $(IMAGE)
	@echo "Open http://localhost:$(WEB_PORT)"

stop:
	-docker rm -f $(NAME)

logs:
	docker logs -f $(NAME)

test: build
	docker run --rm --init -e MIX_ENV=test -e SIPPHONE_NO_WEB=1 \
		-e SIPPHONE_DATA=/tmp/sipphone-test $(IMAGE) mix test

shell: build
	docker run --rm -it $(IMAGE) sh

clean: stop
	-docker rmi $(IMAGE)
	-docker volume rm sipphone-data
