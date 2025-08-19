# syntax=docker/dockerfile:1

### Build stage
FROM golang:1.22-alpine AS builder
WORKDIR /app

RUN wget https://go.dev/dl/go1.23.5.linux-amd64.tar.gz && \
    tar -C /usr/local -xzf go1.23.5.linux-amd64.tar.gz

# Install tools and certs
RUN apk add --no-cache git ca-certificates && update-ca-certificates

# Module files first (better layer caching)
COPY go.mod ./
RUN if [ -f go.sum ]; then cp go.sum .; fi
RUN --mount=type=cache,target=/go/pkg/mod go mod download

# Copy source
COPY . .

# Build static binary
RUN --mount=type=cache,target=/root/.cache/go-build         CGO_ENABLED=0 GOOS=linux GOARCH=amd64         go build -trimpath -ldflags="-s -w" -o server .

### Runtime stage
FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app

# Copy CA certs for TLS to Hedera/mirror nodes
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy binary
COPY --from=builder /app/server /app/server

EXPOSE 8080
USER 65532:65532
ENTRYPOINT ["/app/server"]
