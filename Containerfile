ARG ZIG_VERSION=0.17.0
ARG ALPINE_VERSION=3.23
ARG ZIG_URL=
ARG PORT=4040
ARG RUN_CONCURRENCY=32
ARG RUN_INPUT_MAX=1048576
ARG RUN_OUTPUT_MAX=1048576
ARG DEBUG=
ARG ALLOW_SHUTDOWN=

# Build stage
FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS builder
WORKDIR /build

ARG ZIG_VERSION
ARG ZIG_URL
ARG TARGETPLATFORM
ARG TARGETARCH

RUN apk add --no-cache curl tar xz make ca-certificates python3

# The builder runs natively on $BUILDPLATFORM: fetch Zig for the build host
# and cross-compile for $TARGETARCH below. Running a foreign-arch Zig under
# emulation is slow and breaks outright under Rosetta ("bss_size overflow").
# ZIG_URL, if set, must point at a tarball for the build host's arch.
RUN case "$(uname -m)" in \
    x86_64) HOST_ARCH="x86_64" ;; \
    aarch64) HOST_ARCH="aarch64" ;; \
    *) echo "Unsupported build host arch: $(uname -m)" && exit 1 ;; \
    esac && \
    if [ -n "$ZIG_URL" ]; then \
    URL="$ZIG_URL"; \
    else \
    URL="$(HOST_ARCH="$HOST_ARCH" ZIG_VERSION="$ZIG_VERSION" python3 -c 'import json, os, urllib.request; ver=os.environ["ZIG_VERSION"]; arch=os.environ["HOST_ARCH"]+"-linux"; data=json.load(urllib.request.urlopen("https://ziglang.org/download/index.json")); print(data[ver][arch]["tarball"])')"; \
    fi && \
    curl -fsSL "$URL" -o /tmp/zig.tar.xz && \
    ZIG_DIR="$(tar -tf /tmp/zig.tar.xz | head -n 1 | cut -d/ -f1)" && \
    tar -xJf /tmp/zig.tar.xz -C /opt && \
    mv "/opt/$ZIG_DIR" /opt/zig && \
    rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"

COPY . .
RUN case "${TARGETARCH:-$(uname -m)}" in \
    amd64|x86_64) ZIG_TARGET="x86_64-linux" ;; \
    arm64|aarch64) ZIG_TARGET="aarch64-linux" ;; \
    *) echo "Unsupported TARGETARCH: $TARGETARCH" && exit 1 ;; \
    esac && \
    zig build -Doptimize=ReleaseSafe -Dtarget="$ZIG_TARGET"

# Runtime stage
FROM alpine:${ALPINE_VERSION}
WORKDIR /app
ARG PORT
ARG RUN_CONCURRENCY
ARG RUN_INPUT_MAX
ARG RUN_OUTPUT_MAX
ARG DEBUG
ARG ALLOW_SHUTDOWN
RUN apk add --no-cache make python3
COPY --from=builder /build /app
RUN cp /app/zig-out/bin/runner-zig /app/codebattle_runner
# Bind-mount target for per-request workspace; see setupSandboxMounts.
RUN mkdir -m 0755 /sandbox
ENV PORT=$PORT \
    RUN_CONCURRENCY=$RUN_CONCURRENCY \
    RUN_INPUT_MAX=$RUN_INPUT_MAX \
    RUN_OUTPUT_MAX=$RUN_OUTPUT_MAX \
    DEBUG=$DEBUG \
    ALLOW_SHUTDOWN=$ALLOW_SHUTDOWN
EXPOSE 4040
ENTRYPOINT ["/app/codebattle_runner"]
