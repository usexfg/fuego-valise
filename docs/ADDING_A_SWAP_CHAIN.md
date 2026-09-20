# Adding a swap chain

How to promote an EVM chain from the wallet's ERC-20 layer to a full atomic
swap pair. Every file path and line number below was read from
`usexfg/fuego-suite` at `5392755` and `usexfg/fuego-valise` on
`claude/fuego-hearth-audit-gwym9k`. Where a line number is given it was
verified, not inferred.

---

## Read this first: four mappings, no compiler diagnostic

Adding a value to `SwapPair` requires updating **four** independent mappings in
fuego-suite. Three of them have a `default:` branch, and the fourth is in a
switch that produces no warning because **`-Wall` is not set for C++** —
`CMakeLists.txt:63` and `:423` set only `-std=c++17` and `-Wno-*`
suppressions, and the `-Wall -Wextra` at `:424` applies to `CMAKE_C_FLAGS`,
not `CMAKE_CXX_FLAGS`. There is no `-Werror` anywhere.

So a forgotten mapping is **silent at compile time and wrong at runtime**:

| Mapping | File | Silent fallback if you forget |
|---|---|---|
| Decimals | `PriceOracle.cpp:172`, `default:` at `:202` | **`1e8`** — an 18-decimal EVM chain's amounts come out 10¹⁰ off |
| Price (live) | `PriceOracle.cpp:97`, `default:` at `:127` | `0.0` — every quote is zero |
| Price (seed) | `PriceOracle.cpp:133`, `default:` at `:163` | `0.0` — same, on the seed path |
| Block time | `SwapTimelock.cpp:9`, `default:` at `:39` | `600000` ms — a 2 s L2 gets a 10-minute block estimate, so timelocks are ~300× too long |
| Name → enum | `SwapTypes.cpp:29` (`swapPairFromString`) | Returns `false` → "Unknown swap pair". Loud, at least. |
| Enum → name | `SwapTypes.cpp:78` (`swapPairToString`) | Falls past the switch to `return "???"` |

The decimals one is a money bug, not a cosmetic one. Treat the checklist at
the end of this document as mandatory rather than advisory.

`isLegacyUtxoPair` (`SwapTypes.h:127`) has a `default: return false` at
`:139`, which is correct for EVM chains — they take the keccak256 hashlock. Do not add an EVM
pair to it.

---

## The hard constraint: one HTLC address for all EVM chains

`applyHtlcConfig` is called with `chainCfg.ethHtlcRegistry` for **11** of the
EVM registrations (`SwapDaemon.cpp`, grep `applyHtlcConfig`). There is exactly
one shared registry field (`SwapDaemon.h:89`) plus a GLEEC-specific override
(`:198`). There is no per-chain registry key.

**HashedTimelock must therefore live at the same address on every EVM chain
the daemon talks to.** That means a deterministic deployment — CREATE2 with a
fixed salt, or a fresh deployer key used at nonce 0 on each chain. If you
deploy ad hoc on a new chain, you get a different address, and either that
chain or all the others break.

This is the real gating item for adding an EVM chain. The code changes below
are an afternoon; getting the contract deployed at the right address on a new
chain is the part that needs planning. If a chain genuinely cannot host the
contract at the shared address, the fix is to add a per-chain registry field
the way GLEEC already has one — do that rather than moving everyone else.

Without a registry set, the daemon logs
`eth_htlc_registry not set — lock/claim will fail until configured`
(`SwapDaemon.cpp:121-122`) and registers the client anyway. The chain will
appear available and fail at lock time.

---

## Candidates: the 18 wallet-only chains

`chains.yaml` carries 33 EVM chains in two tiers. `tier: swap` (15) have a
`SwapPair` id; `tier: wallet` (18) do not, so they are ERC-20 only — balances,
send, approve, custom tokens, no atomic swap.

