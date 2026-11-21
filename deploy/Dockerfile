# Soma Relay node. Works with the classic builder and with BuildKit. From the repo root:
#   docker build -f deploy/Dockerfile -t soma-relay-node .
# Multi-arch:
#   docker buildx build -f deploy/Dockerfile --platform linux/amd64,linux/arm64 -t soma-relay-node .
# When web/dist exists at build time (run the web build first), it is served at /.

ARG RUST_VERSION=1

FROM rust:${RUST_VERSION}-slim-bookworm AS build
WORKDIR /src
# Only what the build needs (never the host target/ or node_modules/).
COPY Cargo.toml Cargo.loc[k] ./
COPY crates ./crates
# web/dist is optional: the wildcard matches nothing when it is absent, and Cargo.toml rides
# along so the COPY always has one source. It is removed right after.
COPY Cargo.toml web/dis[t] /out/web/
RUN rm /out/web/Cargo.toml && mkdir -p /out/data
RUN cargo build --release -p relay-node \
    && install -D target/release/relay-node /out/relay-node

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
