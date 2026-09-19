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

## Supported Swap Chains

`XfgSwap::SwapPair` (fuego-suite `src/SwapDaemon/SwapTypes.h:77`) defines **29
pairs, ids 0-28**. `SwapDaemon.cpp` registers a chain client for **25** of
them; `ZANO(24)`, `TON(27)`, `SIA(17)` and `DOT(28)` are staged and log
"… is staged — not yet registered".

The daemon parses pair names with `swapPairFromString`
(`src/SwapDaemon/SwapTypes.cpp:30`), which does **not** accept the wallet's
display tickers for five pairs — send `ROBINHOOD`, `UNICHAIN`, `PLASMA`,
`PULSEX`, `MONAD`, not `RHC`, `UNI`, `XPL`, `PLS`, `MON`.
`SwapPairSdk.daemonName` carries the accepted string.

### The original 12 (unchanged)

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
- SPV mode is read-only; claim/refund requires RPC mode for UTXO chains.
- `redemption_rate_num` / `redemption_rate_denom` are declared in
  `COMMAND_RPC_GET_HEAT_METRICS` but never assigned by `on_get_heat_metrics`.
- `swf_heat_balance` does not exist in that response; the SWF figure is
  `vault_heat_swf`.
- `rust-fuego-wallet/fuego-sdk` is stale against the C++: 13 chains vs 29, an
  AMM contract that matches no RPC struct, `u64` payment-proof amounts, and a
  `scriptPubKey.addresses` read removed in Bitcoin Core 22.

### Resolved
- POLYGON is present in `swapPairToString()` / `swapPairFromString()`
  (`SwapTypes.cpp:91`, `:45-46`). The earlier note was stale.

## Hearth / ΗΞΔŦ RPC contract

**Everything goes through `fuego_walletd` on 18189.** Never straight at fuegod.

| Wallet call | Handled by | Notes |
|---|---|---|
| `heat_metrics`, `amm_quote`, `amm_pool_info`, `get_orderbook_state` | proxy re-POSTs to fuegod | fuegod's `jsonMethod` reads `request.getBody()` — query parameters are ignored |
| `mint_heat`, `swap`, `add_liq`, `remove_liq`, `place_limit_order` | proxy → wallet | these are `WalletRpcServer` methods; fuegod does not implement them |

- `COIN = 10^7` for **both** XFG and ΗΞΔŦ.
- `amm_quote.input_amount` is a uint64 of atomic units.
- `spot_price` is HEAT-per-XFG × COIN, so the human ratio is `spot_price / COIN`.
- **There is no redemption for ΗΞΔŦ.** XFG is burned to mint it; nothing
  converts it back. The daemon's JSON keys still read `redemption_price_*` /
  `redemption_rate_*` — that naming is legacy. Wallet-side the concept is the
  **mint price**, and `HeatMetrics` accepts `mint_*` keys as well so a daemon
  rename needs no wallet change.
- `mint_heat` takes `xfg_burned` **only**. walletd derives the ΗΞΔŦ side as
  `xfg_burned * spot_price / COIN`, matching `HeatMintEngine::validateMint`,
  which rejects `heatOutputs > expectedHeatFor(xfgBurned, price)`. Naming the
  ΗΞΔŦ amount client-side gets the mint rejected below parity and silently
  under-mints above it.
- `place_limit_order.price` is a human decimal; walletd scales it by COIN.
## Two different 1% fees — do not mix them up

| | Constant | Rate | Split |
|---|---|---|---|
| **Atomic swap** | `SWAP_FEE_RATE_BPS = 100` | 1% of the claim/refund amount | `SWAP_FEE_CD_SHARE_PCT 69` / `SWAP_FEE_BONUS_VAULT_PCT 11` / `SWAP_FEE_TREASURY_SHARE_PCT 20` |
| **Hearth** | `HEARTH_FEE_BPS = 100` | 1% taker fee | `HEARTH_CD_SHARE_PCT 70` / `HEARTH_MAKER_REBATE_BPS 30` |

Both are 1%, and that is the whole trap: they are separate fees on separate
paths with different splits. `swap_amount_row.dart` is the atomic-swap widget
and shows 69/11/20.
- Network fee: `MINIMUM_FEE = MINIMUM_FEE_8KH = 8000` (0.0008 XFG). The 0.008
  figure is the retired V2 fee.

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

- `types.rs`: `SwapPair` — all **29** ids (0-28), with `ticker()`,
  `daemon_name()`, `is_staged()`, `registered()`
- `chain/mod.rs`: `ChainType` — one variant per pair plus Fuego, with
  `decimals()` and `evm_chain_id()`
- `chain/mpt.rs`: RLP + Merkle-Patricia Trie + EIP-2718 receipt encoding
- `chain/bitcoin.rs`: Bitcoin-family SPV adapter (BTC, LTC, BCH, KMD, DCR)
- `chain/evm.rs`: EVM adapter with receipt-trie verification
- `chain/btc_rpc.rs` / `chain/evm_rpc.rs`: JSON-RPC clients
- `orderbook.rs`: fuegod orderbook + Hearth AMM client

### ChainType methods
- `is_bitcoin_family()`: BCH, KMD, DCR, BTC, LTC, DOGE, DASH, ZEC (8)
- `is_evm()`: ETH, ARB, BASE, BNB, POLY, GLEEC, RHC, AVAX, CRO, BOB, UNI,
  XPL, PLS, MON, OP (15)
- `decimals()`: base-unit decimals per chain
- `evm_chain_id()`: canonical id, `None` for non-EVM
- `from_symbol()`: tickers plus the daemon's aliases (`BSC`, `POLYGON`,
  `KMD_SPV`, `POLKADOT`, …)

### EVM verification
`verify_merkle` rebuilds the block's receipt trie from every receipt in the
block and compares the root against the header's `receiptsRoot`, so a receipt
cannot be invented and `verify_payment_proof` now calls it.

**It does not prove the header is canonical.** The header comes from the same
RPC and is not checked against a stored header chain. A node that lies about
which block is canonical is still believed. Do not call this full SPV until a
header store with a checkpoint lands, the way the UTXO side has one.

### Known upstream conflict
`chains.yaml` gives Monad `chainId: 143`; fuego-suite
`ChainClientConfig.cpp` defaults `monad_chain_id` to **185**. They cannot both
be right, and a mismatch makes the wrong-network guard reject every Monad
proof. The SDK follows `chains.yaml`.

## CI / Build

- Flutter: 3.44.4
- CI: ubuntu-22.04 (glibc 2.35)
- macOS app bundle: `fuego_wallet.app`
- Rust backend binary: `fuego_walletd`
- Default remote daemon: `207.244.247.64:18180`
