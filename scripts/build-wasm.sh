#!/usr/bin/env bash
# Builds relay-wasm with wasm-pack into web/src/core/pkg (ES module, --target web).
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rustup target list --installed | grep -qx wasm32-unknown-unknown || rustup target add wasm32-unknown-unknown
command -v wasm-pack >/dev/null || { echo "wasm-pack missing: cargo install wasm-pack" >&2; exit 1; }
CARGO_PROFILE_RELEASE_OPT_LEVEL="${RELAY_WASM_OPT_LEVEL:-s}" wasm-pack build crates/relay-wasm --target web --release --out-dir ../../web/src/core/pkg --out-name relay_wasm
rm -f web/src/core/pkg/.gitignore
WASM="web/src/core/pkg/relay_wasm_bg.wasm"
RAW=$(wc -c < "$WASM" | tr -d ' ')
GZ=$(gzip -9 -c "$WASM" | wc -c | tr -d ' ')
echo "relay-wasm: $WASM $((RAW / 1024)) KiB ($((GZ / 1024)) KiB gzip)"
