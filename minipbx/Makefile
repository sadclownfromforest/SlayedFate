IMAGE    ?= minipbx
NAME     ?= minipbx
WEB_PORT ?= 4200
SIP_PORT ?= 5060
VOLUME   ?= minipbx-data

.DEFAULT_GOAL := help
.PHONY: help build run run-bridge stop logs shell test clean

help:
	@echo "make build       - build the Docker image"
	@echo "make run         - run with host networking (Linux): UI http://localhost:$(WEB_PORT), SIP udp/$(SIP_PORT)"
	@echo "make run-bridge  - run with published ports (Docker Desktop): UI on localhost, SIP udp/$(SIP_PORT) on all interfaces"
	@echo "make test        - run the ExUnit suite inside the image"
	@echo "make logs | stop | shell | clean   (data lives in the Docker volume '$(VOLUME)')"

build:
	docker build -t $(IMAGE) .

# Host networking: phones on the LAN (or on this machine) register at <this machine's IP>:$(SIP_PORT).
run: build
	-@docker rm -f $(NAME) >/dev/null 2>&1
	docker run -d --init --name $(NAME) --network host -v $(VOLUME):/data \
		-e WEB_BIND=127.0.0.1 -e WEB_PORT=$(WEB_PORT) -e SIP_PORT=$(SIP_PORT) $(IMAGE)
	@echo "Open http://localhost:$(WEB_PORT)"

# Bridge networking: the UI is published to 127.0.0.1 only; SIP is published on udp/$(SIP_PORT).
# Set "Address phones use to reach the PBX" in Settings to your host's IP (media is phone-to-phone).
run-bridge: build
	-@docker rm -f $(NAME) >/dev/null 2>&1
	docker run -d --init --name $(NAME) -v $(VOLUME):/data \
		-p 127.0.0.1:$(WEB_PORT):4200 -p $(SIP_PORT):5060/udp \
		-e WEB_BIND=0.0.0.0 -e WEB_PORT=4200 -e SIP_PORT=5060 $(IMAGE)
	@echo "Open http://localhost:$(WEB_PORT)"

stop:
	-docker rm -f $(NAME)

logs:
	docker logs -f $(NAME)

test: build
	docker run --rm --init -e MIX_ENV=test -e MINIPBX_NO_WEB=1 -e SIP_PORT=0 -e SIP_BIND=127.0.0.1 \
		-e DATA_DIR=/tmp/minipbx-test $(IMAGE) mix test

shell: build
	docker run --rm -it -v $(VOLUME):/data $(IMAGE) sh

clean: stop
	-docker rmi $(IMAGE)
	@echo "The data volume '$(VOLUME)' is kept; remove it with: docker volume rm $(VOLUME)"
