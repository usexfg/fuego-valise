# Audit — Hearth, ΗΞΔŦ, Swaps, Transactions

**Scope:** `lib/` Hearth AMM + orderbook, ΗΞΔŦ mint/send/balance, DeXFG atomic swaps
(peer + orderbook fill), XFG/ΗΞΔŦ transaction paths, and the `rust-fuego-wallet`
SDK chain adapters those paths depend on.
**Method:** source review plus numeric simulation of every float/precision claim.
High and critical findings were re-tested against the code to look for a reason
they do not fire; the ones that survived are below, and the ones that did not are
in *Counter-review*.

**Not verifiable from this repository:** `xfg-swapd` and `fuegod` are C++ and live in
`fuego-suite`. The JSON-RPC schemas for `swap`, `add_liq`, `remove_liq`,
`place_limit_order`, `mint_heat`, `heat_mint`, `/amm_quote`, `/amm_pool_info` and
`/heat_metrics` could not be checked against their servers. The `HashedTimelock.sol`
source referenced by `AGENTS.md` and `ChainInfo` is not in this repo. Whether ΗΞΔŦ's
atomic scale is 10^7 (the wallet assumes it is) is unconfirmed. No Dart/Flutter
toolchain is present in this container, so `flutter analyze` and `flutter test` were
not run.

---

## CRITICAL

### C1 — Filling an offer on 10 of the 22 selectable pairs initiates a **Solana** swap

`lib/bloc/dex/dex_cubit.dart:855-882` — `_pairNameForChain` maps 12 chains and ends
with `default: return 'SOL';`. `ChainTypeSdk` has 23 members. Every chain added in the
recent expansion — `avax(13) gleec(14) robinhood(15) cro(16) bob(17) unichain(18)
plasma(19) pulsex(20) monad(21) optimism(22)` — plus `fuego(0)` falls through to `'SOL'`.

That string is the `pair` the local `xfg-swapd` is told to run the counterparty leg on:

```
requestSwap()  →  _awaitFillResult()  →  _initiateAfkSwap()
                                          pair: _pairNameForChain(state.selectedChain)
```

`lib/screens/dex/dex_screen.dart:424-437` builds the pair selector from
`SwapPairSdk.values` with no filter, so all 22 are tappable, and `:1169` wires the
Fill button straight to `_requestSwap`. A user who selects the AVAX pair, fills an
AVAX offer and has a Solana keypair in Swap Settings hands the daemon a Solana swap
instruction. `'SOL'` is a pair the daemon knows, so this does not fail loudly the way
an unknown string would.

Compounding it: `ctrAmount` is the XFG atomic amount (H1), so the SOL leg is sized at
`xfg_atomic` lamports.

`test/swap_pair_expansion_test.dart` asserts the new pair ids, chain ids, tickers and
`ChainInfo.decimals[...] == 18`, and passes — it never exercises `_pairNameForChain`.
The test suite is the reason this looks covered.

**Fix:** make `_pairNameForChain` exhaustive over `ChainTypeSdk` (drop the `default:`
so the analyzer enforces it), or gate the pair selector to chains the daemon actually
carries.

---

## HIGH

### H1 — The counterparty amount is set to the XFG amount; there is no rate anywhere in the swap UI

- `lib/screens/dex/peer_swap_screen.dart:78-84`
  ```dart
  xfgAmount: (amountXfg * 1e7).toInt(),
  ctrAmount: (amountXfg * 1e7).toInt(),
  ```
- `lib/bloc/dex/dex_cubit.dart:823-827`
  ```dart
  xfgAmount: amount,
  ctrAmount: amount, // approximate; the maker's offer terms govern the on-chain lock
  ```

The peer-swap screen has exactly two inputs, `_amountController` and
`_peerController` (`:35-36`) — there is no field for the counterparty leg, so the
screen cannot express an exchange rate at all. 1 XFG (`1e7` atomic) becomes `1e7`
of the counterparty's base unit: 0.1 BTC, 0.01 SOL, 1e-11 ETH.