| Chain | Chain ID | Registry tokens | Notes for swap promotion |
|---|---|---|---|
| Linea | 59144 | USDC | zkEVM; standard EVM RPC |
| ZKsync Era | 324 | USDC | **Native AA / different tx envelope** — `EthRpcClient` may not sign correctly; verify before committing |
| HyperEVM | 999 | USDC | Dual-VM chain; confirm EVM block finality semantics |
| Ink | 57073 | USDC, oUSDT | OP Stack, like Optimism |
| Plume | 98866 | USDC | Standard EVM |
| Soneium | 1868 | USDT, USDC.e, oUSDT | OP Stack, like Optimism |
| Sei | 1329 | USDC | EVM + Cosmos dual; use the EVM RPC only |
| Rootstock | 30 | — | Bitcoin sidechain, EVM-compatible; gas is RBTC |
| Gnosis | 100 | — | Gas is xDAI, **not** an 18-decimal ETH-like premium token — check the price seed carefully |
| Flare | 14 | — | Standard EVM |
| Kaia | 8217 | — | Klaytn successor; EVM-compatible, own gas model |
| Scroll | 534352 | — | zkEVM |
| Abstract | 2741 | — | ZK Stack, same AA caveat as ZKsync |
| Doma | 97477 | — | Verify chain id and finality before wiring |
| Beam | 4337 | — | Avalanche subnet |
| Moonriver | 1285 | — | Substrate EVM (Frontier); `eth_*` RPC works |
| peaq | 3338 | — | Substrate EVM |
| Tempo | 4217 | — | **No native gas token** — `eth_getBalance` returns a constant. Fee estimation and refund accounting both assume a payable native asset; this one needs design work, not just wiring |

"Registry tokens" is whether `Erc20Registry` already carries a verified
stablecoin there (`lib/models/erc20_token.dart`). It is unrelated to swap
capability — the swap leg moves the **native** asset.

The easy set is Linea, Ink, Plume, Soneium, Flare, Moonriver, peaq, Scroll:
ordinary EVM chains where `EthChainClient` should work unchanged. ZKsync,
Abstract and Tempo are not drop-ins.

---

## Part A — fuego-suite (C++)

Worked example: promoting Linea (chain id 59144).

### A1. Append to the enum

`src/SwapDaemon/SwapTypes.h:77` (`enum class SwapPair : uint8_t`)

```cpp
  OPTIMISM = 26,   // :104
  TON = 27,
  DOT = 28,
  LINEA = 29       // append only
```

**Never renumber.** The id is persisted as a raw `uint8` —
`SwapStateMachine.cpp:246` writes `static_cast<uint8_t>(m_params.pair)` into
the swap's JSON and `:446` casts it straight back. It is also on the wire
(`SwapInfo.pair`) and mirrored in the wallet's `SwapPairSdk`. Renumbering
silently reassigns every persisted swap to a different chain.

### A2. Both string mappings

`src/SwapDaemon/SwapTypes.cpp` — `swapPairFromString` (`:29`) and
`swapPairToString` (`:78`):

```cpp
  if (iequal(p, "LINEA", n)) { out = SwapPair::LINEA; return true; }
```
```cpp
    case SwapPair::LINEA: return "LINEA";
```

Name the pair after the **chain**, not after something running on it.
`PULSEX = 23` is the counterexample already in the tree: PulseX is a DEX on
PulseChain, and the suite's own dashboard already renders it correctly as
`name: 'PulseChain'` (`dashboard/static/js/swapxfg.js:45`) while the enum and
every wire string still say PULSEX.

Mind the length guard at `SwapTypes.cpp:30`: names must be 3–12 characters.

If you add an alias (the file already has `KMD`/`KMD_SPV` at `:39-40`,
`POLY`/`POLYGON` at `:45-46`, `OP`/`OPTIMISM` at `:64-65`, `SC` for SIA,
`PULS` for PULSEX, `POLKADOT` for DOT), add it to `swapPairFromString` only.
`swapPairToString` must keep emitting exactly one canonical string.

### A3. Config fields and parser

`src/SwapDaemon/SwapDaemon.h`, in `struct ChainClientConfig` (`:51`), matching
the OP block at `:310-315`:

