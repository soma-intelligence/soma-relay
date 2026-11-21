#!/usr/bin/env bash
# Builds relay-ffi for iOS (device + Apple silicon simulator), generates the
# Swift bindings and packages:
#   apple/Frameworks/RelayCoreFFI.xcframework   (static libs + C header + module map)
#   apple/Sources/RelayCore/RelayCoreFFI.swift  (generated Swift API, module RelayCore)
#
#   scripts/build-xcframework.sh          release build
#   scripts/build-xcframework.sh debug    debug build (faster, larger)
set -euo pipefail

PROFILE="${1:-release}"
case "$PROFILE" in
  release) CARGO_ARGS=(--release); PROFILE_DIR=release ;;
  debug) CARGO_ARGS=(); PROFILE_DIR=debug ;;
  *) echo "usage: $0 [release|debug]" >&2; exit 64 ;;
esac

export PATH="$HOME/.cargo/bin:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
export CARGO_TARGET_DIR="$TARGET_DIR"
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim)
HOST=aarch64-apple-darwin
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

for t in "${TARGETS[@]}" "$HOST"; do
  rustup target list --installed | grep -qx "$t" || rustup target add "$t"
done

for t in "${TARGETS[@]}"; do
  echo "relay-ffi: cargo build $PROFILE_DIR $t"
  cargo build -p relay-ffi ${CARGO_ARGS[@]+"${CARGO_ARGS[@]}"} --target "$t"
done

# Bindings come from the host library (same exported interface).
echo "relay-ffi: host build for binding generation"
env -u IPHONEOS_DEPLOYMENT_TARGET cargo build -p relay-ffi ${CARGO_ARGS[@]+"${CARGO_ARGS[@]}"} --target "$HOST"
HOST_LIB="$TARGET_DIR/$HOST/$PROFILE_DIR/librelay_ffi.a"

BUILD="$ROOT/apple/build/relay-ffi"
GEN="$BUILD/generated"
HEADERS="$BUILD/headers"
rm -rf "$GEN" "$HEADERS"
mkdir -p "$GEN" "$HEADERS"
echo "relay-ffi: generating Swift bindings"
env -u IPHONEOS_DEPLOYMENT_TARGET cargo run -q -p relay-ffi --features bindgen --bin uniffi-bindgen -- \
  generate --library "$HOST_LIB" --language swift \
  --out-dir "$GEN"

cp "$GEN/RelayCoreFFI.h" "$HEADERS/"
cp "$GEN/RelayCoreFFI.modulemap" "$HEADERS/module.modulemap"

SWIFT_DIR="$ROOT/apple/Sources/RelayCore"
mkdir -p "$SWIFT_DIR"
if ! cmp -s "$GEN/RelayCore.swift" "$SWIFT_DIR/RelayCoreFFI.swift"; then
  cp "$GEN/RelayCore.swift" "$SWIFT_DIR/RelayCoreFFI.swift"
fi

XCF="$ROOT/apple/Frameworks/RelayCoreFFI.xcframework"
mkdir -p "$ROOT/apple/Frameworks"
rm -rf "$XCF"
LIB_ARGS=()
for t in "${TARGETS[@]}"; do
  LIB_ARGS+=(-library "$TARGET_DIR/$t/$PROFILE_DIR/librelay_ffi.a" -headers "$HEADERS")
done
xcodebuild -create-xcframework "${LIB_ARGS[@]}" -output "$XCF" >/dev/null

echo "relay-ffi: $XCF"
echo "relay-ffi: $SWIFT_DIR/RelayCoreFFI.swift"
for t in "${TARGETS[@]}"; do
  ls -lh "$TARGET_DIR/$t/$PROFILE_DIR/librelay_ffi.a" | awk -v t="$t" '{print "relay-ffi: " t " static lib " $5}'
done
