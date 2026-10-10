# Audit Status — 12 Items + Cross-Cutting

Branch: `master` @ `0003d50`, submodule pin `f6e3482ba`. First pass ran against
`4e261b2`/pin `55e5b13d8`; every item below was **re-verified against `f6e3482ba`**
after the pin moved. Evidence gathered by direct code reads; see per-item refs.

| # | Item | Status | Evidence |
|---|---|---|---|
| 1 | Audit escrow code for theft/inflation paths | **NOT DONE** | Only coverage is the M-2 Ed25519 domain check (`SECURITY_AUDIT_FIX_GUIDE.md`); `Blockchain.cpp:7089` `validateSwapEscrowInput` has no written threat/inflation analysis. |
| 2 | CD screen `cd::apy`/`cd::market_list` | **PARTIAL (see note)** | **Corrected 2026-10-10 — original diagnosis was wrong.** `cd::*` is a Dart-side abstraction (`lib/services/fuego_rpc_service.dart:318-325` documents `cd::market_list`→`getcdoffers`, `cd::apy`→`estimate_cd_yield`), not literal RPC — so this was never "dead code," it was a missing remap. Root cause: `cd::market_list`/`sell`/`buy`/`cancel_listing`/`apy` appeared **only** in walletd's forward lists (`core/src/server.rs:65,205`), never in a handler, so they were posted verbatim (`client.post("{url}/cd::market_list")`) to a daemon with no such route. **Fixed (remap-only):** `cd::apy` now maps to the real `/estimate_cd_yield`; the four market methods were removed from both the allowlist and the forward arm so they now fail loudly instead of rendering an empty CD screen. **But there is no backend to map them to** — fuegod's 64 routes contain no `getcdoffers`/`submitcd`/`cancelcd` (only `/estimate_cd_yield`, `/getdeposits`, `/get_maturing_deposits`, `/rollover_deposit`). A CD secondary market does not exist in the daemon. **→ RE-DO ITEM 2 FOR KILN** (DIGM credit phase): the real work is designing/implementing the CD market in fuegod, not the wiring. Do NOT treat the remap as closing this item. |
| 3 | HEAT mint fee overflow | **PARTIAL (open)** | v11 path safe (`AssetType.h:49-63`); v10 branch (`Blockchain.cpp:3686/3690/3696`) and `HeatMintEngine.cpp:59` still add unchecked. Logged open at `CHANGELOG.agent.md:3054`. |
| 4 | `m_heatSupply` overstates supply | **PARTIAL** | Tx path fixed (`Blockchain.cpp:6279,6897`); epoch sites `5279/5462/5511` still credit non-burn HEAT. Metric-only. |
| 5 | CLI wallet HEAT send/CD create | **PARTIAL** | Signing migrated to owner-bound derivation; XFG fee still missing (`WalletTransactionSender.cpp:2967,2817`); CD term uses `TESTNET_EPOCH_DURATION_BLOCKS` on mainnet (`:2833`); banking fee to dev fund not Treasury (`:2856`). |
| 6 | AMM HEAT→XFG invalid + LP unwithdrawable | **FALSE / DONE** | `Blockchain.cpp:7684` (direction 1), LP redeem via `TransactionExtraLpRemoveAuth` (`:7723`, `WalletLegacy.cpp:1046`). |
| 7a | Alias fee destination check | **FIXED** | `Blockchain.cpp:4798-4840`, stealth-key equality `4823-4824`. |
| 7b | Alias `networkId` never validates | **BROKEN (proven)** | `uint32_t networkId` (`TransactionExtra.h:191`) vs 64-bit hash (`Currency.cpp:1698-1702`); high bits `0x982d4ce7`/`0xef755446` ⇒ nonzero never passes `Blockchain.cpp:4784`. |
| 8 | CD withdrawal decoys (7 same-amount matured) | **PARTIAL** | Maturity consensus-enforced (`Blockchain.cpp:2864`), not mainnet-only; "7" is a non-binding dynamax target, both wallets fall below 8 rings. Needs design decision. |
| 9 | Dead code | **PARTIAL** | Legacy-bond removed; COLD residue still live as zero `cold_commitments` RPC (`RpcServer.cpp:2532`); pre-v11 branches reachable by design; "legacy CD decoy class" not found. |
| 10a | `/verify_payment` served | **BROKEN (dangling)** | Route at `core/src/server.rs:1072` but no daemon implementation; `PaymentProofSdk` defaults `verified:false` (`swap_models.dart:447`). |
| 10b | Dead Dart `createDeposit` | **NOT DONE** | `lib/adapters/fuego_wallet_adapter.dart:274`, zero call sites. |
| 10c | CD dialog hardcodes mainnet epoch | **NOT DONE** | `_epochBlocks = 900` (`create_cd_dialog.dart:29`); `/1440` day math ~8× optimistic (`cd_overview_screen.dart:350`); `cdConfig()` has no caller. |
| 10d | old `src/keystore.rs`,`src/wallet.rs` | **NOT DONE** | Byte-identical duplicates of `core/src/*`; root `src/` not a workspace member. |
| 10e | Seed setup documented | **PARTIAL** | Only in `AGENTS.md`; nothing user-facing. |
| 10f | Rescan from genesis on upgrade | **BY DESIGN** | `scan_version` gate forces one rescan (`wallet_service.rs:186-192`). |
| 11 | Tests / consensus tests / guardian | **PARTIAL** | gtest suite buildable (`55e5b13d8`); H-1/AMLM/treasury tests exist; no tests for networkId/alias-fee/decoy/mint-overflow; guardian not run. |
| 12 | README/docs stale XFG CDs + dev-fund | **NOT DONE** | `README.md:206,210` + ~10 doc files carry the old model. |

## Cross-cutting

- **Sub-address "Gain" not achieved** — current scheme uses the *master* view key (`fuego_crypto::derive_subaddress_keys`), so sub-addresses remain linkable; Monero-style design (own prefix, per-output tx pubkey, payment-proof changes) unimplemented in C++ wallets, payment service, Valise.
- **Walletd token check — absent.** Only localhost Host-header gate (`core/src/server.rs:701`) + loopback bind = DNS-rebinding protection, not auth. Any local process can send; on Android any network app can. Priority blocker.
  - **UPDATE 2026-10-10: RESOLVED.** Bearer-token auth now ships in walletd (`0462637`): token read from an `--auth-token-file` (never argv), presented as `Authorization: Bearer`, loopback-only on the Dart side so it can't leak to a remote seed node. Adversarial review of that change found and fixed one further leak — `status_handler` returned address+balance unauthenticated while every sibling route 401'd — now covered by `wallet_data_handlers_are_all_token_gated` (negative-control verified).
- **iOS** — plan exists (`docs/IOS_WALLETD_FFI_SCOPE.md`); none built.
- **Unlisted CRITICAL** — treasury vault key publicly derivable, `483b8b97f` (unpatched pending GATE-1 approval).
  - **UPDATE 2026-10-10: RE-VERIFIED REAL and still unpatched** at pin `f6e3482ba`. Read directly: `CryptoNoteConfig.h:310` hardcodes `VAULT_KEY_SEED[] = "xfgo_treasury_vault_v1"`, and `src/Treasury/VaultKeys.cpp:19-45` derives the spend key as `hash_to_scalar(keccak(genesisHash || VAULT_KEY_SEED))`. Both inputs are public, so anyone can recompute the spend key. This is the sole backing for every CD interest claim plus `BONUS_VAULT` and the treasury reserves. **This needs a design decision, not a patch** (rotate seed per deployment, or move vault authorization behind a real key) and touches consensus economics — gated on approval. Left unpatched by design.

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

