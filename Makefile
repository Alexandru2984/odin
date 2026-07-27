ODIN    ?= odin
OUT     := bin/webos_server
SRC     := src
SERVICE := webos

# Release flags. Bounds checking and asserts are deliberately left enabled
# (both are on by default): this is a network-facing server parsing attacker
# controlled frames, where a bounds panic is a crash but an unchecked overflow
# is a memory-corruption bug.
RELEASE_FLAGS := -o:speed -vet -strict-style
DEBUG_FLAGS   := -o:none -debug -vet -strict-style

.PHONY: all build debug run test check clean install-service deploy fmt

all: build

build:
	@mkdir -p bin
	$(ODIN) build $(SRC) -out:$(OUT) $(RELEASE_FLAGS)
	@echo "built $(OUT)"

debug:
	@mkdir -p bin
	$(ODIN) build $(SRC) -out:$(OUT) $(DEBUG_FLAGS)

# Type-check without emitting a binary.
check:
	$(ODIN) check $(SRC) -vet -strict-style

test:
	$(ODIN) test $(SRC)

run: build
	./$(OUT)

clean:
	rm -rf bin

# Install/refresh the systemd unit and nginx vhost from deploy/.
install-service:
	sudo cp deploy/webos.service /etc/systemd/system/webos.service
	sudo cp deploy/security-headers-webos.conf /etc/nginx/snippets/security-headers-webos.conf
	sudo cp deploy/webos-rate-limit.conf /etc/nginx/conf.d/webos-rate-limit.conf
	sudo cp deploy/nginx-webos.conf /etc/nginx/sites-available/webos
	sudo nginx -t
	sudo systemctl daemon-reload
	sudo systemctl reload nginx
	@echo "service files installed"

# Build, then swap the binary and restart. Keeps a rollback copy.
deploy: build test
	@cp -f $(OUT) bin/webos_server.prev 2>/dev/null || true
	sudo systemctl restart $(SERVICE)
	@sleep 1
	@systemctl is-active --quiet $(SERVICE) && echo "deployed: $(SERVICE) active" || (echo "DEPLOY FAILED"; sudo journalctl -u $(SERVICE) -n 30 --no-pager; exit 1)
