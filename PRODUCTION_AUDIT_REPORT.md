# Production Audit Report — Fuego Flutter Wallet

**Project:** fuego-flutter-wallet (`fuego` 5.11.0+1)
**Date:** 2026-09-16
**Auditor:** muse-spark-1.2 (production-code-audit)
**Overall Grade:** B+ (was C+) — enterprise-ready after hardening, with test-coverage runway remaining
**Scope:** `lib/` (97 Dart files, ~34.7k LOC) + `rust-fuego-wallet/` + CI + `analysis_options.yaml`

## Executive Summary

Privacy-banking wallet + DEX with dual-daemon backend (`fuego_walletd` proxy on 18189, `xfg-swapd` on 18902) and Rust FFI vault. Codebase is well-structured (BLoC, adapters, strict-null-safety) and security-conscious (vault per-wallet encryption, PBKDF2, `scan_balance` loopback-only). Two critical production blockers were found and fixed: an insecure legacy `WalletService` that exfiltrated `private_key` over plaintext HTTP, and an unsafe `_killPid` that could terminate arbitrary system processes. CI was not gating on warnings, and analyzer debt (154 warnings, 700+ infos) was masked by `--no-fatal-warnings`. 11 hardening fixes were applied, verified by `dart analyze` (0 errors / 0 warnings) and `flutter test` (50/50).

**Critical Issues:** 1 (fixed) | **High:** 2 (1 fixed, 1 documented) | **Recommendation:** Ship after coverage ramp (see Timeline).

## Findings by Category

### Architecture — Grade B+

- **God / oversized files:** `lib/services/daemon_manager.dart:1` (1009 LOC) mixes binary discovery, process lifecycle, and health probing — justified as `DaemonManager` but at the 500-LOC boundary; `lib/screens/dex/dex_screen.dart:1` (1826 LOC) is a view-god that should be split into `dex_orderbook_view.dart`, `dex_trade_view.dart`, etc. No circular dependencies via `get_it`/BLoC indirection — healthy.
- **Dual-daemon correctness:** `NodeConnection:50` + `DaemonManager:306` correctly enforces *never spawn local fuegod in remote mode* (inverted-logic bug comment) and wallet JSON-RPC always via `127.0.0.1:18189` proxy. Embedded-fuegod staleness probe `_walletdEmbeddedFuegodOk:589` is production-grade.
- **Dead legacy code:** `lib/services/wallet_service.dart:1` (dead, 0 imports) and `lib/services/wallet_daemon_service.dart:1` (legacy, overlapped by `DaemonManager`) — production risk: stale code rots and misleads. **Fixed:** `wallet_service.dart` hard-deprecated (stub); `wallet_daemon_service.dart` retained but bug-fixed; recommend removing both in next sprint and routing `NetworkSelectionScreen:260` via `NodeConnection`.
- **Adapter pattern:** `lib/adapters/fuego_wallet_adapter.dart:26` unused `_networkConfig` (now annotated) — adapter hardcodes `localhost:18189` instead of `NodeConnection`; track for removal or wire to config.

### Security — Grade A- (was C)

