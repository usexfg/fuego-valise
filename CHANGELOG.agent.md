# CHANGELOG.agent.md

## [2026-09-26] Fuego PoW on Android, FFI ABI, sub-addresses, key and address fixes (user: "fix 1-7 all"; sub-address design: suite scheme)

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 58 | `build.rs` compiles suite `slow-hash.c` from `OUT_DIR` with exact-text fixes: the `VARIANT2_PORTABLE_SHUFFLE_ADD` light-mode store offsets (wrong CN-UPX/2 on every Android ABI) and the `VARIANT1_INIT64` unaligned load (armv7 SIGBUS). It also defines `FORCE_USE_HEAP` (the 2 MiB stack scratchpad overflowed ~1 MiB isolate stacks). Upstream patch: `fuego-ffi/patches/slow-hash-portable.patch` | claude-opus-5-5 | 2026-09-26 | ✅ done |
| 59 | `fuego_cn_slow_hash`: `unsafe`, null/variant/length checks (the C code `_exit(1)`s on short v1 input). `fuego_mine_share`: xmrig share rule (u64 at hash[24..32] vs expanded 4-/8-byte stratum target; it compared hash[0..4]), `target_len` parameter, null checks, -2 on bad arguments | claude-opus-5-5 | 2026-09-26 | ✅ done |
| 60 | Tests: mainnet block 1,000,001 PoW meets its difficulty (pinned `ce75e028…`); argument rejection; stratum target semantics; `mine_share` agrees with `cn_slow_hash`. CI job `ffi-cryptonight-paths`: `-DNO_AES`, aarch64 (no crypto) and armv7 under qemu | claude-opus-5-5 | 2026-09-26 | ✅ done |
| 61 | Dart FFI: `usize` → `Size`, `u32`/`u64` → `Uint32`/`Uint64` (checker `--strict` clean). Length `assert`s (stripped in release) replaced by unconditional checks, plus a u32 index range check. Secret buffers wiped before free (Dart `_freeSecret`; Rust `fuego_string_free`/`fuego_bytes_free` wipe) | claude-opus-5-5 | 2026-09-26 | ✅ done |
| 62 | `.github/actions/build-android-natives`: cargo-ndk, 4 ABIs, 16 KB page alignment, readelf alignment and export checks. Used by mobile CI, Play Store (never built the FFI before) and F-Droid (never linked or bundled it) | claude-opus-5-5 | 2026-09-26 | ✅ done |
| 63 | `scripts/check-ios-ffi-symbols.sh` (Runner, xcarchive or IPA) in mobile CI and both iOS release workflows, now also after IPA export. `ios-release.yml` maps the signing secrets into job `env` (its gated steps always skipped) | claude-opus-5-5 | 2026-09-26 | ✅ done |
| 64 | `Keypair::from_secret` stores the reduced scalar. Vault secrets were raw Keccak output, rejected by `sc_check` in `generate_key_derivation`/`derive_secret_key` for ~15/16 seeds (probe: 3/64 passed), so walletd found and spent nothing for those wallets. Walletd `scan_version` 2 triggers one rescan of older state | claude-opus-5-5 | 2026-09-26 | ✅ done |
| 65 | `parse_address` stripped the "fire"/"TEST" base58 lead and required ≥72 decoded bytes (addresses are 71), so it parsed 0/32 addresses; every walletd send and tx proof failed. It now decodes the whole string. `decode_block` rejects overflow, which used to panic in debug | claude-opus-5-5 | 2026-09-26 | ✅ done |
| 66 | Sub-addresses in suite's scheme: `fuego_crypto::derive_subaddress_keys` (byte-identical to suite C++ on 5 vectors). Scanner uses one master derivation plus a spend-key table (lookahead 50) and records the owner per output. Walletd adds `create_subaddress`, `get_subaddresses`, `register_legacy_subaddresses` (one rescan) and `sweep_legacy_subaddresses`. Dart: store v2 marks old entries legacy, creation goes through walletd, the receive screen shows a sweep banner and legacy entries can't be copied or selected, and the privacy copy is corrected (sub-addresses are linkable). Removed the vault's unused incompatible `100+2n` helpers | claude-opus-5-5 | 2026-09-26 | ✅ done |

### Sign-off