The orderbook path carries `SwapOfferSdk.rateNum` and exposes `rate` /
`xfgPerCounterparty`, but grep shows those getters are used only for display
(`dex_screen.dart:763, 815, 850-851, 901-905`). Nothing multiplies the XFG amount by
the rate to produce `ctrAmount`.

The inline comment asserts the daemon overrides `ctr_amount` from the offer terms.
That is a claim about `xfg-swapd`, which is not in this repo, and it is contradicted
by the peer path, where there is no offer for the daemon to read terms from.

### H2 — Every Hearth quote on a decimal amount is a quote on zero

`lib/services/fuego_daemon_client.dart:48-57`:

```dart
queryParameters: {
  'input_amount': int.tryParse(amount) ?? 0,
  'direction': sellXfg ? 0 : 1,
},
```

`amount` is `_amountController.text` from `hearth_screen.dart` — a human string.
`int.tryParse('1.5')` is `null` in Dart, so the wallet asks for a quote on `0`. An
integer entry such as `5` is sent as `5`, which under the atomic convention the model
documents is 0.0000005 XFG.

There is no `* 1e7` anywhere in `hearth_screen.dart`, `liquidity_dialogs.dart`,
`hearth_cubit.dart`, `heat_amm.dart` or the Hearth RPC methods of
`fuego_daemon_client.dart` — confirmed by grep for `1e7|10000000|atomicPerCoin|Atomic`,
which returns nothing in those files. The same untranslated strings go to `swap`,
`add_liq`, `remove_liq` and `place_limit_order`.

The reverse direction is untranslated too: `PoolInfo.price`, `.xfgBalance`,
`.heatBalance`, `.heatTotalSupply` and `AmmQuote.expectedOutput` return raw atomic
integers as strings and are rendered directly (`hearth_screen.dart:262-266`, `:928`),
so reserves, spot price and the "You receive" figure are off by 10^7, and the USD
figures derived from them (`:924-927`, `:66-70`) inherit it.

### H3 — The vault's biometric envelope is written even when biometrics are off, so the PIN is not required to decrypt it

`lib/services/fuego_vault_service.dart:465-482` — `_persistEncrypted` writes the
PIN-encrypted `.enc`, then unconditionally:

```dart
final bioKey = await _security.getOrCreateBioKey();
final bio = await _security.encryptBytesWithKey(plain, bioKey);
await File('${dir.path}/$fileName.bio').writeAsString(bio, flush: true);
```

There is no `isBiometricEnabled()` check here. `ensureBiometricEnvelope()` (`:511`)
does check — `_persistEncrypted` does not, and `createNew` calls it on every wallet
creation. So every wallet has, from birth, a second full copy of the vault encrypted
under a 32-byte key stored in `flutter_secure_storage` under `vault_unwrap_key`,
with no PIN and no biometric binding.

`SecurityService._initStorage` sets iOS `KeychainAccessibility.first_unlock_this_device`,
not `.biometryCurrentSet`. On Linux that is libsecret (open while the session is), on
Windows DPAPI (any process as that user). The biometric prompt in
`wallet_provider.dart:248` is an in-app check, and `unlockWithBiometricKey()` (`:312`)
never re-checks it — it reads the key and decrypts.

Net: `<documents>/fuego_vault_<id>.enc.bio` + the keychain entry reconstruct the seed
and spend key without the PIN. `PRODUCTION_AUDIT_REPORT.md` lists this `.bio` envelope
as a strength; it did not note that it is created unconditionally.

### H4 — Hearth swap and liquidity RPCs go to the remote seed node in cleartext, including in local-node mode

`lib/main.dart:273-279`:

```dart
BlocProvider<HearthCubit>(
  create: (_) => HearthCubit(
    hearth.FuegoDaemonClient(
      host: nodeConnection.remoteHost,
      networkConfig: _activeConfig,
    ),
  ),
),
```

`nodeConnection.remoteHost` is the seed node (default `207.244.247.64`), not
`endpoints.chainHost`. `NodeConnection` computes `chainHost = local ? '127.0.0.1' :
_remoteHost` (`node_connection.dart:298`), and `main.dart:120` applies that to the
`core` client — but grep for `updateNode` shows nothing ever re-points this Hearth
client. Desktop defaults to local mode; the Hearth tab still talks to the seed.