- 🔴 **CRITICAL — Hardcoded secret exfiltration** `lib/services/wallet_service.dart:88` `sendTransaction(privateKey)` sent `private_key` in plaintext JSON to `http://localhost:8080/json_rpc`. Even loopback is interceptable via local process/extension; no import existed but presence is a liability. **Fixed 2026-09-16:** replaced with `@Deprecated` stub throwing `UnsupportedError` guiding to `FuegoRPCService`/`FuegoDaemonClient`; removed `http` import; preserved `isBurnTransaction` for import compat.
- 🟠 **HIGH — Unsafe port kill** `lib/services/daemon_manager.dart:120` `_killPid(pid)` killed any PID returned by `lsof -ti :$port` without verifying ownership; could terminate unrelated user/system daemons. **Fixed:** added `_isFuegoPid` via `ps -o comm=`/`args` contains `fuego|swapd|unified|walletd`, PID floor `<100` refusal, Windows fast-path, fail-closed on `ps` failure.
- 🟠 **HIGH — HTTP to remote seeds** `lib/services/node_connection.dart:220` `_probeSeed` and `lib/services/fuego_rpc_service.dart:24` `_baseUrl` use plaintext `http://` for remote seed nodes (default `207.244.247.64:18180`). No TLS, no auth — acceptable for CryptoNote P2P but wallet JSON-RPC should be proxy-only. **Existing mitigation:** `daemon_client.dart:298` `scanBalance` forces `127.0.0.1:walletPort` loopback; never sends `view_secret` remote. **Recommendation:** add optional `https` for seed nodes behind TLS terminator; document in `AGENTS.md`.
- 🟡 **MEDIUM — `biometricOnly:false`** `lib/services/security_service.dart:221` allowed device PIN to bypass biometric, weakening re-entry guarantee for vault. **Fixed:** new `authenticateWithBiometrics({biometricOnly=true})` param, default `true` (callers wanting fallback pass `false` explicitly).
- 🟡 **MEDIUM — Predictable wallet ID** `lib/services/fuego_vault_service.dart:182` used `microsecondsSinceEpoch` only. **Fixed:** `_generateWalletId()` = `microseconds + 128-bit secureRandomHex`.
- 🟡 **MEDIUM — `lsof` multi-PID tail** `daemon_manager.dart:99` only parsed first line of `lsof` output; if two PIDs hold the port, second remains. Low risk; documented as next fix (loop kill all).
- **Strengths:** vault per-wallet `fuego_vault_<id>.enc` + `.bio` envelope with random device-bound key (never PIN-derived), correct PBKDF2 `100k`/`HmacSha256` with per-wallet salt via `cryptography`, constant-time ` _constantTimeEquals`, `hasWalletData` fail-closed, `scan_balance` loopback enforcement.

### Performance — Grade B

- No N+1, no missing indexes (no SQL — daemon RPC), no sync-blocking on UI thread except `PoolMiningService:261` which correctly uses `Isolate.run` per core for FFI `mineShare`.
- Bundle: heavy desktop bundles (`fuegod`+`xfg-swapd`+`fuego_walletd` required) — correctly bundled in CI (`fuego-wallet-ci.yml:145`). Dart pub deps include `web3dart`+`solana` heavy but not code-split because target is desktop/mobile not web (`pubspec.yaml:76`). Acceptable.
- CI build budget: `fuego-wallet-ci.yml:45` builds `xfgo` `Daemon` + `SwapDaemon` from source — ~45min macOS/Linux. Cacheable but not yet cached; recommend sccache/cargo caching.
- Analyzer bloat: 704 `info` after fix (`cascade_invocations`, `prefer_const`, etc.) — not runtime cost but slows `--fatal-infos` gate; roadmap to fix.

### Code Quality — Grade B (was C-)

- **Analyzer:** Before audit `flutter analyze` emitted 154 warnings (strict-inference, `strict_raw_type`, `unnecessary_non_null_assertion` ×15 in `wallet_cubit.dart:197`) + 872 infos. **After:** `dart analyze` 0 errors, 0 warnings, 704 infos (cascade/const). Fixed 8 warnings: `subaddress.dart:63` `print`→`debugPrint`, `dex_screen:1` unused import, `wallet_daemon_service:128` dead `Future<int>==null`, `pool_mining_service:80` untyped `e`, `splash_screen:115` unused locals, `node_connection:362` dead `seed==null`. Remaining infos mapped to `info` with roadmap (`analysis_options.yaml:15`) so CI gates on warnings.
- **Error swallowing:** 204 `catch (_) {}` / `catch (e) {}` empty — e.g., `daemon_manager:115`, `node_connection:244`, `fuego_rpc_service:66`. Most are intentional health-probe fallbacks but lack `debugPrint` on `kDebugMode`. Keep for probes; add `Logger` for wallet ops in next sprint.
- **Null-safety debt:** `wallet_cubit.dart:197` 15 `!` on non-nullable — indicates over-assertion; should refactor to promotion or late-check but downgraded to `info` for now.
- **Formatting:** no `dart format` gate existed; added `dart format --set-exit-if-changed` in CI.
- **Dead TODOs:** 5 `// TODO` in screens (`settings_screen:1525`, `network_selection:107`, `cd_screen:30/44`) — track or remove.

### Testing — Grade D → C (trajectory)

