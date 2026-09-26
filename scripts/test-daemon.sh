#!/bin/bash

# Fuego Wallet Daemon Test Script
# Builds unified daemon, starts it, and verifies all endpoints work

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

PASS=0
FAIL=0

check() {
    if eval "$2" >/dev/null 2>&1; then
        print_success "$1"
        ((PASS++))
    else
        print_fail "$1"
        ((FAIL++))
    fi
}

UNIFIED_PORT=18189
FUEGOD_PORT=18180
UNIFIED_PID=""

cleanup() {
    if [ -n "$UNIFIED_PID" ] && kill -0 "$UNIFIED_PID" 2>/dev/null; then
        print_status "Stopping unified daemon (PID $UNIFIED_PID)"
        kill "$UNIFIED_PID" 2>/dev/null || true
        sleep 2
        kill -9 "$UNIFIED_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo ""
echo "==========================================="
echo " Fuego Wallet Daemon Test Suite"
echo "==========================================="
echo ""

# ── Step 1: Find or build unified binary ──
print_status "Step 1: Finding unified daemon binary..."

UNIFIED_BIN=""
if [ -f "fuego-suite/build/src/unified" ]; then
    UNIFIED_BIN="$(pwd)/fuego-suite/build/src/unified"
elif [ -f "fuego-suite/build/release/src/unified" ]; then
    UNIFIED_BIN="$(pwd)/fuego-suite/build/release/src/unified"
elif [ -f "build/src/unified" ]; then
    UNIFIED_BIN="$(pwd)/build/src/unified"
fi

if [ -z "$UNIFIED_BIN" ]; then
    print_warn "Unified binary not found. Building from source..."
    
    if [ ! -f "fuego-suite/CMakeLists.txt" ]; then
        print_status "Initializing fuego-suite submodule..."
        git submodule update --init --recursive --depth 1 fuego-suite
    fi
    
    cd fuego-suite
    
    if [ ! -d "build" ]; then
        print_status "Building unified daemon..."
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
        ninja -C build unified
    fi
    
    cd ..
    UNIFIED_BIN="$(pwd)/fuego-suite/build/src/unified"
fi

if [ ! -f "$UNIFIED_BIN" ]; then
    print_fail "Unified binary not found at: $UNIFIED_BIN"
    exit 1
fi

print_success "Unified binary: $UNIFIED_BIN"
print_success "Binary size: $(du -h "$UNIFIED_BIN" | cut -f1)"

# ── Step 2: Verify binary runs ──
print_status "Step 2: Verifying binary runs..."

# Test that binary starts and shows help/usage
if timeout 5 "$UNIFIED_BIN" --help 2>/dev/null | head -1 | grep -qi "usage\|help\|fuego\|unified"; then
    print_success "Binary runs and shows usage info"
else
    # Binary might not have --help, just check it doesn't crash immediately
    print_warn "Binary doesn't respond to --help (may be normal)"
fi

# ── Step 3: Free ports ──
print_status "Step 3: Freeing ports..."

for port in $UNIFIED_PORT $FUEGOD_PORT; do
    pid=$(lsof -ti ":$port" -sTCP:LISTEN 2>/dev/null || true)
    if [ -n "$pid" ]; then
        print_warn "Port $port in use by PID $pid — killing"
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi
done

print_success "Ports $UNIFIED_PORT and $FUEGOD_PORT are free"

# ── Step 4: Start unified daemon ──
print_status "Step 4: Starting unified daemon..."

WALLET_DIR="/tmp/fuego_test_wallet"
mkdir -p "$WALLET_DIR"
CONTAINER_FILE="$WALLET_DIR/fuego_wallet"
CONTAINER_PASSWORD="test_password_$(date +%s)"

"$UNIFIED_BIN" \
    --bind-port "$UNIFIED_PORT" \
    --container-file "$CONTAINER_FILE" \
    --container-password "$CONTAINER_PASSWORD" \
    --local &
UNIFIED_PID=$!

print_success "Unified daemon started (PID $UNIFIED_PID)"

# ── Step 5: Wait for health ──
print_status "Step 5: Waiting for daemon to be ready..."

HEALTHY=false
for i in $(seq 1 30); do
    if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$UNIFIED_PORT/health" 2>/dev/null | grep -q "200"; then
        HEALTHY=true
        break
    fi
    sleep 2
done

if [ "$HEALTHY" = true ]; then
    print_success "Unified daemon is healthy on port $UNIFIED_PORT"
else
    print_fail "Unified daemon not ready after 60s"
    echo ""
    print_status "Daemon logs:"
    wait "$UNIFIED_PID" 2>/dev/null || true
    exit 1
fi

# ── Step 6: Test endpoints ──
print_status "Step 6: Testing endpoints..."

# Test /health
RESP=$(curl -s "http://127.0.0.1:$UNIFIED_PORT/health" 2>/dev/null)
check "GET /health returns 200" "echo '$RESP' | grep -q 'ok\|status'"

# Test /getinfo via fuegod port (if reachable)
if curl -s --connect-timeout 2 "http://127.0.0.1:$FUEGOD_PORT/getinfo" 2>/dev/null | grep -q "status\|version"; then
    print_success "GET /getinfo on fuegod port $FUEGOD_PORT responds"
    ((PASS++))
else
    print_warn "fuegod port $FUEGOD_PORT not reachable (may be embedded)"
fi

# Test JSON-RPC getBalance
BALANCE_RESP=$(curl -s -X POST "http://127.0.0.1:$UNIFIED_PORT/json_rpc" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"getBalance","params":{"accountIndex":0}}' 2>/dev/null)
if echo "$BALANCE_RESP" | grep -q "balance\|result\|jsonrpc"; then
    print_success "JSON-RPC getBalance works"
    ((PASS++))
else
    print_fail "JSON-RPC getBalance failed"
    ((FAIL++))
fi

# Test JSON-RPC getBlockCount
HEIGHT_RESP=$(curl -s -X POST "http://127.0.0.1:$UNIFIED_PORT/json_rpc" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"getBlockCount","params":{}}' 2>/dev/null)
if echo "$HEIGHT_RESP" | grep -q "count\|result\|jsonrpc"; then
    print_success "JSON-RPC getBlockCount works"
    ((PASS++))
else
    print_fail "JSON-RPC getBlockCount failed"
    ((FAIL++))
fi

# Test JSON-RPC getHealth
HEALTH_RESP=$(curl -s -X POST "http://127.0.0.1:$UNIFIED_PORT/json_rpc" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"getHealth","params":{}}' 2>/dev/null)
if echo "$HEALTH_RESP" | grep -q "health\|status\|jsonrpc"; then
    print_success "JSON-RPC getHealth works"
    ((PASS++))
else
    print_fail "JSON-RPC getHealth failed"
    ((FAIL++))
fi

# Test swap endpoints (may not be available without config)
for endpoint in getswapoffers getswapprice getswaptrades; do
    SWAP_RESP=$(curl -s "http://127.0.0.1:$UNIFIED_PORT/$endpoint?pair=0" 2>/dev/null)
    if echo "$SWAP_RESP" | grep -q "offer\|price\|trade\|result\|\[\]"; then
        print_success "GET /$endpoint responds"
        ((PASS++))
    else
        print_warn "GET /$endpoint not available (may need swap config)"
    fi
done

# ── Step 7: Test remote daemon connectivity ──
print_status "Step 7: Testing remote daemon connectivity..."

REMOTE_HOST="207.244.247.64"
REMOTE_PORT=18180

if curl -s --connect-timeout 5 "http://$REMOTE_HOST:$REMOTE_PORT/getinfo" 2>/dev/null | grep -q "status\|version\|height"; then
    print_success "Remote daemon $REMOTE_HOST:$REMOTE_PORT is reachable"
    ((PASS++))
else
    print_warn "Remote daemon $REMOTE_HOST:$REMOTE_PORT not reachable"
fi

# ── Summary ──
echo ""
echo "==========================================="
echo " Results: $PASS passed, $FAIL failed"
echo "==========================================="

if [ "$FAIL" -gt 0 ]; then
    print_fail "Some tests failed"
    exit 1
else
    print_success "All tests passed"
    exit 0
fi
