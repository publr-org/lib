# syntax=docker/dockerfile:1
# Build from the repo root (COPY paths are context-relative):
#   docker build -f docker/caddy/Dockerfile -t http-server-caddy .

# ---- build the Zig binary ----
FROM alpine:3.20 AS builder
ARG ZIG_VERSION=0.16.0
ARG TARGETARCH
RUN apk add --no-cache curl xz \
    && case "$TARGETARCH" in \
         amd64) ZIG_ARCH=x86_64 ;; \
         arm64) ZIG_ARCH=aarch64 ;; \
         *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && mkdir -p /usr/local/zig \
    && tar -xJf /tmp/zig.tar.xz -C /usr/local/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz
ENV PATH="/usr/local/zig:${PATH}"

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY build ./build
COPY src ./src
COPY examples ./examples
RUN zig build -Drelease

# ---- runtime: Caddy (HTTP/1.1, /2, /3) fronting the Zig backend (HTTP/1.1 only) ----
FROM caddy:2-alpine
COPY --from=builder /src/zig-out/bin/hello /usr/local/bin/hello
COPY docker/caddy/Caddyfile /etc/caddy/Caddyfile
COPY docker/static /srv/static
COPY docker/caddy/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 8443/tcp 8443/udp
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
