# iOS walletd: scope to a usable wallet

## Where iOS stands

- iOS cannot spawn `fuego_walletd`. App Sandbox forbids starting bundled
  executables (`Process.start` / `NSTask`), and App Review rejects apps
  that try.
- On iOS, `NodeConnection.connect()` calls `DaemonManager.startAll()`,
  finds no walletd and falls back to the degraded mode: wallet JSON-RPC
  points at `127.0.0.1:18189`, where nothing listens.
- So on iOS today:
  - Works: the vault, keys and addresses through `libfuego_ffi.a`, which
    is force-loaded and resolved with `DynamicLibrary.process()`; reads
    that go straight to a remote fuegod.
  - Does not work: scanning, balance, XFG and HEAT sends, CDs,
    sub-addresses, mint, Hearth swaps, LP, limit orders and tx proofs.
    All of them run through walletd.
- The iOS FFI build exists. `scripts/build-ios-ffi.sh` builds
  `aarch64-apple-ios`, `aarch64-apple-ios-sim` and `x86_64-apple-ios` from
  an Xcode build phase.
- Mining is disabled on iOS (`MiningCubit.isMiningSupported`).

## Approach: run walletd's server inside the app

The earlier plan wrapped every `WalletService` method in its own FFI
function. That meant a second, FFI-backed Dart data layer next to the
HTTP one. walletd has grown since:
- `wallet_service.rs` is 2,194 lines with 39 public functions;
- `server.rs` dispatches 48 JSON-RPC method names;
- the wallet slot (`open_wallet` / `close_wallet`) and per-wallet state
  were added.

Wrapping all of that would double the surface and drift.

iOS forbids starting another process. It does not forbid a socket
listening inside the app's own process. So walletd's existing axum
server runs on a tokio runtime inside the app. Two FFI calls start and
stop it, and the Dart data layer stays exactly as it is on Android and
desktop: JSON-RPC over loopback.

This removes Phases 0, 3 and 4 of the earlier plan:
- no async FFI convention;
- no wrappers per method;
- no second data layer.

## Work, in order

### 1. Caller authentication on walletd (all platforms; blocks step 4)

**What is wrong now:**
- walletd's only access check is the `Host` header (`is_authorized_host`).
  That blocks DNS rebinding from a browser, not local callers.
- While a wallet is open, any local process can call `send_transaction`,
  `send_heat` or `sweep_legacy_wallet` on `127.0.0.1:18189`. On desktop
  that is any process on the machine. On Android it is any installed app
  with the INTERNET permission. The PIN is checked only in Dart, so it
  does not stop these calls.
- An in-process server on iOS would carry the same hole.

**Fix:**
- At startup, walletd generates or receives a random 32-byte token.
- Every route except `/health` requires `Authorization: Bearer <token>`,
  compared in constant time.
- The token reaches walletd through an environment variable for a child
  process (not argv, which `ps` shows), or through the FFI start call on
  iOS.
- Every Dart client of walletd sends the header:
  - `FuegoRPCService`
  - `daemon_client.dart`
  - `wallet_service.dart`
  - `daemon_event_bus.dart`
  - `DexCubit`
  - `fuego_wallet_adapter.dart`
  - the health checks in `DaemonManager` and `NodeConnection`
- `DaemonManager` already replaces a stale walletd. A walletd that does
  not know the token must be replaced the same way.

**Alternative on iOS:** a Unix domain socket inside the app container.
Other apps cannot reach that path. Dio would need a custom
`HttpClientAdapter`, though. The token works the same way on every
platform, so it comes first.

### 2. Split `rust-fuego-wallet/core` into a library and a thin binary

- The library exposes `serve(config, shutdown) -> bound address`. The
  config covers:
  - daemon URL
  - data directory
  - testnet
  - token
  - bind address
- `main.rs` keeps the CLI (`serve`, `--await-wallet`, `--seed`) and
  calls `serve`.
- Allow binding `127.0.0.1:0` and return the chosen port. iOS then never
  collides with a fixed port.

### 3. FFI entry points inside `fuego-ffi`, behind a cargo feature

- Two Rust staticlibs force-loaded into one Runner binary each carry
  their own copy of the Rust standard library, so the link fails on
  duplicate symbols. walletd therefore goes into `fuego-ffi` behind a
  `walletd` feature, not into a second crate.
- `scripts/build-ios-ffi.sh` builds with `--features walletd`. Desktop
  and Android builds leave the feature off and keep spawning
  `fuego_walletd`.