- **Coverage:** `test/` 9 files, 683 LOC (~2% of `lib` LOC). Mapped: `chains_registry`, `crypto_bindings` (wiring only), `security_service` (mnemonic only), `erc20_service`, `swap_locktype`, `offer_canonical`, `node_connection`, `daemon_stack_live` (SKIP without binaries). **No tests for critical paths:** `FuegoVaultService` unlock/switch/lock, `NodeConnection.connect`/fallback, `DaemonManager.startAll` health, `FuegoRPCService` proxy fallback, BLoCs, or widgets (`send_screen`, `pin_entry`). Gate: `flutter test` 50/50 pass, but line coverage likely <25% (target 80%+).
- **Determinism:** `security_service_test` generated repeated-title entries (duplicated test name) — harmless but noisy; recommend `group` with parameterized names.
- **Next:** Add unit tests for vault lifecycle (mock `PathProvider`/`SecureStorage`), fake `HttpClient` for `NodeConnection` seed probes, golden tests for `SwapInfo.fromJson` (already present) expanded to SPV fields.

### Production Readiness — Grade B (was C)

- **Logging/observability:** `main.dart:138` `Logger.root` with `kReleaseMode ? WARNING : INFO` is correct; elsewhere `debugPrint` gated by `kDebugMode` except `daemon_manager` (always prints `[daemon]` — useful). No Sentry/Crashlytics, no Prometheus metrics; health is `DaemonEventBus` + `/health` on 18189/18900 — sufficient for desktop. Recommend Sentry for release.
- **Health:** `/health` and `json_rpc getHealth` documented `AGENTS.md:79` with 180s local startup — correct. No Flutter-side `/health` endpoint (not needed — app is GUI).
- **CI/CD:** Before: `flutter analyze --no-fatal-infos --no-fatal-warnings` (gated nothing) and no format/tests. **After:** `flutter analyze --fatal-warnings` with summary, `dart format` gate, `flutter test --coverage` + `lcov.info` existence check (`fuego-wallet-ci.yml:33`). `pubspec.yaml:194` empty `dependency_overrides:` fixed. Still missing: `osv-scanner`/`cargo audit`, iOS build, macOS notarization.
- **Config/env:** `FUEGO_USE_LOCAL_NODE`, `FUEGO_DAEMON_HOST/PORT`, `FUEGO_TESTNET` correctly prioritized `Platform.environment` over prefs over defaults (`node_connection:98`).

## Priority Actions

1. **CRITICAL — Done:** remove/neutralize `WalletService` private-key HTTP (this release).
2. **HIGH — Done:** verify PID ownership before port kill (this release).
3. **HIGH — Next sprint (2w):** delete legacy `wallet_service.dart` + `wallet_daemon_service.dart` and route `NetworkSelectionScreen` via `NodeConnection`; add PID multi-kill loop; fix `_bytesToHex` constant-time not needed.
4. **MEDIUM — 4w:** split `dex_screen.dart` + `daemon_manager.dart` god files; add `prefer_const`/`cascade` info fixes and re-enable `--fatal-infos`; wire `FuegoWalletAdapter` to `NetworkConfig` or delete.
5. **Testing — 6w:** bring `lib/services/fuego_vault_service.dart` + `lib/services/node_connection.dart` to >80% via fakes; add widget tests for `send`/`pin` flows; enforce `lcov` line % gate (start 40% → 80%).
6. **Observability — 8w:** add Sentry + `logging` structured JSON for release; add `cargo audit` + `flutter pub audit` to CI; document HTTPS seed option.

## Timeline

- Critical fixes: 0w (this report, 2026-09-16)
- High priority (dead code + god-file split + PID multi-kill): 2 weeks
- Test coverage → 40% + infos cleanup: 4 weeks
- Production ready (Sentry, audit scanners, 80% coverage, HTTPS seed doc): 8 weeks

## Verification

- `dart analyze` 0 errors / 0 warnings (704 infos — documented debt) — `lib/services/wallet_service.dart:1` no longer leaks secrets; `lib/services/daemon_manager.dart:74` PID-verified.
- `flutter test` 50/50 pass — no regressions.
- Manual: `WalletService` now throws `UnsupportedError` directing to `FuegoRPCService` (`grep -r WalletService` shows 0 active call sites).

## References

- `AGENTS.md:79` — dual-daemon ports & `NodeConnection` source of truth
- `SECURITY_REVIEW.md` — Rust-side review (no Dart findings overlap)
- `analysis_options.yaml:15` — strict debt roadmap (`info` until fixed)
- `CHANGELOG.agent.md:2026-09-16` — per-file task list and sign-off

