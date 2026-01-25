IMAGE ?= ghcr.io/hexlet-codebattle/runner-zig
TAG ?= latest
PLATFORMS ?= linux/amd64,linux/arm64
CONTAINER ?= docker
TEST_IMAGE ?= runner-zig-test

.PHONY: build lint lint-fix test test-container test-integration test-integration-arm test-integration-linux container-build container-push curl-local-health curl-local-test start

## Build multi-arch image directly for GHCR
build:
	zig build

## Run Zig formatting check
lint:
	zig fmt --check src

## Fix Zig code styling
lint-fix:
	zig fmt src

## Run checker (expects check/checker.zig to exist)
test:
	zig run check/checker.zig

## Run integration tests inside the builder container
test-container:
	$(CONTAINER) build --target builder -t $(TEST_IMAGE) .
	$(CONTAINER) run --rm $(TEST_IMAGE) zig build test

## Run integration tests against an already-built container (container + HTTP checks)
test-integration:
	@container_name="runner-zig-it-$$RANDOM"; \
	container_started=0; \
	trap 'if [ $$container_started -eq 1 ]; then $(CONTAINER) stop $$container_name >/dev/null 2>&1 || true; fi' EXIT; \
	$(CONTAINER) run -d --rm --pull=never --name $$container_name -p 4040:4040 $(IMAGE):$(TAG) >/dev/null && \
	container_started=1; \
	for i in 1 2 3 4 5; do \
		if $(MAKE) --no-print-directory curl-local-health >/dev/null; then break; fi; \
		sleep 1; \
	done; \
	$(MAKE) --no-print-directory curl-local-health && \
	seq 1 40 | xargs -n1 -P40 sh -c 'curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:4040/run -H "content-type: application/json" -d @test-payload.json'; \
	if [ $$container_started -eq 1 ]; then $(CONTAINER) stop $$container_name >/dev/null 2>&1 || true; fi

## Build and push multi-arch image (linux/amd64 + linux/arm64) for GHCR
build-and-push: container-build container-push

## Build multi-arch image (linux/amd64 + linux/arm64) for GHCR
container-build:
	$(CONTAINER) build \
		--platform=linux/amd64 \
		--file Containerfile \
		--tag $(IMAGE):$(TAG)-amd64 \
		.
	$(CONTAINER) build \
		--platform=linux/arm64 \
		--file Containerfile \
		--tag $(IMAGE):$(TAG)-arm64 \
		.
	-@$(CONTAINER) rmi $(IMAGE):$(TAG) >/dev/null 2>&1 || true
	-@$(CONTAINER) manifest rm $(IMAGE):$(TAG) >/dev/null 2>&1 || true
	$(CONTAINER) manifest create $(IMAGE):$(TAG)
	$(CONTAINER) manifest add $(IMAGE):$(TAG) $(IMAGE):$(TAG)-amd64
	$(CONTAINER) manifest add $(IMAGE):$(TAG) $(IMAGE):$(TAG)-arm64

## Push multi-arch image manifest + all platform layers to GHCR
container-push:
	$(CONTAINER) manifest push --all \
		$(IMAGE):$(TAG) \
		docker://$(IMAGE):$(TAG)

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