| Check | Result |
|-------|--------|
| `cargo test --workspace` (x86_64) | ✅ all pass |
| `cargo test -p fuego-ffi` with `-DNO_AES`; aarch64 and armv7 under qemu | ✅ 6/6 each |
| Unpatched portable path on block 1,000,001 (negative control) | ✅ `11a8d02b…` (misses difficulty) vs patched `ce75e028…` |
| `check_ffi_bindings.py --strict` | ✅ 0 errors, 0 warnings |
| `flutter analyze` on changed Dart | ✅ 0 errors, no new warnings (4 fewer) |
| Workflow/action YAML parses; readelf alignment and iOS symbol scripts exercised on real/fake inputs | ✅ |
| Android NDK build, iOS archive/IPA, sweep against a live node | — not runnable here (no NDK, macOS or funded wallet) |

## [2026-09-25] fuego-ffi skill

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 55 | `.claude/skills/fuego-ffi`: SKILL.md (boundary conventions, type mapping, add-a-function steps, verification gates, suite-bump checks, known debt), `references/platforms.md`, `references/cryptonight.md`, `scripts/check_ffi_bindings.py` (Rust export vs Dart typedef arity/width/signedness + `#[repr(C)]` struct layout) | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 56 | Evaluate the skill: 4 prompts × with/without skill, graded + benchmarked | claude-opus-5-5 | 2026-09-25 | ✅ done: with 100%, without 92%; -12% time, -6% tokens |
| 57 | iOS symbol checks (mobile CI, `ios-release.yml`, `appstore-release.yml`) used `grep -E "(a\|b\|c)"`, which passed if any one symbol survived; now every symbol must be present | claude-opus-5-5 | 2026-09-25 | ✅ done |