```cpp
  std::string lineaHost;
  uint16_t    lineaPort       = 8545;
  std::string lineaPrivKeyHex;
  std::string lineaAddress;
  uint64_t    lineaChainId    = 59144;
  std::string lineaHtlcBinPath;
```

`src/SwapDaemon/ChainClientConfig.cpp`, matching `:313-319`:

```cpp
  // Linea (zkEVM L2, chain id 59144)
  out.lineaHost       = jsonGetStr (json, "linea_rpc_host", "");
  out.lineaPort       = static_cast<uint16_t>(jsonGetUint(json, "linea_rpc_port", 8545));
  out.lineaPrivKeyHex = jsonGetStr (json, "linea_priv_key");
  out.lineaAddress    = jsonGetStr (json, "linea_address");
  out.lineaChainId    = jsonGetUint(json, "linea_chain_id", 59144);
  out.lineaHtlcBinPath= jsonGetStr (json, "linea_htlc_bin", out.ethHtlcBinPath);
```

And validation, alongside `:488-490`:

```cpp
  if (!validateHex(out.lineaPrivKeyHex, 32, "linea_priv_key", errorMsg)) return false;
  if (!out.lineaAddress.empty() && out.lineaAddress.rfind("0x", 0) != 0) {
    errorMsg = "linea_address must start with 0x";
    return false;
  }
```

Get the chain id right. `chains.yaml` and the C++ already disagree on Monad:
the yaml says **143** (correct — 10143 is Monad testnet), while
`ChainClientConfig.cpp:310` and `SwapDaemon.h:306` both default
`monad_chain_id` to **185**. A mismatch makes the wrong-network guard reject
every proof for that chain. The C++ default is the one to fix.

### A4. The chain client header

`src/SwapDaemon/Linea/LineaChainClient.h` — header-only, no `.cpp`, exactly
like `Optimism/OptimismChainClient.h`:

```cpp
#pragma once
#include "../Ethereum/EthChainClient.h"

namespace XfgSwap {
class LineaChainClient : public EthChainClient {
public:
  LineaChainClient(std::unique_ptr<EthRpcClient> rpc,
                   const std::string& address)
    : EthChainClient(std::move(rpc), address, "LINEA") {}
};
}
```

The string passed to the base constructor is the client's `chainName()` and
shows up in error messages — keep it identical to `swapPairToString`.

Header-only means no `CMakeLists.txt` change. Add a `README.md` beside it; the
existing per-chain READMEs (`Optimism/README.md`) carry the chain parameters
and an integration checklist, and they are the closest thing the suite has to
this document.

### A5. Registration

`src/SwapDaemon/SwapDaemon.cpp`, matching the OPTIMISM block at `:459-469`:

```cpp
  // LINEA
  if (!chainCfg.lineaHost.empty()) {
    auto rpc = std::make_unique<EthRpcClient>(chainCfg.lineaHost, chainCfg.lineaPort,
        chainCfg.lineaPrivKeyHex, chainCfg.lineaAddress, chainCfg.lineaChainId);
    applyHtlcConfig(*rpc, chainCfg.lineaHtlcBinPath, chainCfg.ethHtlcRegistry, m_logger, "LINEA");
    applyPtlcConfig(*rpc, chainCfg.ethPtlcRegistry, m_logger, "LINEA");
    m_chainRegistry.registerChain(SwapPair::LINEA,
        std::make_unique<LineaChainClient>(std::move(rpc), chainCfg.lineaAddress));
    m_logger(Logging::INFO) << "LINEA chain client registered: "
      << chainCfg.lineaHost << ":" << chainCfg.lineaPort;
  }
```

Plus the `#include` at the top of the file.

Registration is gated on a non-empty host, so a chain nobody configured costs
nothing. If the client is not ready, follow the staged pattern at `:487-502` (ZANO `:489`, TON `:493`, SIA `:497`, DOT `:501`) —
log `… is staged — not yet registered` and **do not** call `registerChain`.
That is what ZANO, TON, SIA and DOT do today, and it is why they appear in the
enum but cannot swap.