`FuegoDaemonClient._baseUrl` is `http://` (`:13`), so `swap`, `add_liq`, `remove_liq`
and `place_limit_order` — all value-moving intents — travel to a third party in
cleartext. An on-path attacker rewrites `min_output`, `shares` or `price` on the way
out, and fully controls the quote, reserves and orderbook coming back.

`PRODUCTION_AUDIT_REPORT.md` states "wallet JSON-RPC always via `127.0.0.1:18189`
proxy". That does not hold for the Hearth path.

(`FuegoDaemonClient.mintHeat` at `:37` shares this client but has no callers — mint
goes through `FuegoRPCService`. Not part of this finding.)

### H5 — Mint is hardcoded 1:1 while the UI quotes and receipts a TWAP amount

`lib/bloc/wallet/wallet_cubit.dart:490-496`:

```dart
// heat_minted = xfg_burned (1:1 at launch, server validates ratio)
final result = await _rpcService!.heatMint(
  xfgBurned: totalAtomic,
  heatMinted: totalAtomic,
  ...
```

`mint_heat_screen.dart` quotes `_estimatedHeat = xfg * _twapRate` where `_twapRate`
comes from `/heat_metrics` `redemption_price_num/denom` (`:63-71`), shows
`Rate: 1 XFG = N ΗΞΔŦ (TWAP)` in the confirm dialog (`:141`), and then the success
dialog prints `+${estimatedHeat} ΗΞΔŦ received` (`:281-283`) — recomputed from the
same stale rate, never from `result`. Unless TWAP is exactly 1.0, the receipt states
an amount the user did not receive.

`mint_heat_dialog.dart` is worse: it tells the user "ΗΞΔŦ received depends on PI
redemption price" (`:90`), hardcodes 1:1 (`:139-145`), then reports
`_heatReceived = xfgAtomicAmt / xfgAtomic` (`:148`) — the XFG amount, relabelled ΗΞΔŦ.

`_metrics` is loaded once in `initState` and never refreshed, and nothing bounds the
executed ratio, so there is no slippage guard on mint either.

### H6 — One mint path requires the PIN, the other does not

- `MintHeatScreen` (from `home_screen.dart:745`) → `_promptPinAndMint` →
  `WalletCubit.mintHeat` → `_security.verifyPIN(pin)` (`wallet_cubit.dart:477-480`).
- `MintHeatDialog` (from `heat_screen.dart:182`) → `_submit` →
  `context.read<FuegoRPCService>().heatMint(...)` directly (`mint_heat_dialog.dart:135-146`).
  No PIN, no balance check, no `WalletCubit`.

Two entry points to the same irreversible burn, one of which skips authorization.

### H7 — Counterparty amounts on 11 pairs are scaled by 10^7 instead of 10^18

`lib/services/swap_daemon_client.dart:317-331` — `SwapInfo.pairName` maps ids 0-11 and
returns `'PAIR_$pair'` otherwise. `ctrAmountDecimal` (`:340`) feeds that into
`ChainInfo.amountToDecimal`, which falls back to 7 decimals for unknown tickers
(`chain_info.dart:320-323`).

- ids 12-26 (GLEEC, RHC, AVAX, CRO, BOB, UNI, XPL, PLS, MON, OP) → `'PAIR_n'` → 7
  decimals instead of 18. **10^11 too large.**
- id 11 returns `'POLYGON'`, which is not a key in `ChainInfo.decimals` (the key is
  `'POLY'`) → also 7 decimals, and `explorerTxUrl('POLYGON', …)` returns `''`
  (`chain_info.dart:315`), so Polygon swaps have no explorer link.

These amounts are what `swap_card.dart:204`, `swap_amount_row.dart:114`,
`swap_receipt.dart:83` and `peer_swap_screen.dart:954` display to a user deciding
whether a swap is going right.

