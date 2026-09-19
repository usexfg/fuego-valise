# Audit round 2 — verified against fuego-suite, and what was fixed

Round 1 (`HEARTH_HEAT_SWAP_AUDIT.md`) read `lib/` and `rust-fuego-wallet/` alone
and said so. This round reads the core repository — `usexfg/fuego-suite`
@ `5392755` — and settles every question round 1 left open. Several round-1
findings get worse, two get downgraded, and four new ones appear that were
invisible without the C++.

Ground truth cited below:

| What | Where in fuego-suite |
|---|---|
| `SwapPair` enum, ids 0-28 | `src/SwapDaemon/SwapTypes.h:77` |
| Accepted pair strings | `src/SwapDaemon/SwapTypes.cpp:30-68` (`swapPairFromString`) |
| Which pairs have a client | `src/SwapDaemon/SwapDaemon.cpp` (`registerChain`) |
| HEAT atomic scale, pool seed, fees | `src/CryptoNoteConfig.h:255-310` |
| HEAT mint rule | `src/CryptoNoteCore/HeatMintEngine.cpp:20-22,107-115` |
| AMM/metrics RPC shapes | `src/Rpc/CoreRpcServerCommandsDefinitions.h:2461-2558` |
| Body-not-query request parsing | `src/Rpc/RpcServer.cpp:74-88` (`jsonMethod`) |
| Wallet-side AMM methods | `src/Wallet/WalletRpcServer.cpp:179-190` |

---

## Settled: 10^7 is the ΗΞΔŦ scale

`CryptoNoteConfig.h`:

```
// 1 HEAT = 10^CRYPTONOTE_DISPLAY_DECIMAL_POINT = 10,000,000 atomic.
const uint64_t DIGM_PEG_HEAT = 1000000;   // 0.1 HEAT in atomic units (HEAT COIN = 10^7)
```

ΗΞΔŦ and XFG share `COIN = 10^7`. The wallet's `atomicPerCoin` is right for
both, and round 1's "unverified assumption" is closed. Everything below uses it.

---

## The Hearth decision

**Route the whole Hearth surface through the local `fuego_walletd` proxy
(`127.0.0.1:18189`). Nothing talks to a daemon directly.** Three facts force it:

**1. The write methods are wallet methods. fuegod does not implement them.**
`amm_swap`, `amm_add_liquidity`, `amm_remove_liquidity`, `place_limit_order`
and `heat_mint` live in `src/Wallet/WalletRpcServer.cpp:179-190`. fuegod's
route table (`src/Rpc/RpcServer.cpp:179-217`) has no such entries. The wallet
was POSTing `swap` / `add_liq` / `remove_liq` / `place_limit_order` /
`mint_heat` to `http://<seed>:18180/json_rpc`. Those names are the **proxy's**
vocabulary (`rust-fuego-wallet/core/src/server.rs:71`), and the proxy
translates them — but only if the request reaches the proxy. It never did.

**2. The read endpoints need a JSON body.** `jsonMethod` is
`loadFromJson(req, request.getBody())` — query parameters are never looked at.
The wallet was issuing `GET /amm_quote?input_amount=…&direction=…`. Even had
the parameters been read, `int.tryParse('1.5')` is `null`, so every decimal
amount was already a quote on zero.

**3. The proxy already does both correctly.** `is_fuegod_method`
(`server.rs:203-210`) re-POSTs `heat_metrics` / `amm_quote` / `amm_pool_info`
to fuegod with a body, and `get_orderbook_state` to `/getorderbook`.

So the Dart field names in `heat_amm.dart` were right all along — they match
`COMMAND_RPC_AMM_POOL_INFO` and `COMMAND_RPC_AMM_QUOTE` exactly. **Round 1's
M7 resolves the other way: the Rust SDK's `orderbook.rs` is the stale one**
(`xfg_reserve` / `heat_reserve` / `xfg_heat_ratio` / `output_amount` /
`price_impact` match no C++ struct). Left alone; flagged below.

