# syntax=docker/dockerfile:1.7
#
# Soma Relay node. Build from the repository root:
#   docker build -f deploy/Dockerfile -t soma-relay-node .
# Multi-arch:
#   docker buildx build -f deploy/Dockerfile --platform linux/amd64,linux/arm64 -t soma-relay-node .
# When web/dist exists at build time (run the web build first), it is served at /.

ARG RUST_VERSION=1

FROM rust:${RUST_VERSION}-slim-bookworm AS build
WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target,sharing=locked \
    cargo build --release -p relay-node \
    && install -D target/release/relay-node /out/relay-node
RUN mkdir -p /out/web /out/data \
    && if [ -d web/dist ]; then cp -R web/dist/. /out/web/; fi

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /out/relay-node /usr/local/bin/relay-node
COPY --from=build --chown=65532:65532 /out/web /app/web
COPY --from=build --chown=65532:65532 /out/data /data
ENV RELAY_LISTEN=0.0.0.0:8080 \
    RELAY_DATA_DIR=/data \
    RELAY_WEB_DIR=/app/web
EXPOSE 8080
VOLUME ["/data"]
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/relay-node"]