Defects found by the evals and verified, **not fixed** (recorded in the skill's known debt):

| # | Finding | Severity |
|---|---------|----------|
| F5 | suite `slow-hash.c` `VARIANT2_PORTABLE_SHUFFLE_ADD` stores to the wrong offsets for `light`, so the portable path (every Android ABI, any ARM-no-crypto or `NO_AES` fuegod) computes a different Fuego PoW hash from SSE2/NEON | CRITICAL (consensus); fix belongs in fuego-suite |
| F6 | `build.rs` lacks `FORCE_USE_HEAP`: 2 MiB CryptoNight scratchpad on the stack on the portable path (Dart isolate threads ~1 MiB) | HIGH |
| F7 | `fuego_mine_share` compares hash bytes 0..4 with the stratum target; pools compare the u64 at offset 24 | HIGH |
| F8 | Subaddress n uses vault keys n/n+1 starting at n=1: subaddress 1 spend secret = main view secret | HIGH (security) |
| F9 | Ten `usize` FFI params bound as Dart `Int32` (ABI width mismatch on 64-bit) | MEDIUM |
| F10 | `android-playstore-release.yml` and `fdroid-release.yml` ship no `libfuego_ffi.so`; `ios-release.yml` archive/check steps always skip (`env.IOS_P12_BASE64` never defined) | HIGH (release) |
| F11 | No variant-2-light known-answer test; CryptoNight tests only exercise x86_64 | MEDIUM |

### Sign-off

| Check | Result |
|-------|--------|
| `check_ffi_bindings.py` mutation tests (missing symbol, arity, struct width, return kind) | ✅ each detected |
| Workflow YAML parses after symbol-check change; loop fails on a missing symbol | ✅ |
| `package_skill.py` validation | ✅ |
| Real iOS archive symbol check | — needs a macOS runner |

## [2026-09-25] Network connect, desktop Exec, iOS static link

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 47 | Settings → Network → Connect loaded `assets/bin/fuego_walletd-*` (never produced by any build) via `WalletDaemonService`, bypassing `NodeConnection`. Now `NodeConnection.switchNetwork()` retargets ports/seeds, persists the choice (`node_network` pref, honored at next launch unless `FUEGO_TESTNET` is set) and reconnects; the screen opens on the active network | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 48 | `useTestnet` followed only the env var, so a runtime switch would be reverted by Settings' local/remote toggles; it now reads `NodeConnection` | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 49 | Chain clients (`daemon`, `hearthClient`) and `DexCubit` now follow every reconnect via `NodeConnection.addListener` instead of being pinned at startup | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 50 | Delete now-unreferenced `wallet_daemon_service.dart`, `cli_service.dart`, `assets/bin/` (+ pubspec entry, README tree line) | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 51 | `linux/xfg-wallet.desktop`: `Exec=Fuego Wallet` (nonexistent) → `Exec=fuego-valise`; `Name` → Fuego Valise; `StartupWMClass` → fuego-valise (GTK3 derives it from argv[0]). Shared Linux bundle step now creates the `fuego-valise` launcher symlink for tarball/flatpak/snap | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 52 | iOS: force-load `libfuego_ffi.a` into Runner (per SDK/arch `OTHER_LDFLAGS` at target level so `$(inherited)` keeps CocoaPods flags), `STRIP_STYLE = non-global`; `FuegoNative` uses `DynamicLibrary.process()`. Mobile CI drops the loose-dylib copy (App Store-rejected) for a linked-symbol check; both iOS release workflows build the staticlib and check symbols survive archive stripping | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 53 | Correct suite `AGENTS.md` (`queryblockslite.bin` hang claim, Boost 1.86+ note) | claude-opus-5-5 | 2026-09-25 | ⛔ blocked: push access to `usexfg/fuego-suite` denied by permission classifier; replacement text given to user |
| 54 | Look for a previously created fuego-ffi skill (Claude / opencode) | claude-opus-5-5 | 2026-09-25 | ✅ searched: none in synced Claude skills, claude.ai library, either repo's `.claude/`/`.opencode/`, or reachable history |

### Sign-off

| Check | Result |
|-------|--------|
| `flutter analyze` (Flutter 3.44.4, first real run this session) | ✅ 0 errors; no warnings in any file touched this session (142 pre-existing warnings elsewhere) |
| `project.pbxproj` parses (openstep_parser); Runner Debug/Release/Profile carry force-load + non-global strip | ✅ |
| Host `libfuego_ffi.a` contains exported `fuego_*` and `cn_slow_hash` | ✅ |
| `desktop-file-validate linux/xfg-wallet.desktop` | ✅ (one category hint) |
| Bundle step launcher: `fuego-valise` → `Fuego Valise`, argv[0] = fuego-valise | ✅ |
| iOS device/simulator link and archive stripping | — needs Xcode; CI symbol checks are the verification |
| Network switch end to end in the running app | — no display/device here |

## [2026-09-25] Release pipelines, FFI packaging, wire coverage (user: "fix all")

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 35 | Delete `native/crypto` (incl. 384 committed build artifacts, ~92 MB), `lib/native`, and the committed arm64-only `macos/Runner/libfuego_ffi.dylib` (now gitignored); drop `native/crypto` from mobile CI | claude-opus-5-5 | 2026-09-25 | ✅ done (user approved) |
| 36 | Move desktop build + bundling into shared composite actions `build-desktop-backends` / `bundle-desktop-backends`; CI and all desktop release workflows use them | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 37 | Linux builds (CI tarball, flatpak, snap) never bundled `libfuego_ffi.so`, so wallet create/unlock (`FuegoVaultService` → FFI) failed on Linux. Now bundled in `lib/`; `FuegoNative` loads it by explicit path | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 38 | All 5 release workflows built suite's old C++ `walletd` from 8-month-stale `HEAT` into `assets/bin/` (never read by the app). Desktop ones now build/bundle the real backends from the pinned submodule; iOS ones drop the step (iOS cannot spawn it) | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 39 | `appstore-release`: `subosher/setup-flutter@v1` → `subosito/flutter-action@v2`; signing identity `"Developer ID Application: $APPLE_TEAM_ID"` never matches a cert CN → identity read from the imported keychain | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 40 | `macos-release`: bundle path `fuego-wallet.app` → `fuego_wallet.app` (verify step failed every run); signing gated on never-set `env.APPLE_CERTIFICATE` → step output | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 41 | `scripts/sign-macos-app.sh`: one signer for CI (ad-hoc) and releases (keychain identity, hardened runtime, timestamp); CI re-sign no longer fails when optional `unified` is absent | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 42 | Stop duplicating macOS daemons into `Contents/Resources/bin` (never used; still pointed at Homebrew dylib paths) | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 43 | Linux executable is `Fuego Valise` (space). Flatpak `command: fuego_wallet` and snap `xfg-wallet` named nonexistent binaries, and snap split the exe from its `lib/`. Both now install the bundle intact under `fuego-valise/` with a `fuego-valise` launcher symlink; flatpak skips copying `.git`, `fuego-suite`, Rust `target` | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 44 | Flatpak/snap jobs → ubuntu-22.04 (snap `--destructive-mode` requires host = core22 base; oldest glibc); snap's stale `assets/bin` walletd part removed | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 45 | Wire test `get_random_outs_returns_known_output`: genesis coinbase key + amount from fuegod JSON must come back from `getrandom_outs.bin` with the global index `get_o_indexes.bin` reports — covers non-empty record layout and the `get_o_indexes` parser | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 46 | Delete `scripts/get_walletd_binary.sh`, `scripts/build-fuego-source.sh` (build suite walletd from `HEAT` into `assets/bin` under names nothing loads; unreferenced) | claude-opus-5-5 | 2026-09-25 | ✅ done |

### Sign-off

| Check | Result |
|-------|--------|
| `build-desktop-backends` Linux steps run verbatim here (Rust + suite `Daemon`/`SwapDaemon`/`PaymentGateService` from pin) | ✅ all 5 artifacts produced |
| `bundle-desktop-backends` Linux step run verbatim on a stand-in bundle; bundled `fuegod`, `xfg-swapd`, `unified`, `fuego_walletd` execute | ✅ |
| `libfuego_ffi.so` exports the 37 `fuego_*` symbols incl. those Dart looks up | ✅ |
| Wire tests vs local testnet fuegod from pin | ✅ 3/3 |
| Known-output test fails when parser key/index offsets are swapped (mutation check) | ✅ fails as intended |
| `cargo test -p fuego-sdk` / `-p fuego-ffi` | ✅ 54 / 2 |
| All workflow, action, snapcraft, flatpak YAML parses; all scripts `bash -n` | ✅ |
| macOS actions, signing, notarization, flatpak-builder, snapcraft, iOS release | — cannot run here (no macOS/Xcode, flatpak-builder, snapcraft); first real runs are the verification |

### Open (found, not fixed)
- **iOS FFI is not linked.** No iOS build links `libfuego_ffi` into the app: mobile CI copies a loose `.dylib` into `Runner.app` after `flutter build` (App Store rejects loose dylibs), and the release workflows don't include it at all. `FuegoNative` falls back to `DynamicLibrary.process()`, where the symbols don't exist, so wallet create/unlock fails on iOS. Needs the staticlib force-loaded into Runner (xcconfig `OTHER_LDFLAGS` + non-global strip style) or an XCFramework, verified on a Mac.
- **Settings → Network → Connect always fails.** `network_selection_screen.dart` calls `WalletDaemonService.initialize`, which loads `assets/bin/fuego_walletd-{linux,macos,windows.exe}`, and no build ever produces those files. It also bypasses `NodeConnection`. Runtime mainnet/testnet switching isn't supported by the startup-time wiring (`FUEGO_TESTNET`), so the fix is a redesign, not a patch. `cli_service.dart` loads from `assets/bin` too and is referenced nowhere.
- `linux/xfg-wallet.desktop` has `Exec=Fuego Wallet`, but the binary is `Fuego Valise`.
- Suite's own `AGENTS.md` still says `queryblockslite.bin` hangs on every binary. It works against this pin on a testnet node; that doc lives in suite (read-only from here).

## [2026-09-25] fuego-suite submodule, FFI from suite, SDK/fuegod wire check

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 25 | Add `usexfg/fuego-suite` as a shallow submodule at `fuego-suite/` tracking `master`, pinned to `524454d` | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 26 | `fuego-ffi/build.rs` compiles CryptoNight from `fuego-suite/src/crypto`; delete the vendored copy (`src/cn`, `src/Common`, 30 files, byte-identical to suite at the pin) | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 27 | Add CryptoNight known-answer tests to `fuego-ffi` (canonical CN v0 ×3, v2 ×2 from suite `tests/PowBytes`). The crate had zero tests before | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 28 | Delete `native/crypto` + `lib/native` (dead: `NativeCrypto` referenced nowhere, yet built and shipped in every APK/IPA; includes ~92 MB / 384 committed build artifacts) | claude-opus-5-5 | 2026-09-25 | ✅ done 2026-09-25 after user approval (task 35) |
| 29 | Replace `xfgo/` paths (local name for suite) with `fuego-suite/` in `daemon_manager.dart`, `build-and-run.sh`, `test-daemon.sh`, comments | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 30 | Desktop CI builds fuegod/xfg-swapd/unified from the pinned submodule instead of cloning floating suite `master`; FFI jobs (mobile, fdroid) check out the submodule; macOS job rebuilds `libfuego_ffi.dylib` from it | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 31 | Dependabot `gitsubmodule` (daily): PR per suite master move | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 32 | `fuegod-wire-check` CI job + `fuego-sdk/tests/fuegod_wire.rs`: round-trip `queryblockslite.bin` and `getrandom_outs.bin` through a real fuegod built from the pin | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 33 | Fix found by #32: suite's KV serializer omits empty binary fields, and `parse_get_random_outs_response` / `parse_get_random_commitment_outs_response` treated that as a hard error, failing the whole call when any amount had no outputs. Absent field now means empty | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 34 | Fix CONTRIBUTING.md: told contributors to clone fuego-suite and check out stale `HEAT` | claude-opus-5-5 | 2026-09-25 | ✅ done |

### Sign-off

| Check | Result |
|-------|--------|
| `cargo test -p fuego-ffi` (built from submodule) | ✅ 2/2 vector tests pass |
| `cargo test -p fuego-sdk` | ✅ 54 pass, 2 wire tests ignored without a node |
| Wire tests vs local fuegod built from `524454d` (Ubuntu 24.04, Boost 1.83, `--testnet`) | ✅ 2/2 after fix #33 (1/2 before) |
| `cargo check -p rust_fuego_wallet` | ✅ |
| Edited workflow YAML parses | ✅ |
| CI workflows actually run on GitHub | — not run from here |
| Flutter analyze/build | — no Flutter toolchain in this environment |

### Open (flagged, not changed)
- Five release workflows (`appstore-release`, `ios-release`, `macos-release`, `linux-flatpak-release`, `linux-snap-release`) clone suite branch `HEAT`: last commit 2026-01-15, no `fuego/` dir, so `appstore-release`'s `/tmp/fuego-suite/fuego/build/ios/fuego_walletd` cannot exist. Releases would ship 8-month-old daemons vs what CI tests.
- Committed `macos/Runner/libfuego_ffi.dylib` is an arm64-only dev build (`/Users/aejt/...` install name). CI now overwrites it; the committed file should be deleted + gitignored.
- Suite's AGENTS.md says `queryblockslite.bin` hangs on every binary. It did not hang here on a genesis-only testnet node; not verified on a synced mainnet node.
- Wire tests only exercise empty `getrandom_outs` groups (an isolated genesis node has no spendable outputs); the 40-byte non-empty record layout is not yet checked against live data.
- ~~`build-linux` Boost 1.74 vs suite's "1.86+" note~~ — resolved: user confirmed the 1.86+ note is outdated and suite builds on current Boost.

## [2026-09-22] Repo cleanup: dead trees, disabled workflows, duplicate file

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 19 | Delete `src/Alpha/` and `src/Release/` — two entire dead Flutter app scaffolds (unrelated "Polaris" branding, last touched 2026-08-13, zero references from any CI workflow, script, or doc) | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-22 | ✅ done |
| 20 | Delete the 7 `.github/workflows/*.disable` files (`android-release`, `fdroid-release`, `flutter-desktop`, `fuego-wallet-desktop`, `ios-release`, `linux-appstore-release`, `xfg-wallet-desktop`) — git history keeps them if ever needed; sitting disabled next to active workflows made it impossible to tell superseded from temporarily-off at a glance | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-22 | ✅ done |
| 21 | Delete `lib/services/walletd_service.dart` — resolves F3 below. Confirmed `wallet_daemon_service.dart` (used by `network_selection_screen.dart`) is a separate, live file and was NOT touched | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-22 | ✅ done |
| 22 | Delete `rust-fuego-wallet/core/src/Cargo.toml` — byte-identical duplicate of `rust-fuego-wallet/core/Cargo.toml`; Cargo only ever reads the package-root copy, the `src/` one was dead weight from a restructure | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-22 | ✅ done |
| 23 | Fix `README.md`'s file-tree diagram, which still listed the now-deleted `walletd_service.dart` | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-22 | ✅ done |
| 24 | Confirm read access to `usexfg/fuego-suite` (master) for this session, addressing the undocumented sibling-repo assumption in `daemon_manager.dart`'s binary search paths (11 references to `fuego-suite/`/`xfgo/`, neither present in this repo) | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-22 | ✅ confirmed available (public repo, already served) |

**F3 (below) is now resolved** by task 21.

## [2026-09-22] iOS walletd FFI scope

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 18 | Scope what's needed for `fuego_walletd` to actually work on iOS, given the subprocess approach used for Android CI cannot work there (App Sandbox forbids `Process.start`/`NSTask` for bundled executables) | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-22 | ✅ scoped, not implemented |

Read `rust-fuego-wallet/core`'s actual source (`wallet_service.rs` 1740
lines / 28 public methods, `server.rs` 818 lines / 28 HTTP routes, of
which 13 are pure fuegod passthrough) and the existing `fuego-ffi`
crate's calling convention (synchronous-only today) to produce a grounded
phased plan rather than a hand-wave. Full writeup: `docs/IOS_WALLETD_FFI_SCOPE.md`.

