# iOS walletd: scope for a real fix

## Why this exists

Mobile CI now cross-compiles and bundles `fuego_walletd` for Android
(`libfuego_walletd.so` in `jniLibs`, extracted with execute permission and
spawned via `Process.start()`). That approach cannot work on iOS: App
Sandbox forbids spawning arbitrary bundled subprocesses (`Process.start` /
`NSTask`), and Apple review would reject an app that tried. Cross-compiling
`fuego_walletd` for `aarch64-apple-ios` would produce a binary the app can
never execute under `DaemonManager`'s current design.

The only architecture that works on iOS is folding walletd's wallet-RPC
logic into the existing **in-process FFI library** pattern (`fuego-ffi` /
`fuego_crypto`) instead of a spawned daemon talking HTTP over loopback.
This document scopes that work. It is a plan, not an implementation —
nothing here has been built or verified; there is no Rust/Flutter/Xcode
toolchain available to test any of it from this environment.

## What already exists to build on

- `rust-fuego-wallet/fuego-sdk/fuego-ffi` establishes the calling
  convention already used on every platform: `crate-type = ["cdylib",
  "staticlib"]`, `#[no_mangle] extern "C"` functions, JSON-string /
  byte-buffer marshaling, explicit `fuego_string_free`/`fuego_bytes_free`
  paired frees. `lib/ffi/fuego_native.dart` is the Dart-side binding.
  On iOS, `libfuego_ffi.a` is force-loaded into the Runner binary and
  resolved via `DynamicLibrary.process()`; a new wallet-service FFI can
  ship the same way, inside the same staticlib.
- Mobile CI and both iOS release workflows already cross-compile the
  staticlib for `aarch64-apple-ios` and verify its symbols are in Runner.
- `fuego-ffi` today is **entirely synchronous, single-call, stateless**
  (keypair generation, address derivation, key images, HTLC hash locks,
  swap-pair metadata, `cn_slow_hash`). No tokio, no async, no persistent
  state across calls.

## The actual gap

`fuego_walletd` (`rust-fuego-wallet/core`) is the opposite shape: an async
`axum` HTTP server (`server.rs`, 818 lines, 28 routes) over a persistent,
stateful `Arc<Mutex<WalletService>>` (`wallet_service.rs`, 1740 lines, 28
public methods) with a detached background sync loop
(`tokio::spawn(... sync_loop())` in `main.rs`).

Of the 28 HTTP routes, **13 are pure passthrough** to the remote fuegod's
own HTTP API (`fuegod_get`/`fuegod_post` — `amm_pool_info`,
`getswapoffers`, `getorderbook`, `heat_metrics`, etc.). These don't need
Rust involvement on iOS at all: Dart can call the remote fuegod directly
over HTTPS. That trims the real FFI surface to `/json_rpc` dispatch (→ the
28 `WalletService` methods), `/health`, `/status`, `/scan_balance`.

The 28 `WalletService` methods are genuine financial/crypto logic, not
thin wrappers — ring-signature transaction construction, HTLC swap state
machines, CD (certificate of deposit) interest calculation, AMM
swap/LP add/remove, limit orders, HEAT minting. This is the bulk of the
real work.

## Phased plan

### Phase 0 — pick the async calling convention
Rust functions doing network I/O + signing must not block Dart's UI
isolate, and `fuego-ffi`'s existing convention is synchronous-only. Options:

| Option | Description | Tradeoff |
|---|---|---|
| (a) Poll | Rust spawns work on an internal runtime; Dart polls `get_result(request_id)` | Simplest, matches existing precedent exactly; adds latency per call |
| (b) Callback | Rust calls back into Dart via `NativeCallable`/`Dart_PostCObject_DL` when ready | No polling; more FFI plumbing to hand-write |
| (c) `flutter_rust_bridge` | Codegen tool built for exactly this (async + streams) | Removes most hand-rolled plumbing, but means migrating off the hand-written `fuego_native.dart` bindings — a real decision, not a tweak |

Recommendation: (c) if there's appetite for the migration; otherwise (b)
as the minimal in-house addition. Needed most for the background
sync-status stream — balance/height changes the UI should react to
without polling.

