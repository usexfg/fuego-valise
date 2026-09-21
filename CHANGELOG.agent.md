# CHANGELOG.agent.md

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