Sign-off: this is a multi-week Rust+Swift+Dart project (new async FFI
convention, 28 financial-logic methods wrapped, a parallel Dart data-layer
for iOS, xfg-swapd is a separate unaddressed scope) — no code written, no
build attempted. Recommended next step is a single-method spike (Phase
0+1 in the doc), not wrapping everything blind.

## [2026-09-21] Security audit + daemon/mobile review

### Tasks

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 1 | Restore PIN gate in `splash_screen.dart` (CRITICAL bypass) | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ done |
| 2 | Remove unconditional `clearStaleLockout()` that defeated brute-force lockout | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ done |
| 3 | `stopAll()` — reset `_*ExternallyRunning` flags to prevent stale state | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ done |
| 4 | Lock vault on `AppLifecycleState.paused`/`inactive` (mobile background) | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ done |
| 5 | Fix broken biometric fallback in `unlockWithBiometricKey` (always-fail MAC) | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ done |
| 6 | Persist swapd `configPath` for crash-restart (`_lastSwapdConfigPath`) | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ done |
| 7 | `getOrCreateWalletdPassword` — propagate write failure (was silent) | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ done |

### Self-review pass (2026-09-21)

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 8 | Narrow vault-lock trigger to `paused` only — `inactive` also fires on notification pull-down, incoming-call banner, and the biometric system prompt itself; locking there would force PIN re-entry constantly and could relock the vault mid biometric-unlock | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ done |
| 9 | Fix `_resetWallet()` (Forgot PIN flow) leaving orphaned encrypted vault files on disk — `clearWalletData()` only clears `SecurityService` entries, not `FuegoVaultService`; without `vault.wipe()` the old vault stayed on disk with no PIN to unlock it, stranding the user since `hasPIN=false` now skips `PinEntryScreen` entirely. This path was unreachable before fix #1 (task 1 above) made `PinEntryScreen` reachable, so this bug was previously dead code | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ done |
| 10 | Verified `stopAll()` external-flag reset (task 3) against both call sites (`NodeConnection.connect()`, `disconnect()`) — confirmed no regression: redundant no-op in `connect()` (immediately followed by `startAll()`, which resets the same flags itself), accuracy improvement in `disconnect()` (no `startAll()` follows, so stale `true` would otherwise persist in `status.value.walletdRunning` indefinitely after an explicit disconnect) | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ verified, no change needed |
| 11 | Verified `getOrCreateWalletdPassword` exception propagation (task 7) against both call sites (`daemon_manager.dart`, `walletd_service.dart`) — both already wrap the call in try/catch, so removing the internal silent-swallow introduces no new uncaught-exception risk | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ verified, no change needed |