---

## Findings that got worse

### ★ HEAT minting is rejected by consensus, not merely mis-displayed

Round 1 called the hardcoded 1:1 a display defect. It is not.

```cpp
uint64_t expectedHeatFor(uint64_t xfgBurned, uint64_t price) {
  return (uint128_t)xfgBurned * price / parameters::COIN;
}
...
if (heatOutputs > expectedHeat) return false;   // HeatMintEngine.cpp:115
```

`spot_price` is "HEAT atomics per XFG atomic × COIN". At the genesis seed —
`HEARTH_INITIAL_XFG 10,000` : `HEARTH_INITIAL_HEAT 1,000`, a 10:1 ratio —
`price = 0.1 × COIN`, so burning 10 XFG permits exactly 1 HEAT. The wallet
asked for `heat_minted = xfg_burned`: **ten times the permitted amount, so the
transaction is rejected.** Above parity it would instead pass and silently
under-mint, costing the minter the difference.

The canonical client math is in `SimpleWallet.cpp:4000`:
`heatAmount = xfgAmount * poolReserveHeat / poolReserveXfg`, from
`/amm_pool_info` — not from the redemption price the wallet was quoting.

In practice the mint button was already failing earlier: `heat_mint` is absent
from both `is_wallet_method` and `is_fuegod_method`, so the proxy answers
"unknown method". The correct call is `mint_heat` with **only** `xfg_burned`;
walletd then derives the HEAT side itself (`wallet_service.rs:638-648`) using
the same rule consensus checks.

**Fixed:** `mintHeat(xfgBurnedAtomic:)` sends the burn amount alone; the quote
comes from the live pool; the receipt prints only a figure the daemon returned.

### ★ The pair fallthrough is worse than ten pairs — and there is a second one

`SwapPair` has **29** members (0-28), not the 22 the wallet mirrored. The wallet
was missing `SIA(17)`, `DOGE(20)`, `DASH(21)`, `ZEC(22)`, `ZANO(24)`,
`TON(27)`, `DOT(28)`, and `SwapPairSdk.fromId`'s `orElse: eth` rendered every
one of them as an **Ethereum** offer.

`_pairNameForChain`'s `default: return 'SOL'` covered eleven `ChainTypeSdk`
values, and `'SOL'` is a pair the daemon knows, so the fill proceeded.

**New, and separate:** even the pairs that did map sent the wrong *string*.
`swapPairFromString` accepts `ROBINHOOD`, `UNICHAIN`, `PLASMA`, `PULSEX`,
`MONAD` — it does **not** accept the wallet's display tickers `RHC`, `UNI`,
`XPL`, `PLS`, `MON`. Five of the peer-swap chains could never have initiated.

**Fixed:** `SwapPairSdk` carries all 29 ids with a `daemonName` separate from
`ticker`; `tryFromId` returns null; `_chainForPair` has no `default:`, so
adding a pair is a compile error until it is mapped.

### ★ The fee disclosure names a split that does not exist

The UI states "1% — 69% CD yield / 11% bonus pool / 20% treasury". Actual:

```
HEARTH_FEE_BPS          = 100  // 1.0% Hearth taker fee
HEARTH_CD_SHARE_PCT     = 70   // 70% → CD yield pool
HEARTH_MAKER_REBATE_BPS = 30   // 30% → maker rebate
```

70/30, with no bonus pool and no treasury share. The panel also appears on the
cross-chain swap screen, where the Hearth taker fee does not apply at all.
**Fixed**, with the constant names cited in the copy.

---

## New findings, only visible against the C++

### N1 — Every hardcoded fee in the wallet is 10× the network minimum (medium)

```
MINIMUM_FEE_V2  = 80000   // 0.008 XFG  (retired)
MINIMUM_FEE_8KH = 8000    // 0.0008 XFG  BMv10+ flat fee
MINIMUM_FEE     = MINIMUM_FEE_8KH
```

