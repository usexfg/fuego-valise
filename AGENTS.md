# AGENTS.md — Fuego Wallet Architecture Reference

## Swap Architecture (Dual-Mode)

The Fuego swap system uses **two daemons** that serve different purposes:

### fuegod (port 18180)
- Main CryptoNote blockchain node
- Has an **embedded SwapDaemon** for XFG-side operations (escrow, ring signatures, state machine)
- RPC endpoints: `/getswapoffers`, `/getswapprice`, `/getswaptrades`, `/submitswap`, `/cancelswap`, `/requestswap`, `/initiate`, `/accept`, `/processswap`, `/refundswap`, `/getactiveswaps`, `/listswaps`, `/getswapstatus`
- Does NOT configure counterparty chain clients (BTC, ETH, SOL, etc.)
- Used by: Dart wallet tabs 1-3 (Orderbook, Trade, Trades)

### xfg-swapd (port 18902)
- Standalone swap daemon for cross-chain atomic swaps
- Has its own JSON-RPC HTTP server on port 18902, status server on 18900, P2P on 18901
- Configurable via `--swap-config` JSON with chain RPC endpoints and signer keys
- Supports all 12 counterparty chains with SPV or RPC verification
- Connects to fuegod as an RPC client for Fuego chain operations
- Used by: Dart wallet Cross-Chain tab
- Built from: `src/SwapDaemon/` in the fuego C++ repo

### Why Both Are Needed
- Fuegod handles Fuego-side escrow and ring signatures only
- xfg-swapd handles actual cross-chain lock/claim/refund on BTC, ETH, SOL, etc.
- They use **separate databases** (fuegod: `<configFolder>/swaps`, xfg-swapd: `~/.xfg-swapd`)

## Supported Swap Chains (12 pairs)

| ID | Chain | Adapter | Connection | HTLC Type |
|----|-------|---------|-----------|-----------|
| 0 | SOL | `SolChainClient` | Solana JSON-RPC | On-chain program |
| 1 | ETH | `EthChainClient` | Ethereum JSON-RPC | HashedTimelock.sol |
| 2 | XMR | `XmrChainClient` | monerod + monero-wallet-rpc | Ring sigs + adaptor sigs |
| 3 | BCH | `BchChainClient` | Electrum SPV or bitcoind RPC | P2SH |
| 4 | ARB | `EthChainClient` | Arbitrum JSON-RPC | HashedTimelock.sol |
| 5 | BASE | `EthChainClient` | Base JSON-RPC | HashedTimelock.sol |
| 6 | KMD | `KmdChainClient` | Electrum SPV or komodod RPC | P2SH |
| 7 | BNB | `BscChainClient` | BSC JSON-RPC | HashedTimelock.sol |
| 8 | DCR | `DcrChainClient` | Neutrino SPV (BIP-157/158) or dcrd RPC | P2SH |
| 9 | BTC | `BtcChainClient` | Electrum SPV or bitcoind RPC | P2WSH SegWit |
| 10 | LTC | `LtcChainClient` | Electrum SPV or litecoind RPC | P2WSH SegWit |
| 11 | POLYGON | `PolygonChainClient` | Polygon JSON-RPC | HashedTimelock.sol |

