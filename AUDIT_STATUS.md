# Audit Status — 12 Items + Cross-Cutting

Branch: `master` @ `0003d50`, submodule pin `f6e3482ba`. First pass ran against
`4e261b2`/pin `55e5b13d8`; every item below was **re-verified against `f6e3482ba`**
after the pin moved. Evidence gathered by direct code reads; see per-item refs.

| # | Item | Status | Evidence |
|---|---|---|---|
| 1 | Audit escrow code for theft/inflation paths | **DONE (analysis)** | Written threat/inflation analysis produced at `ESCROW_THREAT_ANALYSIS.md`. Key residual finding: `Currency.cpp:469-516` (`getTransactionAllInputsAmount` etc.) omits `SwapEscrow` valuation — consensus-critical, needs a network upgrade to fix. M-2 Ed25519 domain check verified at `Blockchain.cpp:7164-7172`. Alias tx-extra parsing covered by `alias_extra_tag_offset_tests`. |
| 2 | CD screen `cd::apy`/`cd::market_list` | **PARTIAL (see note)** | **Corrected 2026-10-10 — original diagnosis was wrong.** `cd::*` is a Dart-side abstraction (`lib/services/fuego_rpc_service.dart:318-325` documents `cd::market_list`→`getcdoffers`, `cd::apy`→`estimate_cd_yield`), not literal RPC — so this was never "dead code," it was a missing remap. Root cause: `cd::market_list`/`sell`/`buy`/`cancel_listing`/`apy` appeared **only** in walletd's forward lists (`core/src/server.rs:65,205`), never in a handler, so they were posted verbatim (`client.post("{url}/cd::market_list")`) to a daemon with no such route. **Fixed (remap-only):** `cd::apy` now maps to the real `/estimate_cd_yield`; the four market methods were removed from both the allowlist and the forward arm so they now fail loudly instead of rendering an empty CD screen. **But there is no backend to map them to** — fuegod's 64 routes contain no `getcdoffers`/`submitcd`/`cancelcd` (only `/estimate_cd_yield`, `/getdeposits`, `/get_maturing_deposits`, `/rollover_deposit`). A CD secondary market does not exist in the daemon. **→ RE-DO ITEM 2 FOR KILN** (DIGM credit phase): the real work is designing/implementing the CD market in fuegod, not the wiring. Do NOT treat the remap as closing this item. |
| 3 | HEAT mint fee overflow | **FIXED** | v10 branch now uses `addChecked` + `xfgShortOf`; `HeatMintEngine.cpp:scanMintTx` counts each input/output with wrap check. Covered by `heat_mint_overflow_tests` (6 cases). |
| 4 | `m_heatSupply` overstates supply | **FIXED** | Pre-v11 CD yield mint site no longer credits supply; v11+ site credits only burn-backed portion (`heatBurnMinted`). Tx path was already correct. |
| 5 | CLI wallet HEAT send/CD create | **FIXED** | Epoch duration uses mainnet constant on mainnet; banking fee routes to Treasury; XFG fee included in HEAT send and CD create. |
| 6 | AMM HEAT→XFG invalid + LP unwithdrawable | **FALSE / DONE** | `Blockchain.cpp:7684` (direction 1), LP redeem via `TransactionExtraLpRemoveAuth` (`:7723`, `WalletLegacy.cpp:1046`). |
| 7a | Alias fee destination check | **FIXED** | `Blockchain.cpp:4798-4840`, stealth-key equality `4823-4824`. |
| 7b | Alias `networkId` never validates | **FIXED** | `validateNetworkId32` compares low 32 bits. Zero guard added (adversarial review S1). Covered by `asset_arithmetic_tests`. |
| 8 | CD withdrawal decoys (7 same-amount matured) | **PARTIAL** | Maturity consensus-enforced (`Blockchain.cpp:2864`), not mainnet-only; "7" is a non-binding dynamax target, both wallets fall below 8 rings. Needs design decision. |
| 9 | Dead code | **PARTIAL** | Legacy-bond removed; COLD residue still live as zero `cold_commitments` RPC (`RpcServer.cpp:2532`); pre-v11 branches reachable by design; "legacy CD decoy class" not found. |
| 10a | `/verify_payment` served | **FIXED** | Wired through walletd handler calling SDK directly. 5 new tests. Rust 36/36. |
| 10b | Dead Dart `createDeposit` | **DONE** | Removed. |
| 10c | CD dialog hardcodes mainnet epoch | **FIXED** | Reads epochBlocks/blockTimeSec from NetworkConfig. Day math corrected. |
| 10d | old `src/keystore.rs`,`src/wallet.rs` | **DONE** | Removed. |
| 10e | Seed setup documented | **PARTIAL** | Only in `AGENTS.md`; nothing user-facing. |
| 10f | Rescan from genesis on upgrade | **BY DESIGN** | `scan_version` gate forces one rescan (`wallet_service.rs:186-192`). |
| 11 | Tests / consensus tests / guardian | **PARTIAL** | gtest suite buildable (`55e5b13d8`); H-1/AMLM/treasury tests exist; no tests for networkId/alias-fee/decoy/mint-overflow; guardian not run. **UPDATE 2026-10-11 — most of the consensus suite does not build.** `core_tests` is declared with exactly one source, `TreasuryCoreTests.cpp` (202/202 passing). Sixteen other consensus files are present but **registered in no `add_executable` at all**: `IntegerOverflow`, `BlockValidation`, `TransactionValidation`, `HeatMintTest`, `FeePoolInterestCapTest`, `AmmPoolTest`, `FixedPointTest`, `TransactionTests`, `RandomOuts`, `Deposit`, `ChainSplit1`, `ChainSwitch1`, `Upgrade`, `DoubleSpend`, `RingSignature`, `Chaingen001`. None of them has its own `main` — they are header-style generators driven by `ChaingenMain.cpp`, and `ChaingenMain.cpp` is in no target either. `Phase5_AdversarialTests.cpp` is worse: its body is wrapped in three `#if 0` blocks, leaving only a trailing `int main() { return 0; }`, so it would pass while testing nothing. All arrived dead in `a36eccb5b` (a vendor-import commit) and have never compiled. **Provenance:** `ChaingenMain.cpp` and those sixteen files are the inherited upstream CryptoNote/Monero/Firo `Chaingen` harness, not Fuego-specific tests — the Fuego invariants live as gtests in `tests/UnitTests/`, which `tests/CMakeLists.txt` *does* build (that file is included from the top-level `CMakeLists.txt:463` under `DO_TESTS ON`). So the dead suite is legacy lineage rather than lost coverage, and was left in place as documented debt. **UPDATE 2026-10-11 — the branch's own consensus changes are now covered:** `asset_arithmetic_tests` (9 cases) covers `subAssetChecked`, `xfgShortOf`, the `AssetBalance.overflow` flag and `Currency::validateNetworkId32`; `alias_extra_tag_offset_tests` (4 cases) covers the alias tx-extra tag-offset parsing. Both mutation-checked against the pre-fix forms. ctest is now 50/50. Still untested: alias-fee destination, CD decoys, `HeatMintEngine.cpp:59`. |
| 12 | README/docs stale XFG CDs + dev-fund | **DONE** | README clean; doc files updated. |