`send_screen` and `mint_heat_screen` hardcode `0.008` — the retired V2 fee —
and `send_screen` reserves `0.01` on MAX. `lib/core/constants.dart` already had
`txFee = 8000` correct; nothing used it. Over-reserving, so not a loss, but the
confirm dialog quotes a fee ten times the real one and locks 0.0072 XFG out of
every send. **Fixed:** one `txFee` / `txFeeXfg` constant, used everywhere.

### N2 — The ΗΞΔŦ screen reads a provider type that is never registered (high)

`heat_screen.dart` called `context.read<FuegoDaemonClient>()` against
`services/fuego_daemon_client.dart`. `main.dart` registers
`RepositoryProvider<FuegoDaemonClient>` with the **`core/daemon_client.dart`**
class of the same name. Two distinct types, one name — the lookup could never
resolve, so opening the ΗΞΔŦ tab threw. **Fixed:** goes through `WalletCubit`.

### N3 — Four pairs are offered but have no chain client (medium)

`SwapDaemon.cpp:487-503` logs "…is staged — not yet registered" for `ZANO`,
`TON`, `SIA` and `DOT`. They exist in the enum and have source directories, but
no `registerChain` call. The daemon registers **25** of 29. `swapableChains`
listed 22 — wrong in both directions: it omitted live `DOGE`/`DASH`/`ZEC` and,
once the enum was completed, would have offered the four staged ones.
**Fixed:** `swapableChains` is the 25 live pairs, `stagedChains` is the 4, and
the selector is gated on the live set.

### N4 — `redemption_rate_*` is declared and never assigned (low, upstream)

`COMMAND_RPC_GET_HEAT_METRICS::response` declares `redemption_rate_num` and
`redemption_rate_denom`, and `on_get_heat_metrics` assigns every other field
but not those two. The wallet rendered `redemptionRate * 100` as a confident
`0.00%` APY. **Fixed** wallet-side (null ⇒ `—`); the daemon should populate
them or drop them. `swf_heat_balance` is likewise read by the wallet and does
not exist in the struct — the real field is `vault_heat_swf`. **Fixed.**

---

## Round-1 findings downgraded by the C++

- **M7 (two incompatible AMM contracts)** — not symmetric. The Dart field names
  are correct against `CoreRpcServerCommandsDefinitions.h`; the Rust SDK's
  `orderbook.rs` is stale. Downgraded to a cleanup, not a correctness risk.
- **M8 (fee dropped by `sendHeat`/`heatMint`)** — the walletd proxy's
  `send_heat` takes no fee at all and the C++ handlers fall back to
  `m_currency.minimumFee()` when `fee == 0`. Dropping it is harmless; the
  defect is the *displayed* fee (N1). Downgraded to low.
- **AGENTS.md "12 pairs"** — stale. The daemon carries 29 ids and registers 25.
  The "POLYGON missing from `swapPairToString()`" known-issue is also stale;
  it is present at `SwapTypes.cpp:91`.

---

## What was changed

