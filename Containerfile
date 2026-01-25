ARG ZIG_VERSION=0.15.2
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

RUN if [ -z "$TARGETARCH" ]; then \
    case "$(uname -m)" in \
    x86_64) TARGETARCH="amd64" ;; \
    aarch64) TARGETARCH="arm64" ;; \
    esac; \
    fi && \
    case "$TARGETARCH" in \
    amd64) ZIG_ARCH="x86_64" ;; \
    arm64) ZIG_ARCH="aarch64" ;; \
    *) echo "Unsupported TARGETARCH: $TARGETARCH" && exit 1 ;; \
    esac && \
    if [ -n "$ZIG_URL" ]; then \
    URL="$ZIG_URL"; \
    else \
    URL="$(ZIG_ARCH="$ZIG_ARCH" ZIG_VERSION="$ZIG_VERSION" python3 -c 'import json, os, urllib.request; ver=os.environ["ZIG_VERSION"]; arch=os.environ["ZIG_ARCH"]+"-linux"; data=json.load(urllib.request.urlopen("https://ziglang.org/download/index.json")); print(data[ver][arch]["tarball"])')"; \
    fi && \
    curl -fsSL "$URL" -o /tmp/zig.tar.xz && \
    ZIG_DIR="$(tar -tf /tmp/zig.tar.xz | head -n 1 | cut -d/ -f1)" && \
    tar -xJf /tmp/zig.tar.xz -C /opt && \
    mv "/opt/$ZIG_DIR" /opt/zig && \
    rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"

COPY . .
RUN zig build -Doptimize=ReleaseSafe

# Runtime stage
FROM alpine:${ALPINE_VERSION}
WORKDIR /app
ARG PORT
ARG RUN_CONCURRENCY
ARG RUN_INPUT_MAX
ARG RUN_OUTPUT_MAX
ARG DEBUG
ARG ALLOW_SHUTDOWN
RUN adduser -S -u 10001 app
COPY --from=builder /build/zig-out/bin/runner-zig /app/codebattle_runner
ENV PORT=$PORT \
    RUN_CONCURRENCY=$RUN_CONCURRENCY \
    RUN_INPUT_MAX=$RUN_INPUT_MAX \
    RUN_OUTPUT_MAX=$RUN_OUTPUT_MAX \
    DEBUG=$DEBUG \
    ALLOW_SHUTDOWN=$ALLOW_SHUTDOWN
USER app

EXPOSE 4040
ENTRYPOINT ["/app/codebattle_runner"]