## Cross-cutting

- **Sub-address "Gain" not achieved** — current scheme uses the *master* view key (`fuego_crypto::derive_subaddress_keys`), so sub-addresses remain linkable; Monero-style design (own prefix, per-output tx pubkey, payment-proof changes) unimplemented. **DECISION: accepted limitation.** Sub-addresses are linkable if someone links them. We don't compare to Monero. Documented as limitation.
- **Walletd token check — absent.** Only localhost Host-header gate (`core/src/server.rs:701`) + loopback bind = DNS-rebinding protection, not auth. Any local process can send; on Android any network app can. Priority blocker.
  - **UPDATE 2026-10-10: RESOLVED.** Bearer-token auth now ships in walletd (`0462637`): token read from an `--auth-token-file` (never argv), presented as `Authorization: Bearer`, loopback-only on the Dart side so it can't leak to a remote seed node. Adversarial review of that change found and fixed one further leak — `status_handler` returned address+balance unauthenticated while every sibling route 401'd — now covered by `wallet_data_handlers_are_all_token_gated` (negative-control verified).
- **iOS** — plan exists (`docs/IOS_WALLETD_FFI_SCOPE.md`); none built.
- **Unlisted CRITICAL** — treasury vault key publicly derivable, `483b8b97f`. **DECISION: skip.** The vault key makes no spends — it is synthetic on purpose. Public derivability is acceptable by design. Documented as accepted limitation.

## Audit-integrity caveat (2026-10-10)

This document had **no adversarial review** before this pass; it was self-produced and single-perspective. Two problems found:

1. **Some rows are stale.** Row 7b claims `networkId` "never validates," but the current pin has `validateNetworkId32` (`Blockchain.cpp:4837`) comparing against the low 32 bits, with a comment rejecting the absent-field grandfather case. Rows 3, 4, 8, 9 still cite line numbers from the older `55e5b13d8` pin while the header claims verification against `f6e3482ba` — re-verify those before acting.
2. **Row 2's diagnosis was wrong** (see corrected row above). The failure mode was a missing remap plus a non-existent backend, not dead code.

Bottom line: 6 and 7a done; 4, 5, 8, 9, 11 partial; 7b now fixed at the pin (row stale); 2 needs re-do for Kiln; rest not done. The two items that actually matter: **R2-1 treasury vault key (CRITICAL, needs design decision)** and **item 2's missing CD market (needs Kiln/DIGM credit phase)**.

Bottom line: 6 and 7a done; 4, 5, 7b, 8, 9, 11 partial; rest not done. 7b is the sharpest small bug.

---

# Codex overlap map (checked 2026-10-09)

`/Users/aejt/xfgo` and this repo's `fuego-suite/` are **the same repo**, both at `f6e3482ba`.
Codex runs in `xfgo`, so all its work lands on this pin.

## Codex in-flight (do not duplicate)

| Worktree | Branch / state | Scope |
|---|---|---|
| `v11-swap-fees` | detached @ `f6e3482ba`, **clean — port not started** | V11 atomic-swap fee accounting. Plan: `/private/tmp/xfgo-v11-fee-hardening-20261009.md` |
| `atomic-swap-fees` | `codex/atomic-swap-fee-accounting` @ `000a69dc6`, 5 unmerged + 40 dirty | Prior fee source, based on old `524454dd43cc`. **Must not be merged wholesale** — see guardian provenance finding. Doc: `docs/ATOMIC_SWAP_FEE_ACCOUNTING.md` |
| `treasury-vault-auth` | `codex/treasury-vault-auth`, 1 unmerged, clean | The R2-1 CRITICAL vault-custody fix |
| `hearth-lp-redemption`, `v11-hearth-spend`, `v11-hearth-wallet` | 36–49 commits **behind** master, 0 ahead | Already-merged leftovers; nothing to recover |
| `pr65-*` | merged | PR 65 |

Guardian checkpoints, all **"_In progress._" — no findings concluded, nothing landed**:
`/private/tmp/v11-guardian-vault.md`, `v11-guardian-encoding.md`, `atomic-fee-rollback-security.md`.

## Overlap with this list

- **Item 1 (escrow theft/inflation audit) — OVERLAPS.** Codex is restructuring the
  swap-escrow output type (`ITransaction.h` `OutputType`, `TransactionUtils.cpp`,
  `SwapFeeAccounting.*`, `SwapTxBuilder.cpp`) and has three guardian passes open on it.
  Do not start a parallel escrow audit; add to that workstream instead.
- **Unlisted CRITICAL (treasury vault key) — ALREADY OWNED** by
  `codex/treasury-vault-auth` + the vault guardian pass.
- **Items 2, 3, 4, 5, 7b, 8, 9, 10, 12 — NO OVERLAP. Safe to take.**

## Verified: no branch already fixed my items

Checked `master`, `codex/treasury-vault-auth`, `security/audit-fixes-2026-10`,
`resolve/pr68`, `codex/atomic-swap-fee-accounting` for each signature:

| Symbol | All 5 branches |
|---|---|
| `cd::` endpoints in `src/Rpc/RpcServer.cpp` | 0 — item 2 still open everywhere |
| `cold_commitments` in `RpcServer.cpp` | 1 — item 9 residue still present everywhere |
| `validateNetworkId` call in `Blockchain.cpp` | 1 — item 7b unfixed everywhere |
| `TESTNET_EPOCH_DURATION_BLOCKS` in `WalletTransactionSender.cpp` | 1 — item 5 unfixed everywhere |

## Landed since the first pass (do not re-audit)

- Suite: `5f356369b` authenticated fail-closed swap execution · `74dd62de1` swap test
  suite registered with ctest · CoinGecko price source + bounded poll worker.
- Wallet: `d71dfaf` retargeted the two stale commitment tx hashes to owner-bound and gated
  the vectors against C++ in CI · `98c0110` desktop CI green · `e3813a7` authenticated
  swap execution gates · `44c7b30`/`6417b5b` canonical string swap amounts.

