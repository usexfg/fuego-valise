# CHANGELOG.agent.md

## [2026-09-25] fuego-suite submodule, FFI from suite, SDK/fuegod wire check

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 25 | Add `usexfg/fuego-suite` as a shallow submodule at `fuego-suite/` tracking `master`, pinned to `524454d` | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 26 | `fuego-ffi/build.rs` compiles CryptoNight from `fuego-suite/src/crypto`; delete the vendored copy (`src/cn`, `src/Common`, 30 files, byte-identical to suite at the pin) | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 27 | Add CryptoNight known-answer tests to `fuego-ffi` (canonical CN v0 ×3, v2 ×2 from suite `tests/PowBytes`). The crate had zero tests before | claude-opus-5-5 | 2026-09-25 | ✅ done |
| 28 | Delete `native/crypto` + `lib/native` (dead: `NativeCrypto` referenced nowhere, yet built and shipped in every APK/IPA; includes ~92 MB / 384 committed build artifacts) | claude-opus-5-5 | 2026-09-25 | ⛔ blocked by permission classifier (irreversible delete) — needs user approval |
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
- `build-linux` builds suite on ubuntu-22.04 (Boost 1.74); suite's AGENTS.md says Boost 1.86+. Pre-existing, unverified.

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
