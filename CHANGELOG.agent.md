# CHANGELOG.agent.md

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
| F3 | `WalletdService` — dead code with hardcoded seed node, superseded by `DaemonManager` | LOW | Safe to delete when confirmed unused |
| F4 | Mobile degraded mode — `rpcService` points at `127.0.0.1:18189` (never listening); all wallet RPCs fail with connection refused | MEDIUM | Needs `fuego_walletd` ARM binary bundled in APK/IPA |

### Sign-off

| Check | Result |
|-------|--------|
| Build compiles | — (requires Flutter toolchain; not run in CI container) |
| Tests pass | — (requires device/emulator) |
| All tasks done | ✅ |