### Chain Connection Modes
- **SPV mode**: Read-only verification via Electrum protocol (BTC/LTC/BCH/KMD) or Neutrino (DCR). Cannot create lock transactions — claim/refund needs RPC mode.
- **RPC mode**: Full node connection with `-txindex`. Required for sending transactions.
- **EVM chains**: JSON-RPC only (no SPV). Share same HashedTimelock.sol contract. Public RPCs (Infura/Alchemy) used by default — no user setup needed.
- **SOL**: JSON-RPC + on-chain HTLC program. Public RPC used by default — no user setup needed.
- **XMR**: CryptoNote ring signatures — no SPV proof possible. Run your own `monerod` + `monero-wallet-rpc` (recommended) or use a remote node from [monero.fail](https://monero.fail).

### What Users Need To Run
| Chain | User Action Required? |
|-------|----------------------|
| BTC, LTC, BCH, KMD | None — Electrum SPV handles verification via public servers |
| ETH, ARB, BASE, BNB, POLYGON | None — public JSON-RPC used by default |
| SOL | None — public Solana RPC used by default |
| DCR | None for SPV mode (Neutrino built-in) |
| XMR | Run your own monerod + monero-wallet-rpc (recommended), or use a remote node from monero.fail |

### Known Issues
- POLYGON missing from `swapPairToString()`, `swapPairFromString()`, `msPerBlock()`, `PriceOracle.cpp` in xfg-swapd C++ code — shows "???" in logs, fails at CLI level, but works via JSON config.
- `main.cpp` help text only lists "SOL, ETH, XMR, BCH, ARB, BASE" — stale.
- SPV mode is read-only; claim/refund requires RPC mode for UTXO chains.

## Dart Wallet Backend Architecture

### Backend Startup (main.dart + NodeConnection)
- `NodeConnection` is the single source of truth for local vs remote mode
- Platform defaults: **desktop → local**, **mobile → remote** (override via prefs or `FUEGO_USE_LOCAL_NODE`)
- **Local**: `fuego_walletd -P 18189 serve --local` (embedded fuegod; never spawn a separate fuegod in remote mode)
- **Remote**: `fuego_walletd -P 18189 serve --daemon-host <seed> --daemon-port <port>` — local proxy always preferred
- Wallet JSON-RPC always targets `http://127.0.0.1:18189` when the proxy is up
- Desktop local failure auto-falls back to remote proxy + seed failover across `NetworkConfig.seedNodes`
- Health: `/health` or JSON-RPC `getHealth` on 18189 (up to ~180s for local)

### Binary Naming
- GUI frontend: `fuego-wallet` (dash)
- Rust backend: `fuego_walletd` (underscore)
- Fuegod daemon: `fuegod`
- Swap daemon: `xfg-swapd`

### Port Layout
| Port | Service |
|------|---------|
| 18180 | fuegod daemon RPC |
| 18189 | fuego_walletd HTTP proxy (Dart connects here) |
| 18900 | xfg-swapd status server |
| 18901 | xfg-swapd P2P |
| 18902 | xfg-swapd JSON-RPC (Dart Cross-Chain tab connects here) |

## Rust SDK (fuego-sdk)

Located at: `rust-fuego-wallet/fuego-sdk/fuego-sdk/src/`

- `types.rs`: SwapPair enum (12 pairs), SwapOffer, SwapPrice, SwapTrade, SwapStatus
- `chain/mod.rs`: ChainType enum (13 chains including Fuego), ChainSpv trait
- `chain/bitcoin.rs`: Bitcoin-family SPV adapter (BTC, LTC, BCH, KMD, DCR)
- `chain/evm.rs`: EVM chain adapter (ETH, ARB, BASE, BNB, POLYGON)
- `chain/btc_rpc.rs`: Bitcoin JSON-RPC client
- `chain/evm_rpc.rs`: Ethereum JSON-RPC client

### ChainType Methods
- `is_bitcoin_family()`: BitcoinCash, Komodo, Decred, Bitcoin, Litecoin
- `is_evm()`: Ethereum, Arbitrum, Base, Bnb, Polygon
- `from_symbol()`: Accepts "BSC" as alias for Bnb, "POLYGON"/"POLY" for Polygon

## CI / Build

- Flutter: 3.44.4
- CI: ubuntu-22.04 (glibc 2.35)
- macOS app bundle: `fuego_wallet.app`
- Rust backend binary: `fuego_walletd`
- Default remote daemon: `207.244.247.64:18180`

## fuego-suite submodule

- `fuego-suite/` is a git submodule of `usexfg/fuego-suite`, tracking `master`, pinned to one commit. Clone with `--recurse-submodules`. Locally it replaces the old gitignored `xfgo/` checkout.
- `fuego-ffi/build.rs` compiles CryptoNight (`slow-hash.c` etc.) directly from `fuego-suite/src/crypto`. There is no vendored copy. `cargo test -p fuego-ffi` checks it against canonical CN v0/v2 vectors.
- Desktop CI builds `fuegod`/`xfg-swapd`/`unified` from the pinned submodule (`submodules: recursive`), not from a fresh clone of suite master.
- Dependabot (`gitsubmodule` ecosystem) opens a PR whenever suite master moves. Merging that PR is how the pin moves.
- The Rust SDK is a Rust reimplementation of suite's C++ wire formats, not shared source. The submodule does not keep it in sync; only the fuegod wire-format CI job catches drift.
- Wire-format check (CI job `fuegod-wire-check`): builds `fuegod` from the pin, runs it isolated with `--testnet` (ungates RPC on an unsynced node), and round-trips `fuego-sdk/tests/fuegod_wire.rs`. Locally: start fuegod the same way, then `FUEGOD_RPC_URL=http://127.0.0.1:28180 cargo test -p fuego-sdk --test fuegod_wire -- --ignored`.
- Desktop build + bundling lives only in `.github/actions/build-desktop-backends` and `.github/actions/bundle-desktop-backends`; CI and every desktop release workflow (macOS, App Store, flatpak, snap) use them. Bundle layout: `fuego_walletd`, `fuegod`, `xfg-swapd`, `unified` next to the executable (`Contents/MacOS` on macOS); `libfuego_ffi` in `Contents/Frameworks` (macOS) or `lib/` (Linux). `scripts/sign-macos-app.sh` signs the result.
- `libfuego_ffi.dylib` is built, never committed (`macos/Runner/libfuego_ffi.dylib` is gitignored). `scripts/build-and-run.sh` builds it for local macOS builds.
- Linux release packages build on ubuntu-22.04: snap `core22` is 22.04 and `--destructive-mode` requires the host to match. Suite links Boost statically, so the daemons only need OpenSSL 3, libstdc++ and glibc at runtime.
- iOS cannot spawn `fuego_walletd`; iOS release workflows do not build it (see `docs/IOS_WALLETD_FFI_SCOPE.md`).
- iOS links the FFI statically: Runner's `OTHER_LDFLAGS` force-load `rust-fuego-wallet/target/<triple>/release/libfuego_ffi.a` (`aarch64-apple-ios` device, `aarch64-apple-ios-sim` / `x86_64-apple-ios` simulator) and `STRIP_STYLE = non-global` keeps the `fuego_*` symbols for `DynamicLibrary.process()`. Before a local iOS build: `cargo build --release --manifest-path rust-fuego-wallet/Cargo.toml -p fuego-ffi --target <triple>`.
- Linux bundles include a `fuego-valise` launcher symlink to the `Fuego Valise` executable; `linux/xfg-wallet.desktop` execs it.

## Network selection

- Mainnet/testnet: `FUEGO_TESTNET` env wins at launch, else the choice saved by Settings → Network (`node_network` pref). `NodeConnection.switchNetwork()` retargets ports/seeds, persists, and reconnects at runtime; `useTestnet` in `main.dart` follows it.
- Chain clients (`daemon`, `hearthClient`) and `DexCubit` follow every reconnect through `NodeConnection.addListener`.
