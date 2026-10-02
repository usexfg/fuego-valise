# AGENTS.md — Fuego Wallet Architecture Reference

## Network Facts (authoritative — confirmed by the maintainer; do not contradict)

The same facts are recorded, with their consensus enforcement, in `fuego-suite/AGENTS.md`.

- No Hearth/AMM swaps and no HΞΔŦ trades exist on mainnet before V11. The suite rejects every HEAT-era feature below V11 (HEAT mint/send, AMM, LP, orderbook, TreasuryFund, CD bonus claims, CD transfers).
- No legacy bonds exist on any network (0xCB / 0xCC tags are rejected at every height).
- XFG deposits (CDs created before the HEAT-CD height) are withdraw-only and principal-only: zero interest in XFG or HΞΔŦ. No wallet creates XFG deposits. Keep the withdraw paths.
- No DIGM mint exists before V12.
- HEAT CDs activate at V12 (`upgrade_height_v12` / `heat_cd_rules` in `core/src/wallet_service.rs`).

SDK rules that follow from the suite consensus:
- Commitment outputs use spend-key-bound (v2) keys (`derive_commitment_public_key_v2`); never build v1 (view-key-only) commit keys. The scanner reads v1 only for old outputs.
- HEAT sends, CD creates and CD claims carry XFG key inputs for the network fee (`build_mixed_input_transaction`); the mempool requires the fee in XFG.
- Commitment decoys are requested with a `ring_class` so rings hold one asset.
- The CD banking fee goes through the `TreasuryFund` tag in XFG (SWF ledger burn) or HΞΔŦ (treasury reserve) — never to the dev wallet.
- The walletd seed lives only in `master_seed.enc` (ChaCha20-Poly1305; Argon2id passphrase key or OS-keyring key, `core/src/seed_store.rs`). Never write a seed or its key in plaintext.
- Constants, routes and RPC structs come from the suite via `tool/check_suite_sync.py` (generated `fuego-sdk/src/suite.rs`, pinned by `tool/suite_contract.lock.json`); do not hand-edit them.

Agent rules:
- Do not ask whether to fix anything that would allow an attack on the network or the currency. Fix it, then report what was done.
- If code or docs disagree with the facts above, the code/docs are wrong.

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