### Mobile CI: fuego_walletd (2026-09-21)

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 12 | Confirm `fuego_walletd` was missing from mobile CI (`fuego-wallet-mobile-ci.yml` only built `fuego_crypto`/`fuego_ffi`, never the `core` crate binary) — this was finding F4 from the earlier audit, now confirmed at the CI level | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ confirmed |
| 13 | Add `fuego_walletd` Android cross-compile to CI (`cargo ndk` for the same 4 ABIs, reusing the existing `fuego_crypto`/`fuego_ffi` recipe) | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ done |
| 14 | Package `fuego_walletd` as `jniLibs/<abi>/libfuego_walletd.so` — the only way to get Android's installer to extract a bundled executable with execute permission on non-rooted devices; it is invoked via `Process.start()`, never `dlopen()`'d despite the `.so` naming | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ done |
| 15 | Set `packaging.jniLibs.useLegacyPackaging = true` in `android/app/build.gradle` + `android:extractNativeLibs="true"` in the manifest — without this, AGP 8.x's default packaging maps libs straight from the APK (page-aligned, never extracted as a real file), which would make the binary unexecutable | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ done |
| 16 | Add a `MethodChannel` (`MainActivity.kt`) exposing `applicationInfo.nativeLibraryDir` — Dart has no built-in accessor for this path, and `Platform.resolvedExecutable` does not point there on Android | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ done |
| 17 | Wire the resolved native-lib-dir into `DaemonManager._findWalletdBinary()` as an Android-only candidate path, resolved once and cached at the top of `startAll()` | claude/okoc-valise-daemon-audit-1niqzp | 2026-09-21 | ✅ done |

