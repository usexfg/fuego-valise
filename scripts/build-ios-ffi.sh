#!/bin/sh
# Xcode build phase (Runner target, before Sources/Frameworks): builds the
# libfuego_ffi.a slices that Runner's OTHER_LDFLAGS force-load, for the SDK
# and architectures Xcode is building. Cargo makes this a no-op when current.
set -eu

export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found. Install Rust (https://rustup.rs) to build libfuego_ffi for iOS." >&2
  exit 1
fi

case "${PLATFORM_NAME:?}" in
  iphoneos) targets="aarch64-apple-ios" ;;
  iphonesimulator)
    targets=""
    for arch in ${ARCHS:?}; do
      case "$arch" in
        arm64) targets="$targets aarch64-apple-ios-sim" ;;
        x86_64) targets="$targets x86_64-apple-ios" ;;
        *) echo "error: no Rust target for simulator arch $arch" >&2; exit 1 ;;
      esac
    done
    ;;
  *) echo "error: unsupported PLATFORM_NAME $PLATFORM_NAME" >&2; exit 1 ;;
esac

manifest="${PROJECT_DIR:?}/../rust-fuego-wallet/Cargo.toml"
for t in $targets; do
  # Xcode's SDKROOT points at the iOS SDK; Cargo's host build scripts would
  # then link against it and fail. cc-rs finds the iOS SDK itself via xcrun.
  env -u SDKROOT cargo build --release --manifest-path "$manifest" -p fuego-ffi --target "$t"
done
