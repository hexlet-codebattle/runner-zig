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

## Recipe used by the runner: dispatch by which solution/checker file is present
## in check/. `make -n test` is captured at startup and replayed for every /run.
## Checker-required langs (zig, ...) put their entry point in checker.*; simple
## langs (python, js, ruby, ...) just have solution.*.
test:
	cd check && \
	if   [ -f checker.zig ];    then zig run checker.zig; \
	elif [ -f solution.py ];    then python3 solution.py; \
	elif [ -f solution.js ];    then node solution.js; \
	elif [ -f solution.rb ];    then ruby solution.rb; \
	else echo "no recognized solution file" >&2; exit 1; fi

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

## Build alpine + ubuntu images and run the python a+b integration suite against each.
test-integration:
	$(CONTAINER) build --file Containerfile --tag $(IMAGE):alpine-it .
	@$(MAKE) --no-print-directory _run-integration IMG_REF=$(IMAGE):alpine-it FLAVOR=alpine
	$(CONTAINER) build --file Containerfile.ubuntu --tag $(IMAGE):ubuntu-it .
	@$(MAKE) --no-print-directory _run-integration IMG_REF=$(IMAGE):ubuntu-it FLAVOR=ubuntu

## Private: run the python a+b smoke test against a pre-built image.
## Invoked by test-integration once per flavor; takes IMG_REF and FLAVOR.
## Asserts /run returns exit_code:0 stdout:"5\n" for a single request and for
## every request of a 30-way parallel burst.
_run-integration:
	@container_name="runner-zig-it-$(FLAVOR)-$$RANDOM"; \
	trap "$(CONTAINER) stop $$container_name >/dev/null 2>&1 || true" EXIT; \
	echo "==== integration ($(FLAVOR)): $(IMG_REF) ===="; \
	$(CONTAINER) run -d --rm --pull=never --name $$container_name -p 4040:4040 \
		--cap-add=SYS_ADMIN \
		--cap-add=SYS_CHROOT \
		--security-opt=seccomp=unconfined \
		--security-opt=apparmor=unconfined \
		--security-opt=no-new-privileges=false \
		-e DEBUG=true \
		$(IMG_REF) >/dev/null; \
	for i in 1 2 3 4 5; do \
		if curl -fsS http://localhost:4040/health >/dev/null 2>&1; then break; fi; \
		sleep 1; \
	done; \
	curl -fsS http://localhost:4040/health >/dev/null || { echo "FAIL: health check"; exit 1; }; \
	echo "-- single request --"; \
	body=$$(curl -sS http://localhost:4040/run -H 'content-type: application/json' -d @test-payload.json); \
	printf '  %s\n' "$$body"; \
	pass=1; \
	printf '%s' "$$body" | grep -q '"exit_code":0,"stdout":"5\\n","stderr":""' \
		|| { printf '  FAIL: response did not match {exit_code:0, stdout:"5\\\\n", stderr:""}\n'; pass=0; }; \
	echo "-- 30 parallel runs --"; \
	ok=$$(seq 1 30 | xargs -n1 -P30 sh -c 'b=$$(curl -sS http://localhost:4040/run -H "content-type: application/json" -d @test-payload.json); printf "%s\n" "$$b"' | grep -c '"exit_code":0,"stdout":"5\\n","stderr":""'); \
	printf '  %d/30 returned the expected body\n' "$$ok"; \
	[ "$$ok" = "30" ] || pass=0; \
	echo "---- container logs (tail 40) ----"; \
	$(CONTAINER) logs --tail 40 $$container_name 2>&1 | tail -40; \
	[ "$$pass" = "1" ] || { echo "==== FAIL ($(FLAVOR)) ===="; exit 1; }; \
	echo "==== PASS ($(FLAVOR)) ===="

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
		--security-opt=seccomp=unconfined \
		--security-opt=apparmor=unconfined \
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