### H8 — Slippage protection is absent or inverted across all three Hearth actions

- **Swap:** `hearth_screen.dart:904-908` sets `minOutput: q.outputAmount` — the
  quoted output verbatim. Zero tolerance. On a live pool any adverse tick, down to one
  atomic unit, makes the swap unfillable; the quote is already stale by the time the
  user taps.
- **Add liquidity:** `add_liq` takes only `xfg_amount` and `heat_amount`
  (`fuego_daemon_client.dart:80-87`). No minimum-shares or ratio bound exists in the
  RPC, so there is nothing to protect a deposit against a reserve shift.
- **Remove liquidity:** `liquidity_dialogs.dart:180-196` checks only
  `shares.isEmpty`. Leaving both slippage boxes blank sends `min_xfg: ''` and
  `min_heat: ''`. If the daemon coerces those to 0, the withdrawal has no floor.

---

## MEDIUM

**M1 — Unknown enum ids coerce to a wrong but plausible value.**
`SwapPairSdk.fromId` → `eth` (`swap_models.dart:35-38`), `ChainTypeSdk.fromId` →
`fuego` (`:126`), `SwapLockTypeSdk.fromId` → `htlc` (`:60`), `SwapStateSdk.fromString`
→ `open` (`:145`). `SwapPairSdk` skips ids 17, 20, 21, 22, 24, so a live offer on any
of those renders as an **Ethereum** offer. A daemon state the wallet does not know
(a refund, say) renders as `open`.

**M2 — Monero swap config is collected and discarded.**
`swap_settings_screen.dart:154-162` validates the XMR spend key and the daemon/wallet
hosts and writes them to secure storage, but never adds `'xmr'` to the `chains` map
passed to `generateConfig`. `SwapConfigService.buildConfig` has no XMR branch at all
(grep for `xmr` in that file returns nothing). The key never reaches
`swap_config.json`, so `xfg-swapd` has no Monero configuration and
`DexCubit._xmrReserveProof` cannot succeed. The UI reports "Config saved".

**M3 — An EVM chain with a key but a blank RPC is silently dropped.**
`swap_config_service.dart:105` requires `cfg.rpcUrl` non-empty; the `else if` at `:117`
excludes EVM and SOL. A chain that matches neither is written nowhere and raises nothing.

**M4 — Native-coin wei conversion loses precision, and the correct helper is already in the repo.**
`web3_multi_chain_service.dart:213, 236` use `BigInt.from(amount * 1e18)`.
Simulated over 200k realistic decimal amounts: 99.9% differ from the exact value, in
both directions, worst case −8192 wei (`1.1` → +128, `2.3` → −256). The value error is
economically nil (~1e-14 ETH), but `fuego-sdk`'s EVM verifier compares
`value_wei != Some(proof.amount)` exactly (`chain/evm.rs:171-174`), so an off-by-N lock
would fail verification and sit until the timelock refund. Whether `xfg-swapd` does the
same exact compare is unverifiable here. `Erc20Amount.toBaseUnits`
(`erc20_token.dart:509-518`) already does this correctly with BigInt string parsing and
is used by the token path — just not by the native path.

**M5 — The EVM HTLC ABI encoding matches no standard HTLC (currently unreachable).**
`web3_multi_chain_service.dart:313-324` encodes `0xb06c955c` + `bytes32` + `uint256`
for lock, `0x437e2920` + `bytes32` for claim, and a bare `0x2e1a4d40` for refund.
Computed against Keccak-256, `HashedTimelock.sol`'s
`newContract(address,bytes32,uint256)` is `0x335ef5bd`; a 40-signature brute force
across plausible lock/claim/refund names and parameter shapes produced no match for
any of the three. Structurally, the lock encodes no receiver and the claim/refund
encode no contract id, so even a contract that accepted these could not know who may
claim. No Solidity source or ABI exists in this repo to check against.
`evmLockHtlc`/`evmClaimHtlc`/`evmRefundHtlc` have no UI callers, so this is latent.

