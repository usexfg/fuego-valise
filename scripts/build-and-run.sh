#!/bin/bash

# Fuego Wallet Build & Run Script
# Builds unified daemon + Flutter app, then runs with debug logging

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_fail() { echo -e "${RED}[FAIL]${NC} $1"; }

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

echo ""
echo "==========================================="
echo " Fuego Wallet Build & Run"
echo "==========================================="
echo ""

# ── Step 1: Build unified daemon ──
print_status "Step 1: Building unified daemon..."

if [ ! -f "fuego-suite/CMakeLists.txt" ]; then
    print_status "Initializing fuego-suite submodule..."
    git submodule update --init --recursive --depth 1 fuego-suite
fi

cd fuego-suite

if [ ! -f "build/src/unified" ]; then
    print_status "Configuring build..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew install boost openssl icu4c jsoncpp cmake ninja 2>/dev/null || true
        cmake -B build -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
    else
        sudo apt-get install -y libboost-all-dev libssl-dev libicu-dev libjsoncpp-dev cmake ninja-build 2>/dev/null || true
        cmake -B build -G Ninja \
            -DCMAKE_BUILD_TYPE=Release
    fi
    
    print_status "Building..."
    ninja -C build unified
    print_success "Unified daemon built"
else
    print_success "Unified daemon already built"
fi

cd ..

# ── Step 2: Build Rust wallet backend ──
print_status "Step 2: Building Rust wallet backend..."
cargo build --manifest-path rust-fuego-wallet/Cargo.toml --release --package rust_fuego_wallet
print_success "Rust wallet backend built at rust-fuego-wallet/target/release/fuego_walletd"

cargo build --manifest-path rust-fuego-wallet/Cargo.toml --release --package fuego-ffi
if [[ "$OSTYPE" == "darwin"* ]]; then
    cp rust-fuego-wallet/target/release/libfuego_ffi.dylib macos/Runner/libfuego_ffi.dylib
fi
print_success "fuego-ffi built from fuego-suite/src/crypto"

# ── Step 3: Build Flutter app ──
print_status "Step 3: Building Flutter app..."

if [[ "$OSTYPE" == "darwin"* ]]; then
    flutter build macos --release
    APP_PATH="build/macos/Build/Products/Release/fuego_wallet.app"

    # Bundle unified daemon into app
    print_status "Bundling unified daemon into app..."
    cp fuego-suite/build/src/unified "$APP_PATH/Contents/MacOS/"
    chmod +x "$APP_PATH/Contents/MacOS/unified"
    print_success "Unified daemon bundled at: $APP_PATH/Contents/MacOS/unified"
else
    flutter build linux --release
    APP_PATH="build/linux/x64/release/bundle"
    cp fuego-suite/build/src/unified "$APP_PATH/"
    chmod +x "$APP_PATH/unified"
    print_success "Unified daemon bundled at: $APP_PATH/unified"
fi

# ── Step 4: Run app ──
print_status "Step 4: Running app..."

if [[ "$OSTYPE" == "darwin"* ]]; then
    echo ""
    echo "App bundle: $APP_PATH"
    echo "Run manually:"
    echo "  open \"$APP_PATH\""
    echo ""
    echo "Or run the unified daemon standalone to test:"
    echo "  $APP_PATH/Contents/MacOS/unified --bind-port 18189 --container-file /tmp/fuego_wallet --container-password test123 --local"
    echo ""
    echo "Then test connectivity:"
    echo "  curl http://127.0.0.1:18189/health"
    echo "  curl -X POST http://127.0.0.1:18189/json_rpc -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getBalance\",\"params\":{\"accountIndex\":0}}'"
else
    echo ""
    echo "Run the app:"
    echo "  $APP_PATH/fuego_wallet"
    echo ""
    echo "Or test unified daemon standalone:"
    echo "  $APP_PATH/unified --bind-port 18189 --container-file /tmp/fuego_wallet --container-password test123 --local"
fi

print_success "Build complete"