### A6. The three silent mappings

`src/SwapDaemon/PriceOracle.cpp` — all three switches:

```cpp
static const double SEED_LINEA_USD = 0.00;   // ETH-denominated; set a real seed
…
    case SwapPair::LINEA: return SEED_LINEA_USD / xfgUsd;        // :97  switch
    case SwapPair::LINEA: return SEED_LINEA_USD / SEED_XFG_USD;  // :133 switch
    case SwapPair::LINEA: return 1e18;   // wei                  // :172 switch
```

Linea's gas token is ETH, so its seed should track ETH, not be an independent
guess. The same is true of every OP-Stack and ETH-gas L2 in the table above.

`src/SwapDaemon/SwapTimelock.cpp:9`:

```cpp
    case SwapPair::LINEA: return 2000;  // ~2s/block
```

The `default:` here returns 600000 ms and the comment calls it "conservative
(safe: overestimates CTR)". Overestimating is safe for correctness and awful
for UX — the counterparty waits through a timelock computed as if blocks took
ten minutes.

### A7. Dashboard

`dashboard/static/js/swapxfg.js:16` (the pair list) and `:45-48` (the
`icon`/`color`/`ticker`/`name` map), plus an `<option>` in
`dashboard/static/swapxfg.html` near `:92-103`, and an icon under
`dashboard/static/coin-icons/`.

The `name` field here is user-facing. This is where the PulseChain/PulseX
split already exists and where a new chain's display name should be correct
from the start.

---

## Part B — fuego-valise (Dart wallet)

### B1. `chains.yaml` → regenerate

Flip the chain's `tier` from `wallet` to `swap`, then:

```
dart run tool/gen_chains.dart
```

Do not hand-edit `lib/models/chain_registry.g.dart`. The generator formats its
own output and `dart run tool/gen_chains.dart --check` is asserted by
`test/chains_registry_test.dart`, so a hand edit fails CI.

`ChainInfo.walletOnlyChains` derives from `kWalletTierKeys`, so the tier flip
moves the chain automatically.

### B2. `lib/models/swap_models.dart`

`SwapPairSdk` — append with the **same id as the C++**, and set `daemonName`
to a string `swapPairFromString` accepts:

```dart
  linea(29, 'LINEA', 'XFG/LINEA', 'LINEA'),
```

`ChainTypeSdk` — append. Its ids are wallet-internal and deliberately not the
`SwapPair` ids; the enum says so at `:113-115`. Add the chain to `isEvm`
(`:153`). Do **not** add it to `isBtcFamily`.

`test/swap_pair_expansion_test.dart` asserts `ChainTypeSdk.values.length ==
SwapPairSdk.values.length + 1`, so both enums move together or the test fails.

### B3. `lib/bloc/dex/dex_cubit.dart`

`_chainForPair` (`:340`) has **no `default:`** — deliberately, because a
`default` there used to route ten pairs to Solana. Adding a `SwapPairSdk`
value without a case is a Dart compile error. This is the one place in either
codebase where the compiler helps you.

### B4. `lib/models/chain_info.dart`

Add the ticker to `swapableChains` (`:468`) only once the daemon actually
registers the client. A chain listed here but staged in C++ offers the user a
swap that fails. `stagedChains` (`:501`) exists for exactly that case.

Also add entries to `ChainInfo.names` (`:15`), `.decimals` (`:271`) and
`.colors` (`:365`) — a test asserts every swapable ticker has all three.

### B5. `lib/services/swap_config_service.dart`

`_evmSwapChains` derives from `kChains` where `family == 'evm' && tier ==
'swap'`, so B1 covers it. Add an entry to `_daemonConfigPrefixes` (`:11`) only
if the daemon's config key prefix differs from the chains.yaml key — as it
does for `xpl`→`plasma` and `pls`→`pulsex`.

### B6. Update the test tables