**M6 — OpenAlias resolution is unauthenticated and races the confirmation dialog.**
`send_screen.dart:52-121` resolves via DNS-over-HTTPS to Cloudflare and takes the first
TXT record containing `oa1:xfg`. DoH protects the transport; nothing validates DNSSEC,
which is what OpenAlias relies on for authenticity, and no unsigned-record warning is
shown. Resolution fires on focus loss (`:47-51`), so tapping Send starts it
asynchronously while `_showConfirmDialog` reads the field synchronously — the user can
confirm a dialog showing `alice@example.com` while `_sendTransaction` (`:243-268`)
re-reads the field and sends to whatever DNS returned. Separately, the validator
short-circuits on `value.contains('@')` (`send_screen.dart:574`), so a failed
resolution still passes validation and the raw alias is submitted as an address.

**M7 — Two incompatible AMM contracts ship in one repo, and mismatches render as zeros.**
Dart calls `/amm_quote?input_amount=&direction=` and parses
`expected_output / price_impact_bps / fee`, `reserve_xfg / reserve_heat /
total_lp_shares / spot_price / epoch_swap_fees / hearth_twap`
(`heat_amm.dart`, `fuego_daemon_client.dart`). The Rust SDK calls
`/amm_quote?sell_xfg=&amount=` and parses `output_amount / price_impact`,
`xfg_reserve / heat_reserve / spot_price / xfg_heat_ratio`
(`fuego-sdk/src/orderbook.rs:94-104, 175-191`). At most one is right. Because every
Dart field falls back to `0` or `'0'` (`heat_amm.dart:278-281` and the `?? '0'`
defaults), a wrong contract produces a screen full of plausible zeros rather than an error.

**M8 — Declared fees are dropped on the wire.**
`FuegoRPCService.heatMint` (`:259-275`) and `.sendHeat` (`:277-293`) both take `fee`
and both omit it from the params. `WalletCubit` computes and passes it; the confirm
dialogs display it. The daemon applies its own.

**M9 — Hearth results are silent on both success and failure.**
`hearth_screen.dart:903` and `:866` call `executeSwap` / `placeLimitOrder` and drop the
returned `Future` — no `await`, no result, no error handling, no tx hash. The
liquidity dialogs use `try { … } finally { … }` with no `catch`
(`liquidity_dialogs.dart:85-94, 180-196`), so a failure closes the spinner and shows
nothing. `HearthCubit` returns these futures raw (`hearth_cubit.dart:75-114`).

**M10 — A float in the tx history aborts the whole load, silently.**
`core/transaction.dart:32-33` uses `(json['amount'] ?? …) as int` and
`json['fee'] as int?`. Any daemon that emits `1.0e7` throws, and the only caller wraps
it in `catch (_) {}` (`wallet_cubit.dart:280-282`), so the history goes empty with no
message. Every other model in the repo uses a tolerant `_intValue` helper.
`direction` is only ever `'in'`/`'out'` (`core/daemon_client.dart:216`), so
`isPending`/`isFailed` are always false.

**M11 — Bitcoin-family lock verification reads a field removed in Bitcoin Core 22.**
`fuego-sdk/src/chain/bitcoin.rs:185-191` reads `vout.scriptPubKey.addresses`, dropped
in favour of the singular `address` in Core 22.0. Against a modern node the array is
absent, `pays_expected` stays false, and BTC/LTC/BCH/KMD/DCR lock verification always
fails. It fails closed, so this is a liveness break, not a soundness one. The merkle
reconstruction itself (`:71-96`) is correct double-SHA-256 with proper byte-order handling.

**M12 — EVM proof amounts are u64, capping verifiable locks at ~18.44 units.**
`PaymentProof.amount: u64` (`chain/mod.rs:140`) and `parse_hex_u64_public`
(`chain/evm_rpc.rs:207-209`). u64 max is 18,446,744,073,709,551,615 wei ≈ 18.44 ETH.
Above that the parse returns `None` and verification returns false. Same ceiling in
18-decimal units for BNB, POLY, ARB and BASE.

