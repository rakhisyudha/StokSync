# syntax=docker/dockerfile:1

# Multi-stage build for the StokSync Go API. The final image contains only
# the compiled static binary plus CA certificates, not the Go toolchain or
# source tree, to keep the deployed image small and reduce its attack surface.

FROM golang:1.23-alpine AS builder

WORKDIR /src

# Resolve dependencies in their own layer so an unrelated source change does
# not force a re-download.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# CGO is disabled because pgx is a pure-Go driver; a static binary lets the
# runtime stage use a minimal base image without libc compatibility concerns.
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w" \
    -o /out/stoksync-api \
    ./cmd/api

FROM alpine:3.20 AS runtime

# ca-certificates is required for any outbound TLS the API makes (for example
# a managed PostgreSQL provider requiring sslmode=verify-full).
RUN apk add --no-cache ca-certificates && \
    addgroup -S stoksync && \
    adduser -S -G stoksync stoksync

WORKDIR /app
COPY --from=builder /out/stoksync-api ./stoksync-api

USER stoksync

# Documents the default listener; the actual bind address is controlled by
# STOKSYNC_HTTP_ADDR at runtime.
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget --quiet --tries=1 --spider "http://127.0.0.1:8080/v1/health" || exit 1

ENTRYPOINT ["./stoksync-api"]