### Phase 1 — background runtime + state lifetime
- A process-global (`once_cell`) tokio `Runtime` + `Arc<Mutex<WalletService>>`,
  created by an FFI `fuego_wallet_init(seed, daemon_host, daemon_port,
  testnet) -> bool` call from Dart at unlock time — mirrors what
  `main.rs` already does for the desktop/Android daemon.
- Background sync loop spawned on that runtime at init, same as today.
- An explicit `fuego_wallet_shutdown()` call wired into the vault-lock
  path (`FuegoVaultService.lock()` / the `AppLifecycleState.paused`
  handler already in `main.dart`) so backgrounding the app actually
  suspends network activity instead of leaving an unbounded background
  task running past the point the vault itself locked.

### Phase 2 — iOS background execution reality
iOS suspends unbounded background work within seconds absent an explicit
background task/extension request. Two honest options:
- **Foreground-only sync** (recommended for v1): sync resumes when the
  app returns to foreground. Consistent with the vault-lock-on-background
  behavior already shipped — a background sync loop touching decrypted
  key material while the vault is nominally locked would be its own new
  security question, not just a scheduling one.
- `BGProcessingTask`/`BGAppRefreshTask` for periodic short sync windows —
  real additional Swift-side work, with Apple's usual unreliable
  scheduling.

### Phase 3 — wrap the WalletService surface
JSON in/out FFI functions for all 28 methods, request-id-dispatched per
Phase 0's convention. Grouped by shape:
- Cheap reads: `address`, `balance`, `height`, `balance_full`,
  `sync_status`, `get_transactions`
- Signing + broadcast: `send_transaction`, `send_heat`, `mint_heat`,
  `create_cd`, `heat_cd`, `claim_cd`, `list_cds`
- Swap/DEX flows: `amm_swap`, `lp_add`, `lp_remove`, `place_limit_order`,
  `create_afk_lock`, `claim_afk_swap`, `get_tx_proof`

### Phase 4 — Dart-side integration
- A new `FuegoWalletFfi` class in `lib/ffi/`, parallel to `FuegoNative`.
- The bigger piece: `WalletProvider`/`WalletCubit`/`FuegoRPCService`
  currently assume an HTTP JSON-RPC backend (`Dio` against
  `127.0.0.1:18189`). On iOS they need a parallel FFI-backed
  implementation behind the same interface, selected by `Platform.isIOS`
  — not a small conditional, a second data-layer implementation.
- `NodeConnection` needs an iOS branch that skips
  `DaemonManager.startAll()` entirely and initializes the FFI wallet
  instead.
- The 13 passthrough routes noted above: Dart calls the remote fuegod
  directly over HTTPS, no Rust involvement.

### Phase 5 — xfg-swapd (separate scope, not covered above)
`xfg-swapd` is a **separate** Go/C++ binary also spawned as a subprocess
for cross-chain atomic swaps (see `AGENTS.md`'s dual-daemon architecture).
It has the identical iOS subprocess problem and is architecturally
further from FFI-friendly — no existing Rust FFI crate to extend, and
Go/C++ isn't a drop-in fit for the pattern above. This is realistically a
second, larger scope of work. Cross-chain swaps should be expected to
stay unavailable on iOS even after Phase 4 ships, unless scoped
separately.

### Phase 6 — build/CI
- Cross-compile for `aarch64-apple-ios` (device) **and**
  `aarch64-apple-ios-sim` / `x86_64-apple-ios` (simulator) — CI today only
  builds the device arch, so simulator testing/dev builds aren't covered.
- Package as an XCFramework (Apple's multi-slice format) instead of the
  current flat `.dylib` copy, so one Xcode build covers both device and
  simulator without manual slice-switching.
- Verify the `keyring` crate's iOS backend (Keychain via
  `security-framework`) actually compiles/links for iOS targets. Likely
  lower-risk than the Android case (no JNI-style context requirement —
  Keychain is a plain Apple API) but unverified in this sandbox.

## Recommended next step

Not "build all of this" — confirm scope/priority first: does iOS stay in
its current degraded/remote-read-only mode for now (an honest, already-
shipped state), or is this the near-term priority? If the latter: spike
Phases 0+1 with a single method (`address()`/`balance()` — the simplest
possible round trip) working end-to-end through the new async-FFI
pattern, verified building for iOS device *and* simulator in CI, before
committing to wrapping all 28 methods.
