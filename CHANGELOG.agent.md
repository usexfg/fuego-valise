# CHANGELOG.agent.md

## [2026-11-10] Restore iOS FFI prebuild in Mobile CI

The Build iOS job failed because `flutter build ios --simulator` expects `libfuego_ffi.a` for x86_64-apple-ios (and aarch64-apple-ios-sim) via OTHER_LDFLAGS force_load, but the Xcode "Build fuego-ffi" script phase does not execute reliably after Flutter's SPM project migration on CI runners. Explicitly pre-build all three iOS Rust targets (device + both simulators) with cargo before the Flutter build. Also correct the artifact upload path to the simulator .app (no .ipa is produced by `--simulator`).

| # | Task | Owner | Date | Status |
|---|------|-------|------|--------|
| 121 | Add explicit cargo build of fuego-ffi for aarch64-apple-ios, aarch64-apple-ios-sim, x86_64-apple-ios in build-ios job | Grok Agent | 2026-11-10 | Done |
| 122 | Fix upload-artifact path from non-existent .ipa to build/ios/iphonesimulator/*.app | Grok Agent | 2026-11-10 | Done |

### Sign-off

CI workflow only. No source or crypto changes. Android and Analyze jobs were already green.