| Finding | Change |
|---|---|
| C1 pair fallthrough | `SwapPairSdk` = all 29 ids + `daemonName`; `_pairNameForChain` deleted; `_chainForPair` exhaustive |
| — | `tryFromId` / `tryFromName` / `tryFromString` return null instead of coercing to ETH / Fuego / HTLC / open |
| H1 counterparty amount | `counterpartyAmountFor()` derives the CTR leg from the offer's `rateNum` in exact BigInt math; peer swap gained a counterparty-amount field; both paths refuse rather than guess |
| H2 Hearth units | `parseAtomic()` — exact decimal-string → atomic, no double; used on every Hearth and send input |
| H3 vault `.bio` | envelope written only when biometrics are enabled; `purgeBiometricEnvelopes()` on disable |
| H4 remote plaintext | Hearth built on `FuegoRPCService` (local proxy); the direct-to-seed client is deprecated |
| H5 mint ratio | `mint_heat` with `xfg_burned` only; pool-rate quote; receipt shows only daemon-returned figures |
| H6 mint PIN | `MintHeatDialog` goes through `WalletCubit.mintHeat` and prompts for the PIN |
| H7 decimals | `SwapInfo.pairName` derives from `SwapPairSdk`; `ctrAmountDecimal` is nullable; `amountToDecimal` no longer defaults to 7 |
| H8 slippage | `slippageBps` on `HearthState`, applied to `min_output`; both remove-liquidity minimums required |
| M2 XMR config | `XmrChainConfig` written as `xmr_spend_key` / `xmr_view_key` / `xmr_{daemon,wallet}_{host,port}` |
| M3 silent drop | `lastSkippedChains` surfaced in Swap Settings |
| M4 wei precision | `sendEth` / `lockHtlc` / `sendSol` take decimal strings through `Erc20Amount.toBaseUnits` |
| M6 OpenAlias | resolution runs before the confirm dialog; full address shown; unresolved alias fails validation; DNSSEC caveat stated |
| M9 silent errors | every Hearth write returns `HearthResult`; read failures get a retry banner |
| M10 tx parse | tolerant numeric reads; one float no longer empties the history |
| M14 `offers.first` | fill requires a tapped offer; amount checked against the offer |
| M16 fee split | 70/30, named from the chain constants |
| N1 fee | `txFee` / `txFeeXfg` everywhere |
| N2 provider | ΗΞΔŦ screen on `WalletCubit` |
| N3 staged pairs | `swapableChains` = 25 live; `stagedChains` = 4 |
| N4 metrics | APY null-when-unreported; `vault_heat_swf` |
| L1 truncation | `parseAtomic` is exact; also caught and guarded the uint64 ceiling (~9.22 tokens on an 18-decimal chain) |

Tests: `swap_pair_expansion_test.dart` rewritten to exercise the **lookups**
(the old version asserted the tables and passed while every lookup was broken);
`atomic_units_test.dart` added for the unit conversions, pool scaling and fee.

---

## Still open

1. **`rust-fuego-wallet/fuego-sdk` is stale against the C++.** `ChainType` has
   13 chains vs 29; `orderbook.rs` speaks a dead AMM contract;
   `PaymentProof.amount` is `u64`, capping EVM verification at ~18.44 units of
   an 18-decimal coin; `bitcoin.rs` reads `scriptPubKey.addresses`, removed in
   Bitcoin Core 22. Not on the wallet's runtime path, so not fixed here — but
   anything built on the SDK inherits all four.
2. **EVM "SPV" is a single-RPC trust check.** `evm.rs verify_merkle` is
   `block_hash == header.hash && height > 0`. The UI says "SPV verified".
3. **`_encodeLockCall` / `_encodeClaimCall` / `_encodeRefundCall`** still encode
   selectors matching no known HTLC ABI, with no receiver and no contract id.
   No UI caller, so unreachable; left in place pending the real contract ABI,
   which is not in either repository.
4. **`kHeatPegUsd = 1.58`** is a hardcoded snapshot of a CPI-tracking peg.
   fuego-suite carries it only as a comment. It belongs in
   `COMMAND_RPC_GET_FUEGO_PRICE`, which already has a `heat_peg_usd` field.
5. **DOGE / DASH / ZEC reserve proofs.** Live pairs, but no verified P2PKH
   version bytes here, so they take the explicit "not supported in-app" branch
   rather than signing for a Bitcoin address.
6. **SIA's 24 decimals exceed int64** — `ctr_amount` is a uint64, so a
   meaningful Sia amount cannot be expressed. Moot while SIA is staged.
7. **`lib/services/fuego_daemon_client.dart`** is now unused and marked
   deprecated. Deleting it needs your say-so.
8. **`AGENTS.md`** still documents 12 pairs and a stale POLYGON known-issue.
