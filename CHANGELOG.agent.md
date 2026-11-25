# CHANGELOG.agent.md

## [2026-11-10] Mobile CI iOS simulator FFI missing

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 121 | iOS mobile CI failed at Build for simulator: Xcode could not find `rust-fuego-wallet/target/x86_64-apple-ios/release/libfuego_ffi.a` (force_load in OTHER_LDFLAGS). The Xcode build phase script only builds arches present in $ARCHS; on the arm64 macos-latest runner the simulator build still referenced the x86_64 slice. Pre-build all three iOS targets in the workflow before flutter build. Updated artifact upload to the simulator .app path. | grok | 2026-11-10 | ✅ fixed in `.github/workflows/fuego-wallet-mobile-ci.yml` |

### Sign-off

| Check | Result |
|-------|--------|
| Source change | CI workflow only; no source edits |
| Expected | Next mobile CI run should produce the static libs and complete the iOS simulator build |

## [2026-11-10] Desktop CI binary name mismatch (unifyd vs unified)

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 120 | Build Linux and Build macOS failed at "Build backends" with `unifyd missing after the PaymentGateService build`. The PaymentGateService target links `src/unified`. AGENTS.md and prior task 76 document the binary as `unified`. The composite actions looked for and installed `unifyd`. | grok | 2026-11-10 | ✅ fixed in `.github/actions/build-desktop-backends/action.yml` and `bundle-desktop-backends/action.yml` |

### Sign-off

| Check | Result |
|-------|--------|
| Source change | CI workflow actions only; no suite source edits |
| Expected | Next CI run should locate `unified` and complete desktop builds |


## [2026-10-04] Merge Colin's owner-bound commitment keys into the audit branch

Merge `origin/feat/owner-bound-commitment-keys` (`51598e6`) into `origin/claude/okoc-valise-daemon-audit-1niqzp` (`5f32382`), fork `75034c0`. 4 files / 25 hunks. Performed in a scratch worktree; the dirty working tree was not touched. **Not pushed.**

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 112 | Resolve `transaction_builder.rs` (11 hunks) by keeping our side | opencode | 2026-10-04 | Done; ours carries `ddb7d12`, which changed every builder signature `view_pub` -> `view_secret`. Colin's side seeds `r = Hs(viewPub ‖ inputsHash)`, and his file has 4 `deterministic_tx_key(view_pub` against our 6 `deterministic_tx_key(view_secret`. Taking his side would have re-exposed `r` to anyone knowing the sender's address, defeating owner-bound commitments |
| 113 | Resolve `phase7_vectors.rs` (7 hunks) by keeping our side | opencode | 2026-10-04 | Done; keeps the C++ `parseAndValidate` round-trip hashes `e39df476…` / `7006fa39…` and clears Colin's 2 failures |
| 114 | Resolve `wallet_service.rs` (5 hunks) by keeping our side + his comment | opencode | 2026-10-04 | Done; his entire diff to this file was 5 `spend_pub` lines we already had plus one comment |
| 115 | Resolve `scanner.rs` (2 hunks) by keeping ours and adding his legacy-account loop | opencode | 2026-10-04 | Done; **taking his side wholesale would have regressed two things** — it drops `state.owners.insert` for commitments, which breaks the existing `commitments_found_owner_bound_by_owner_and_legacy` owner assertions, and it raises `highest_subaddress` with a *legacy keypair index*, corrupting the suite-sub-address lookahead |
| 116 | Close the partial gap in his fix | opencode | 2026-10-04 | His `None` fallback still uses the master `derivation`, so a legacy-*form* commitment at a legacy account is still missed on his branch. The merged loop tries owner-bound then legacy-form, each under the account's own derivation |
| 117 | Add regression test `commitments_found_on_legacy_accounts` | opencode | 2026-10-04 | Done; **negative control**: with the patch removed it fails `left: 0, right: 2`, independently reproducing the gap. With the patch, both commitments are found and every recorded scalar opens its key |
| 118 | Route our builder helper onto Colin's `ring.rs` wrapper | opencode | 2026-10-04 | Done; his 4 wrappers auto-merged and all compile. `owner_bound_commit_key` now calls `derive_owner_bound_commit_key`, so the factoring is shared without any regression |
| 119 | Record that `b8b0e93`'s commit message overclaims | opencode | 2026-10-04 | `CommitmentEntry.exposed` and `SCAN_VERSION 3` are named in the message but exist in neither branch. Noted in task 110 of the 2026-10-04 entry above |