- The calls:
  - `fuego_walletd_start(config_json) -> json {port, token}` or an error.
    It starts a process-global tokio runtime and the server. Calling it
    twice returns the running instance.
  - `fuego_walletd_stop()` shuts down gracefully. The sync task stops;
    sync state is written atomically per batch, so nothing is lost.
- Paired frees use the existing `fuego_string_free`.

### 4. Dart: iOS branch in `NodeConnection`

- On iOS, skip `DaemonManager.startAll()`. Instead:
  1. call `fuego_walletd_start` with remote mode (`--daemon-host` /
     `--daemon-port` equivalents), `await_wallet` and the data directory;
  2. take the returned port and token;
  3. build `ConnectionEndpoints` as for the proxy.
- From there, the existing flow is unchanged:
  - `open_wallet` after unlock;
  - `close_wallet` on lock through `FuegoVaultService.addLockListener`;
  - every cubit uses the same JSON-RPC calls.
- Network switching (`switchNetwork`) stops and restarts the server with
  the new daemon and testnet flag.

### 5. iOS lifecycle

**Foreground only.** On `AppLifecycleState.paused`, the vault already
locks and `close_wallet` runs. Then call `fuego_walletd_stop()`. On
`resumed`, start the server again; the wallet reopens after unlock.

**Why stop and restart:**
- iOS suspends the process in the background. It can also reclaim
  listening sockets of suspended apps, so a restart is more reliable
  than assuming the socket survived.
- A background sync running while the vault is locked would also keep
  decrypted key material in use.

**Background sync:**
- `BGAppRefreshTask` windows are a separate, optional step.
- They need the view key without the full vault unlock. That is a
  security decision of its own.

**First sync on a phone:**
- Interrupted scans resume from the last committed batch. Scan state is
  written in one atomic batch, and re-scanning is idempotent.
- How long a full sync from a recent restore height takes on a device
  is not measured yet.

### 6. Storage on iOS

- Data directory: Application Support from `path_provider`. It holds
  `wallets/<id>/wallet_state.sled`.
- No seed is written. The seed comes from the vault through
  `open_wallet`.
- The state still records which outputs, key images and amounts belong
  to the wallet:
  - exclude the directory from iCloud backup (`isExcludedFromBackup`);
  - set the file protection class to
    `NSFileProtectionCompleteUntilFirstUserAuthentication`.
- `master_seed.bin` (the legacy walletd wallet) never existed on iOS. No
  legacy sweep path is needed there.

### 7. Dependencies on iOS targets (unverified)

walletd pulls in:
- tokio (full)
- axum
- sled
- reqwest with rustls
- keyring (used by `keystore.rs`)
- bip39, ed25519-dalek, curve25519-dalek

None of this has been compiled for `aarch64-apple-ios` here; there is no
Apple toolchain in this environment.
- `keyring` 3 has an iOS Keychain backend. Check whether walletd needs
  `keystore.rs` at all in `--await-wallet` mode, where the seed comes
  from the vault. If not, put it behind a cfg for iOS.
- Then check the staticlib size. tokio, axum and reqwest add several MB.

### 8. CI

On the macOS runner:
1. build the iOS simulator slice with `--features walletd`;
2. run a simulator integration test:
   - start;
   - `/health` with no token: 200;
   - `wallet_status` with no token: 401;
   - with the token:
     - `wallet_status`;
     - `open_wallet` with a test seed;
     - `wallet_status` shows it open;
     - `close_wallet`;
   - stop.

The device slice gets a link check, as `libfuego_ffi.a` does today.

### 9. Not covered: xfg-swapd

xfg-swapd is a separate C++ process for cross-chain atomic swaps. It has
the same subprocess problem and no Rust or FFI path. Cross-chain swaps
stay unavailable on iOS. Hearth (on-chain HEAT/XFG) swaps work, because
walletd builds them.

## What usable means at the end

On iOS:
- the wallet scans and shows its balance;
- XFG and HEAT sends work;
- CDs: create, claim and rollover;
- sub-addresses;
- HEAT mint;
- Hearth swaps, LP and limit orders;
- tx proofs.

All of these go through the same walletd code and JSON-RPC as desktop
and Android.

Missing on iOS:
- background sync;
- mining;
- cross-chain swaps.

## Step order and dependencies

| Step | Depends on | Platforms |
|---|---|---|
| 1 Token auth | — | all; fixes a live hole on desktop and Android |
| 2 Library split | — | all |
| 3 FFI start/stop | 2 | iOS |
| 4 NodeConnection iOS branch | 1, 3 | iOS |
| 5 Lifecycle | 4 | iOS |
| 6 Storage | 3 | iOS |
| 7 Dependency check | 3 | iOS (first thing to run on a Mac) |
| 8 CI | 3, 4 | iOS |