**iOS is explicitly NOT addressed** — this is not a CI gap on iOS, it is an architecture limitation. iOS sandboxing forbids spawning arbitrary bundled subprocesses at all (`Process.start`/`NSTask`), and would also fail App Store review. Cross-compiling `fuego_walletd` for iOS would produce a binary the app can never execute under the current `Process.start()`-based `DaemonManager` design. The real fix is folding walletd's wallet-RPC logic into the existing in-process FFI library (same shape as `fuego-ffi`/`fuego_crypto`) instead of a spawned daemon — a larger project, not a CI change.

**Unverified build risk:** `core/Cargo.toml` depends on `keyring = "3"` (used unconditionally, not `#[cfg]`-gated, in `keystore.rs`). This crate's Android backend typically expects a JNI/Android context that a plain `cargo ndk build`-produced standalone binary (not loaded via JNI) does not have. The usage is wrapped in `if let Ok(entry) = ...`, so a failure to construct the entry should be non-fatal at runtime, and `daemon_manager.dart` already always supplies `--container-password` via CLI arg rather than relying on the binary's own keyring lookup — but whether the crate even *compiles* cleanly for `aarch64-linux-android` et al. is unverified in this sandbox (no Rust/NDK toolchain available). Watch the first CI run for this specifically.

**Also unverified:** whether `fuego_walletd` actually runs correctly end-to-end once installed (does it bind to `127.0.0.1:18189` correctly inside Android's per-app network sandbox, does `sled`'s file-based storage work from the path passed via `--container-file`, etc.) — this CI change gets the binary onto the device; runtime verification needs an actual device/emulator run, which this sandbox cannot do.

### Findings not yet fixed (require binary/platform changes)

| # | Finding | Severity | Blocker |
|---|---------|----------|---------|
| F1 | Container password in process argv (`--container-password <pass>` visible via `ps`) | HIGH | Requires `unified`/`fuego_walletd` binary to support env-var or stdin delivery |
| F2 | `fuego_wallets.json` stores wallet addresses in plaintext (iCloud/ADB readable) | LOW | UX/migration decision needed |
| F3 | ~~`WalletdService` — dead code with hardcoded seed node, superseded by `DaemonManager`~~ | LOW | **Resolved 2026-09-22** — deleted |
| F4 | Mobile degraded mode — `rpcService` points at `127.0.0.1:18189` (never listening); all wallet RPCs fail with connection refused | MEDIUM | Needs `fuego_walletd` ARM binary bundled in APK/IPA |

### Sign-off

| Check | Result |
|-------|--------|
| Build compiles | — (requires Flutter toolchain; not run in CI container) |
| Tests pass | — (requires device/emulator) |
| All tasks done | ✅ |