### Sign-off

| Check | Result |
|-------|--------|
| `cargo build --workspace` | ✅ clean, no errors, no warnings |
| `cargo test --workspace` | ✅ **115 passed, 0 failed** (fuego-crypto 20, fuego-ffi 6, fuego-sdk 65, walletd 24) |
| Both vector suites coexist | ✅ `ownerbound_vectors` (Colin's, 70 vectors) **and** `commitment_owner_bound_vectors` (ours) both pass; `crosscheck_ownerbound_vectors` proves parity 70/70 |
| `phase7_vectors` | ✅ 10/10; Colin's 2 failures cleared |
| Regression test negative control | ✅ fails `0 vs 2` without the patch, passes with it |
| Byte-vector parity negative control | ✅ flipping one expected byte fails the assert |
| All tasks done | Merge resolved and verified in a scratch worktree. **No push, no PR** |
| `flutter test` | ✅ **72 passed, 0 failed** — includes Colin's 13 `swap_pair_drift_test.dart` |
| `flutter analyze --no-pub --fatal-warnings --no-fatal-infos` | ✅ exit 0; 0 errors, 0 warnings (780 info-level, pre-existing) |
| Scope | Merge + scanner fix + two test files. The pre-existing dirty working tree, local branches and refs were left untouched |

## [2026-10-01] Swap-pair drift: 10 DeXFG pairs rendered as `PAIR_<n>`

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 90 | `SwapInfo.pairName` (`swap_daemon_client.dart`) carried a private 0-11 id table. Pairs with ids ≥ 12 — GLEEC(12), RHC(13), AVAX(14), CRO(15), BOB(16), UNI(18), XPL(19), PLS(23), MON(25), OP(26) — resolved to `PAIR_12`..`PAIR_26`, so **10 of the 22** DeXFG pairs lost name, colour, icon, decimals and explorer link, and their Direct-tab filter chips could never match. Now derived from `SwapPairSdk` | opencode | 2026-10-01 | ✅ done |
| 91 | `POLYGON` vs `POLY` key mismatch: three emitters returned `'POLYGON'` (`swap_daemon_client.dart`, `daemon_event_bus.dart`, `dex_cubit._pairNameForChain`) while every `ChainInfo` map is keyed `'POLY'`. Dead explorer link, dead POLY filter chip, default 7-decimal formatting on Polygon. All three now emit `'POLY'` | opencode | 2026-10-01 | ✅ done |
| 92 | `DaemonEventBus._extractPairName` had the same 0-11 table *and* a duplicate inline 12-entry `explorerTx` map. Now derives from `SwapPairSdk` and delegates to `ChainInfo.explorerTxUrl`, so there is one explorer map rather than two | opencode | 2026-10-01 | ✅ done |
| 93 | `ChainInfo.explorerTx` was missing 7 wired swap chains. Added OP (`optimistic.etherscan.io`), PLS (`scan.pulsechain.com`), MON (`monadscan.com`), UNI (`uniscan.xyz`). **GLEEC, RHC and XPL deliberately left absent** — no authoritative explorer URL exists in-repo and a wrong one in a wallet is a phishing risk, so they are pinned as known gaps in the new test instead of guessed | opencode | 2026-10-01 | ✅ done (3 gaps tracked by test) |
| 94 | `ChainInfo.ptlc` had no descriptor for KMD or DCR despite both being wired `SwapPairSdk` pairs; added. Also `gleec.png` was referenced but absent (sourced from the suite dashboard's copy) and `chains.yaml` pointed `rsk` at a non-existent `rsk.png` (corrected to `rootstock.png`); registry regenerated | opencode | 2026-10-01 | ✅ done |
| 95 | `gen_chains.dart --check` existed but ran in **no** CI job — the manifest could drift from `chain_registry.g.dart` undetected. Added a "Chain registry is in sync with chains.yaml" step to the `analyze` job in `fuego-wallet-ci.yml` | opencode | 2026-10-01 | ✅ done |
| 96 | New `test/swap_pair_drift_test.dart` (13 tests) locks the fix: ids match C++ `SwapTypes.h` verbatim, `pairName` never falls back to `PAIR_<n>`, the ten previously-broken ids are named individually, every swapable chain has colour/icon/decimals/PTLC, referenced icon assets exist on disk, explorer coverage matches the explicit known-gap set, and `ChainInfo.swapableChains == SwapPairSdk` tickers | opencode | 2026-10-01 | ✅ done |
| 97 | `AGENTS.md` was stale: claimed 12 `SwapPair` values (29 — 25 registered, 4 staged) and listed POLYGON as missing from four C++ tables (it is present in all four upstream). Replaced the Known Issues list with the four *silent* failure modes (`MAX_PAIR_INDEX`, `DOT` loop sentinels, `ctrDivisor` defaulting to a plausible-wrong `1e8`, the 12-char parse guard) and the stale `swapxfg` / dashboard / `swap_config.example.json` / orphan `CLV/` facts. Left the Rust SDK's "12 pairs" line alone — verified accurate | opencode | 2026-10-01 | ✅ done |

### Sign-off

| Check | Result |
|-------|--------|
| `flutter analyze --fatal-warnings --no-fatal-infos` | ✅ 0 errors, 0 warnings, exit 0 (781 infos, all pre-existing) |
| `flutter test` | ✅ 72/72 (59 pre-existing + 13 new) |
| `dart run tool/gen_chains.dart --check` | ✅ up to date (33 chains) |
| Not touched | `rust-fuego-wallet/fuego-sdk/fuego-crypto/src/ring.rs` and the untracked `ownerbound_vectors*` are pre-existing unrelated working-tree changes — deliberately left alone |
| Source changes in this entry | 6 files + 1 new test + 1 icon asset + CI step + AGENTS.md |

## [2026-10-01] OKOC valise-daemon audit continuation (local index, no source change)

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 85 | The **local** git index held `rust-fuego-wallet/src/walletd.rs` as a byte-exact revert of `ebc6b8a` ("harden walletd password handling + seed perms"). If committed it would have restored a literal `"fuego"` default (ignoring the SecureStorage password Dart passes as `WALLETD_CONTAINER_PASSWORD`/`WALLETD_PASSWORD`) and re-exposed the password via `ps` (CWE-214) — ADV-03, weighted 9.4/10 in the 2026-09-16 guardian audit. Confined to the local index; restored locally, then verified the remote tip already carries the hardened file byte-identically | opencode | 2026-10-01 | ✅ done (no remote change needed) |
| 86 | `chain_registry.g.dart` differed from the pre-branch baseline by 10 lines (`tier: wallet` → `tier: swap` for op, avax, cro, monad, xpl, pls, uni, rh, bob, gleec). Confirmed intentional: the matching change is in `chains.yaml` and matches the branch's swap-chain commits (`1ab5eee`, `67df1af`). `gen_chains.dart --check` passes on the tip. The stale copy was the local branch, not the tip — no fix applied | opencode | 2026-10-01 | ✅ done (false positive) |
| 87 | `web/icons/Icon-*.png` (referenced by `web/index.html:27`, `web/manifest.json`) present on the tip; `setup.sh` (Sideloadly/mitmproxy GSA sideload workaround) never tracked on the tip. Neither needed restoring | opencode | 2026-10-01 | ✅ done (no change needed) |
| 88 | Discarded local commit `c10a4bc` (kept as `backup/c10a4bc-redundant-squash`): it re-squashed 28 commits already on the branch — including the `origin/master` merge `698900e` and tip `db0d4d1` "walletd: serve the vault wallet, not a key of its own" — and held the pre-tier-promotion `chain_registry.g.dart`. Pushing it would have removed 33,866 lines | opencode | 2026-10-01 | ✅ done |
| 89 | `fuego-suite` submodule was uninitialized, so `fuego-ffi/build.rs:85` panicked and `cargo check` exited 101. Initialized to the recorded pin `524454dd` (an interrupted earlier attempt had left it on unpinned `master` `a36eccb`) | opencode | 2026-10-01 | ✅ done |

### Sign-off

| Check | Result |
|-------|--------|
| `cargo check` | ✅ exit 0 (4 pre-existing C warnings in suite `slow-hash.c`: unused `tmp` ×2, `aligned_malloc`, `aligned_free`) |
| `flutter analyze` / `dart analyze` | ✅ 0 errors, 0 warnings (779 infos) |
| `flutter test` | ✅ 59/59 |
| `dart run tool/gen_chains.dart --check` | ✅ up to date (33 chains) |
| Source changes in this entry | none — investigation, submodule init, and changelog only |

## [2026-09-26] PR #12 CI and review fixes

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 67 | iOS archive had no `fuego_*` symbols: release links dead-strip, and ld64 does not keep a main executable's unreferenced globals. Added `-Xlinker -export_dynamic` next to each `-force_load` | claude | 2026-09-26 | ✅ done (verified by CI) |
| 68 | Runner build phase "Build fuego-ffi" (`scripts/build-ios-ffi.sh`) builds the Rust slice for the active SDK/arch; clean Xcode/flutter builds no longer need a manual cargo step (review #7) | claude | 2026-09-26 | ✅ done |
| 69 | Android natives: cargo-ndk 4.1.2 could not link against NDK r25b (`crtbegin_so.o`, `-llog`). Use the runner's preinstalled NDK (27.x), which master's green builds used | claude | 2026-09-26 | ✅ done |
| 70 | walletd JSON-RPC: the `is_wallet_method` allowlist omitted the sub-address methods and several handled aliases (`getHealth`, `transfer`, `send_heat`, `create_afk_lock`, `heat_cd`, ...), which returned "unknown method". Removed it; the handler is the only list, and unhandled names fall through to the fuegod proxy. Dropped the placeholder zero-APY arm so `cd::apy` still reaches fuegod (review #4) | claude | 2026-09-26 | ✅ done |
| 71 | Outputs whose `get_o_indexes` failed keep global index 0 and could never be spent or swept; retried every sync round (review #3) | claude | 2026-09-26 | ✅ done |
| 72 | Zero 8-byte stratum target rejected (-2) (review #8) | claude | 2026-09-26 | ✅ done |
| 73 | Core client wallet port follows mainnet/testnet switches when the local proxy runs (review #2) | claude | 2026-09-26 | ✅ done |
| 74 | Backgrounding locks through `WalletProvider.lockWallet()` (clears cached data), and resuming routes to `PinEntryScreen` when a PIN is set (review #5) | claude | 2026-09-26 | ✅ done |
| 75 | Linux launcher symlink pointed at "Fuego Valise" (display name); the binary is `fuegowallet` (`BINARY_NAME`). Bundle step reads it from CMakeLists and checks the link resolves; flatpak fixed too (review #6) | claude | 2026-09-26 | ✅ done |
| 76 | `unified` is required: the desktop build fails without it, and bundling requires all four backends (review #1) | claude | 2026-09-26 | ✅ done |
| 77 | Main CI Analyze passed `--fatal-warnings` but infos were still fatal by default (red on master too); added `--no-fatal-infos` as the step's comment intends | claude | 2026-09-26 | ✅ done |
| 78 | Suite's CMake adds `-march=native` to Crypto whenever `CI`/`GITHUB_*` is set at configure; release `fuegod`/`xfg-swapd` could SIGILL on user CPUs older than the runner, and the cached wire-check build did SIGILL on another runner. Desktop builds and the wire check now configure with those vars unset; cache key bumped | claude | 2026-09-27 | ✅ done |
| 79 | Android export check used `readelf -s --dyn-syms \| grep -q` under pipefail: grep exits on the match, readelf takes SIGPIPE (141), the step failed with the symbol present. Now `--dyn-syms` only, full read | claude | 2026-09-27 | ✅ done |
| 80 | iOS symbol check failed on the debug simulator build: Xcode `ENABLE_DEBUG_DYLIB` puts app code in `Runner.debug.dylib`. The script now includes it when present | claude | 2026-09-27 | ✅ done |
| 81 | walletd ran on its own random `master_seed.bin`: GUI balance (`scan_balance` ignored the keys), sends, history and sub-addresses were that key's, not the vault's. walletd now starts with `--await-wallet`; the app sends the vault seed (`open_wallet`) after unlock and `close_wallet` on lock; per-wallet state dirs with a wallet-id guard; `scan_balance` checks keys (409) | claude | 2026-09-29 | ✅ done |
| 82 | Existing `master_seed.bin` wallet is synced as the legacy wallet and swept into the vault wallet from the receive screen (`get_legacy_wallet`, `sweep_legacy_wallet`, 50 inputs per tx); file kept | claude | 2026-09-29 | ✅ done |
| 83 | Sync wrote the top block hash per block but the height/outputs per batch: quitting mid-batch skipped blocks for good. Hash and state now written in one sled batch; scanner skips outputs already held or spent (re-scan idempotent) | claude | 2026-09-29 | ✅ done |
| 84 | Sub-address list reconciled with walletd's (labels and hidden entries kept by address); legacy sub-addresses re-registered per opened wallet; stale pre-`open_wallet` walletd is restarted instead of reused | claude | 2026-09-29 | ✅ done |
| 90 | Commitment outputs (HEAT, LP, swap receipts, CDs) were built with the legacy key, spendable by the sender and any view-key holder (`send_heat` even discarded the recipient's spend key). Builders now emit owner-bound keys `derive_public_key(D, i, B)` (suite `keyderiv` parity); scanner matches owner-bound via the sub-address table, falls back to the legacy form | claude | 2026-10-02 | ✅ done |
| 91 | Byte-for-byte C++/Rust vectors from keyderiv (primary + sub-addresses, 5 indices, legacy); Rust-built mint and HEAT-send txs parse and round-trip in suite's production parser with matching hashes | claude | 2026-10-02 | ✅ done |
| 92 | Every SDK builder seeded the tx secret r = Hs(seed ‖ inputsHash) with the sender's view **public** key; anyone holding the sender's address could recompute r, link the sender's txs and test outputs against known addresses. Builders now take the view secret (suite `generateDeterministicTransactionKeys`). `get_tx_proof` tries the secret seed, then the public seed for txs sent before the fix (it produced invalid proofs for every Rust-built tx). Pinned hashes regenerated; suite's C++ parser round-trips each | claude | 2026-10-03 | ✅ done |
| 93 | `send_heat`, `create_cd`/`heat_cd`, `claim_cd`, `rollover_cd` paid the fee out of HEAT. suite's `pushBlock` (v10+) conserves HEAT exactly; the mempool sums both assets and accepted them, then any block including one was invalid. New `build_commitment_spend_xfg_fee_transaction`: XFG key inputs pay MINIMUM_FEE. `claim_cd` paid CDs out as XFG (rejected); it now returns principal + interest as HEAT bills. GUI shows the HEAT send fee as 0.0008 XFG | claude | 2026-10-03 | ✅ done |
| 94 | 8 HEAT epoch-to-epoch auto-roll CD (900-block term) removed from walletd and the GUI: suite rejects terms below 6 epochs and keeps auto-roll off until v13. 8 HEAT is the minimum CD amount with normal terms | claude | 2026-10-03 | ✅ done |
| 95 | `docs/IOS_WALLETD_FFI_SCOPE.md` rewritten: run walletd's axum server in-process on iOS (FFI start/stop in `fuego-ffi` behind a `walletd` feature) instead of wrapping 39 methods; prerequisite token auth on walletd for all platforms | claude | 2026-10-03 | ✅ plan |
| 96 | Not fixed, found: walletd accepts any local caller (only a `Host` check); while a wallet is open any local process, or any Android app with INTERNET, can call `send_transaction`. Plan step 1 in the iOS scope doc | claude | 2026-10-03 | ⏳ open |
| 97 | Not fixed, suite consensus: commitment rings mix terms of the same amount and `classifyInputAsset` classifies by the first ring member, so a HEAT spend whose lowest-index decoy is an LP or pool output is misclassified; `fee_summary` adds the combined-asset fee, so treasury burns and HEAT→XFG swap deltas are paid to the miner as XFG. Both are in keyderiv's Part 2 (asset accounting), not started | claude | 2026-10-03 | ⏳ open (suite) |

### Sign-off

| Check | Result |
|-------|--------|
| `cargo test --workspace` | ✅ 109 passed (after rows 92–94) |
| `check_ffi_bindings.py --strict` | ✅ clean |
| `flutter analyze --fatal-warnings --no-fatal-infos` / `flutter test` | ✅ / ✅ 59 |
| `dart format --set-exit-if-changed lib/ test/` | ❌ 94/108 files, same on master; not reformatted in this PR |
| iOS link, Android NDK link, desktop bundles | — CI on the PR |

## [2026-11-10] FV-09: network-aware address prefix

FFI and vault address creation no longer hardcode the mainnet prefix. `fuego_make_address_for_network` and `fuego_vault_get_address_for_network` take a testnet flag. Dart threads it through, and the vault service re-derives the cached address when the provider switches network. Mainnet still starts with `fire`, testnet with `TEST`.