**M13 — "SPV verified" on EVM is a single-RPC trust check.**
`chain/evm.rs:94-99` — `verify_merkle` returns
`proof.block_hash == header.hash && proof.block_height > 0`. There is no receipt-trie
proof; `verify_payment_proof` re-queries the same endpoint for the header, receipt and
transaction. The chain-id check (`:180-183`) catches a wrong network but not a
dishonest one. The UI renders this as `SPV verified at <height>` with a check mark
(`confirmation_cluster.dart:47-51, 216`, `swap_card.dart:281`).

**M14 — The offer-targeting bug the comments claim was fixed is still in the call site.**
`dex_cubit.dart:445-447` documents `selectedOffer` as the fix for "H11: `offers.first`
was orderbook-order dependent". `dex_screen.dart:1361-1363` reads
`state.selectedOffer ?? (state.offers.isNotEmpty ? state.offers.first : null)`. A user
who types an amount and taps Fill without tapping a row fills whichever offer the
daemon happened to list first. Nothing checks the entered amount against
`offer.amount` either.

**M15 — All chain private keys sit in plaintext on disk.**
`swap_config_service.dart:66-88` writes every WIF/hex key and the XFG spend key into
`swap_config.json`, then runs `chmod 600` — after the write (a window at the process
umask), best-effort inside `catch (_)`, and skipped entirely on Windows. The daemon
needs the file, so plaintext is a design constraint, but the file is never removed and
never re-protected. `configPathSync()` (`:37-43`), if it were ever called, would put
that file next to the application binary; the comment at `:78` misdescribes it as a
"/tmp fallback". It has no callers.

**M16 — The fee disclosure is a hardcoded literal.**
`swap_amount_row.dart:57-80` states "Protocol fee — 1%" with a 69/11/20 split and
"taken from the XFG leg", sourced from nothing. The amounts shown beside it are not
fee-adjusted.

---

## LOW

- **L1** `(amount * 1e7).toInt()` in `core/daemon_client.dart:199, 201` truncates
  instead of rounding. Simulated over 400k 7-dp amounts: 22,161 (5.5%) lose exactly one
  atomic unit, always downward. Same pattern at `dex_screen.dart:1375` and
  `peer_swap_screen.dart:81-82`. Cannot overspend — the balance check uses `.round()`,
  and `.toInt() ≤ .round()`. `SendTransactionRequest.toJson()` does it correctly and is
  dead code.
- **L2** `heatPegUsd = 1.58` hardcoded at `hearth_screen.dart:62, 925`. The peg tracks
  inflation by design, so the constant goes stale on its own.
- **L3** `hearth_screen.dart:298-306` substitutes `xfgHeatRatio = 0.1` when the pool is
  unavailable and renders it as "Current Mint Rate" with no unavailable state.
- **L4** `HeatMetrics.currentApy` (`heat_amm.dart:100`) renders `0.00%` from a field the
  comment says the daemon does not populate.
- **L5** `transaction_details_screen.dart:23-24` prints 8 decimals for a 7-decimal coin.
- **L6** `dex_cubit.dart:1247` — `getBalance(addr, _userAddress ?? 'eth')` passes the
  address as the chain key. No branch matches, so the DEX balance is always 0.
- **L7** Address validation is `startsWith('fire') && length == 98`
  (`send_screen.dart:575`). No base58 checksum, so a corrupted address of the right
  shape reaches the daemon.
- **L8** `_setMaxAmount` reserves `0.01` XFG (`send_screen.dart:391`) while the send
  path charges `0.008` (`:121, 271`).
- **L9** `switchEvmChain` (`dex_cubit.dart:154-174`) passes
  `Web3MultiChainService.default*Rpc`, overwriting a user-configured RPC on every switch.
- **L10** `clearStaleLockout()` (`security_service.dart:202`) deletes both the lockout
  and the attempt counter. No callers — see *Counter-review*.
- **L11** `_encryptBytes` rewrites the global `_encSaltKey` on every encrypt
  (`security_service.dart:389-391`). Harmless today — see *Counter-review*.