`test/swap_pair_expansion_test.dart` holds a transcription of the full
`swapPairFromString` table. Add the new pair's accepted-string set there, or
the "daemonName is a string swapPairFromString accepts" test fails — which is
the point.

---

## Part C — Rust SDK

`rust-fuego-wallet/fuego-sdk/fuego-sdk/src/`:

- `types.rs` — `SwapPair`: add the variant plus its `ticker()`,
  `daemon_name()`, `is_staged()` and `registered()` arms.
- `chain/mod.rs` — `ChainType`: append the variant. **Order matters**: this
  enum is `Fuego` followed by the `SwapPair` order, so a new pair appends at
  the end. Add `decimals()` and `evm_chain_id()` arms, and the symbol and any
  aliases to `from_symbol()`.
- `chain/evm.rs` — nothing, if the chain uses the standard receipt-trie path.

`tests/swap_pairs.rs` holds a `(ticker, daemon_name)` table that must match.

---

## Verification checklist

Nothing here is optional; three of the first four have no compile-time signal.

**fuego-suite**
- [ ] `SwapTypes.h` — appended, not renumbered
- [ ] `swapPairFromString` — accepts the canonical name (and any alias)
- [ ] `swapPairToString` — emits exactly one canonical name
- [ ] `PriceOracle.cpp` — **all three** switches (live price, seed price, decimals)
- [ ] `SwapTimelock.cpp` — real block time, not the 600000 ms default
- [ ] `ChainClientConfig.cpp` — parse + validate, chain id matching `chains.yaml`
- [ ] `SwapDaemon.h` — config struct fields
- [ ] `SwapDaemon.cpp` — `#include` + registration block
- [ ] HashedTimelock deployed at the shared `eth_htlc_registry` address
- [ ] Dashboard: `swapxfg.js` list + map, `swapxfg.html` option, icon
- [ ] Per-chain `README.md`

**fuego-valise**
- [ ] `chains.yaml` tier flipped, `gen_chains.dart` re-run
- [ ] `SwapPairSdk` id matches the C++ exactly
- [ ] `ChainTypeSdk` appended and added to `isEvm`
- [ ] `_chainForPair` case added (compiler enforces)
- [ ] `ChainInfo` decimals / names / colors, and `swapableChains` only once registered
- [ ] `swap_pair_expansion_test.dart` accepted-string table updated

**Rust SDK**
- [ ] `SwapPair` + `ChainType` variants, `decimals()`, `evm_chain_id()`, `from_symbol()`
- [ ] `tests/swap_pairs.rs` table

**End to end**
- [ ] `--swap-config` with the chain's RPC host; confirm the daemon logs
      `<CHAIN> chain client registered` and **not** the
      `eth_htlc_registry not set` warning
- [ ] A quote returns a non-zero rate (proves the PriceOracle arms landed)
- [ ] An amount round-trips at the right magnitude (proves the decimals arm
      landed — a 10¹⁰ error is what 1e8-instead-of-1e18 looks like)
- [ ] Lock → claim on testnet before mainnet

---

## Known upstream items this touches

- `PULSEX = 23` is named after a DEX on PulseChain rather than the chain.
  `swapPairToString` emits it, so the wallet has to send it; fixing it means
  adding `PULSECHAIN` to `swapPairFromString` and renaming the constant.
- `KMD_SPV = 6` keeps an SPV-first suffix and is emitted even in RPC mode.
  Plain `KMD` parses, so this is cosmetic.
- Monad's chain id is 143 in `chains.yaml` and 185 in the C++
  (`ChainClientConfig.cpp:310`, `SwapDaemon.h:306`). 143 is correct; 10143 is
  the testnet id. The C++ default needs changing.
- `-Wall` is absent from `CMAKE_CXX_FLAGS`, which is why none of this is
  caught at build time. Turning it on for the SwapDaemon target would convert
  the `swapPairToString` omission into a visible `-Wswitch` warning; the three
  `default:` branches would still need removing to get the same protection.
