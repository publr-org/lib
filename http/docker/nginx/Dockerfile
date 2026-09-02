# syntax=docker/dockerfile:1
# Build from the repo root (COPY paths are context-relative):
#   docker build -f docker/nginx/Dockerfile -t http-server-nginx .

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

# ---- a self-signed cert, generated at build time so the runtime image needs no openssl ----
FROM alpine:3.20 AS certs
RUN apk add --no-cache openssl \
    && openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
         -keyout /key.pem -out /cert.pem -days 365 \
         -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

# ---- runtime: nginx (HTTP/1.1, /2) fronting the Zig backend (HTTP/1.1 only) ----
FROM alpine:3.20
RUN apk add --no-cache nginx \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log \
    && mkdir -p /etc/nginx/tls
COPY --from=builder /src/zig-out/bin/hello /usr/local/bin/hello
COPY --from=certs /cert.pem /key.pem /etc/nginx/tls/
COPY docker/nginx/nginx.conf /etc/nginx/http.d/default.conf
COPY docker/static /srv/static
COPY docker/nginx/entrypoint.sh /usr/local/bin/docker-entrypoint-nginx.sh
RUN chmod +x /usr/local/bin/docker-entrypoint-nginx.sh

EXPOSE 8443/tcp
ENTRYPOINT ["/usr/local/bin/docker-entrypoint-nginx.sh"]