- **L12** `HearthState.copyWith` passes `quote: quote` and `error: error` rather than
  `?? this.…` (`hearth_cubit.dart:28-37`), so any unrelated emit drops the quote. The
  confirm handler dereferences `cubit.state.quote!` (`hearth_screen.dart:904`); the
  guard at `:614` makes this safe at build time but not against a concurrent emit.
- **L13** `submitOffer` derives the offer id from
  `cnFastHash('$pair:$amount:$rate:$timestampSeconds')` (`dex_cubit.dart:549-551`) —
  two identical offers in the same second collide.

---

## Counter-review — claims tested and downgraded

Each of these looked high or critical on first read and does not hold.

**`* 1e7` truncation is not a value bug.** A 400k-sample sweep of 7-decimal amounts
gives 22,161 mismatches, every one exactly −1 atomic unit (1e-7 XFG). The balance check
rounds and the wire truncates, so the wire amount is never larger than the checked
amount. → **LOW (L1)**, not a fund bug.

**The EVM HTLC ABI is not reachable.** `evmLockHtlc` / `evmClaimHtlc` / `evmRefundHtlc`
exist only on `DexCubit`; grep across `lib/` finds no screen that calls them. The
encoding is wrong, but no user action sends it. → **MEDIUM (M5)**, not critical.

**The PIN lockout bypass is dead code.** `clearStaleLockout()` would wipe both
`pin_lock_until_ms` and `pin_failed_attempts`, defeating the 8-attempt /15-minute
lockout on demand. Grep across `lib/` returns only the declaration. → **LOW (L10)**.

**The KDF salt desync is dead code.** `_encryptBytes` overwrites the global
`_encSaltKey` on every call, which would break any key derived through
`deriveDataKeyFromPIN`. But `_decryptBytes` uses the salt carried in the payload, and
`deriveDataKeyFromPIN` / `extractDataKeyBytes` have no callers outside
`security_service.dart`. Encrypt/decrypt stay self-consistent. → **LOW (L11)**.

**The wei imprecision is not a theft or loss vector.** Worst observed error is 8192 wei,
about 1e-14 ETH. The real consequence is an exact-equality verification mismatch
(`evm.rs:171-174`) leaving a lock stranded until refund, and I cannot confirm from this
repo that `xfg-swapd` performs that same exact compare. → **MEDIUM (M4)**.

**The Bitcoin merkle verification is correct.** `bitcoin.rs:71-96` reconstructs the root
with double SHA-256 and handles display-vs-internal byte order on both the txid and the
header root. The defect there is the `scriptPubKey.addresses` field (M11), not the proof.

**Not every silent fallback is dangerous.** `ChainTypeSdk.fromId → fuego` and
`SwapLockTypeSdk.fromId → htlc` are reached only from daemon-supplied ids; they mislead
the display but do not route funds. The routing fallback that does move funds is
`_pairNameForChain` (C1), which is why it is separated out.

---

## Suggested order of work

1. **C1** — exhaustive `_pairNameForChain`, or gate the pair selector to daemon-backed chains.
2. **H1** — add a counterparty-amount input and derive `ctrAmount` from the offer rate;
   refuse to initiate when it is unset.
3. **H3** — gate the `.bio` write on `isBiometricEnabled()` and delete stale envelopes
   when biometrics are turned off.
4. **H2 / H7 / M7** — pin the atomic-unit convention for ΗΞΔŦ and the AMM, converge the
   Dart and Rust contracts on one schema, and make a missing field an error rather than a `0`.
5. **H4** — build the Hearth client from `endpoints.chainHost` and re-point it after `connect()`.
6. **H5 / H6** — one mint path, PIN-gated, reporting the daemon's returned amount; carry
   the TWAP rate into the request or bound it.
7. **H8** — a slippage setting applied to swap, add and remove.
8. **M2 / M3** — write the XMR branch into `buildConfig`, and fail loudly on a chain that
   has a key but no transport.
9. Cover `_pairNameForChain`, `SwapInfo.pairName` and `ChainInfo.amountToDecimal` in
   `swap_pair_expansion_test.dart` — the existing test asserts the data tables and misses
   every lookup that consumes them.
