IMAGE ?= ghcr.io/hexlet-codebattle/runner-zig
TAG ?= latest
PLATFORMS ?= linux/amd64,linux/arm64
CONTAINER ?= docker
TEST_IMAGE ?= runner-zig-test

.PHONY: build lint lint-fix test test-unit test-integration container-build container-push container-start curl-local-health curl-local-test start

## Build multi-arch image directly for GHCR
build:
	zig build

## Run Zig formatting check
lint:
	zig fmt --check src

## Fix Zig code styling
lint-fix:
	zig fmt src

## fake check
test:
	ls -la

## Run integration tests inside the builder container
test-unit:
	zig test src/test.zig

## Stress the server with 10K real /run requests and assert RSS doesn't grow.
## Builds ReleaseSafe so we measure real allocator behavior, not DebugAllocator hold-back.
## Tight default budget (1 KB/req) catches anything but the smallest steady leak.
test-leak:
	zig build -Doptimize=ReleaseSafe
	RUNNER_RSS_BULK=10000 RUNNER_RSS_MAX_KB_PER_REQ=1 RUNNER_RSS_MIN_FLOOR_KB=1024 \
		zig build test --summary all

## Run integration tests against an already-built container (container + HTTP checks)
test-integration:
	@container_name="runner-zig-it-$$RANDOM"; \
	container_started=0; \
	trap 'if [ $$container_started -eq 1 ]; then $(CONTAINER) stop $$container_name >/dev/null 2>&1 || true; fi' EXIT; \
	$(CONTAINER) run -d --rm --pull=never --name $$container_name -p 4040:4040 \
		--cap-add=SYS_ADMIN \
		--cap-add=SYS_CHROOT \
		--security-opt=no-new-privileges=false \
		-e DEBUG=true \
		$(IMAGE):$(TAG) >/dev/null && \
	container_started=1; \
	for i in 1 2 3 4 5; do \
		if $(MAKE) --no-print-directory curl-local-health >/dev/null; then break; fi; \
		sleep 1; \
	done; \
	$(MAKE) --no-print-directory curl-local-health && \
	seq 1 60 | xargs -n1 -P60 sh -c 'curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:4040/run -H "content-type: application/json" -d @test-payload.json' | sort | uniq -c; \
	echo "---- container logs (tail) ----"; \
	$(CONTAINER) logs --tail 80 $$container_name 2>&1 | tail -80; \
	if [ $$container_started -eq 1 ]; then $(CONTAINER) stop $$container_name >/dev/null 2>&1 || true; fi

## Build and push multi-arch image (linux/amd64 + linux/arm64) for GHCR
build-and-push: container-build container-push

## Build a single-arch image for local use/tests
container-build:
	$(CONTAINER) build \
		--file Containerfile \
		--tag $(IMAGE):$(TAG) \
		.

## Pull the multi-arch manifest tag from registry
container-pull:
	$(CONTAINER) pull $(IMAGE):$(TAG)

## Push multi-arch image manifest + all platform layers to GHCR
container-push:
	$(CONTAINER) buildx build --push \
		--platform=linux/amd64,linux/arm64 \
		--file Containerfile \
		--tag $(IMAGE):$(TAG) \
		.

## Start the container locally on port 4040
container-start:
	$(CONTAINER) run --rm -p 4040:4040 \
		--cap-add=SYS_ADMIN \
		--cap-add=SYS_CHROOT \
		--security-opt=no-new-privileges=false \
		$(IMAGE):$(TAG)

## Quick local smoke check against the running server
curl-local-health:
	@curl -fsS http://localhost:4040/health && echo

## Run a local /run request for zig
curl-local-test:
	@curl -sS http://localhost:4040/run \
		-H 'content-type: application/json' \
		-d @test-payload.json

## Start the server from the local build output
start:
	./zig-out/bin/runner-zig
