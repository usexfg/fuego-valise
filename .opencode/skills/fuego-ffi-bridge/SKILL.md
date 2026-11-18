---
name: fuego-ffi-bridge
description: Fuego Valise Dart↔Rust FFI bridge operator guide — the live surface is lib/ffi/fuego_native.dart binding to the fuego-ffi crate (libfuego_ffi), NOT the dead crypto_bindings.dart copies. Use when working on native FFI bindings, Dart↔Rust symbol drift, adding Rust exports, fixing native/crypto vs rust-fuego-wallet duplication, cargo ndk Android/iOS native library builds, libfuego_ffi/libfuego_crypto load failures, or CI gates for the Rust SDK.
---

# Fuego FFI Bridge

Two Rust surfaces ship to devices. One is live, one is a near-dead mirror. Knowing which is which prevents most mistakes in this repo.

## Crate map (verified Sep 2026)

| Rust crate | Library | Status | Used by |
|---|---|---|---|
| `rust-fuego-wallet/fuego-sdk/fuego-ffi` | `libfuego_ffi` | **LIVE** — primary bridge | `lib/ffi/fuego_native.dart`, used by 5 services (vault, mining, output scanner, dex cubit, …) |
| `native/crypto` | `libfuego_crypto` | **LIVE for mobile only** — built + bundled by `fuego-wallet-mobile-ci.yml` | dependency of fuego-ffi (`use fuego_crypto::…`), Android jniLibs, iOS build |
| `lib/native/crypto` | — | **MIRROR, do not edit** | nothing imports it; keep in sync only because it is checked in |
| `fuego-sdk/fuego-crypto`, `fuego-vault` | — | Library crates, build clean | consumed by fuego-ffi |

Rules that follow from this:

1. New native capability → add the Rust export to `fuego-ffi` (`rust-fuego-wallet/fuego-sdk/fuego-ffi/src/lib.rs`), add the lookup in `lib/ffi/fuego_native.dart`. Never touch `crypto_bindings.dart` — it is imported by zero files.
2. `lib/native/crypto/` and `native/crypto/` share identical `Cargo.toml` and `bindings/crypto_bindings.dart` byte-for-byte; `lib/native/crypto/src/lib.rs` is a trimmed copy (620→539 lines). When you change one `lib.rs` you must mirror it. The cleanest end state is deleting the mirror — but do that only in a dedicated PR, never incidentally.
3. `native/crypto` is a standalone crate (its own lockfile, NOT a workspace member of `rust-fuego-wallet/`). `fuego-ffi` IS a workspace member. Their `src/cn/` C sources are identical copies — the `build.rs` files must stay behaviorally identical too.

## Build config invariant (do not regress)

Both `build.rs` files compile Cryptonight C sources (`src/cn/slow-hash.c` etc.) via `cc`. They must define `_GNU_SOURCE` and use `-std=gnu11` (not strict `-std=c11`): `slow-hash.c` uses `MAP_ANONYMOUS`/`MAP_HUGETLB`, which strict c11 hides on glibc and breaks the Linux build. Both were fixed 2026-09; if a Linux build fails with `MAP_ANONYMOUS undeclared`, a build.rs lost this.

## Binding-consistency gate (the thing that actually catches drift)

The invariant that matters: **every symbol `fuego_native.dart` looks up must be exported by `fuego-ffi`.** Check with:

```bash
RUST=$(grep -oE 'fn (fuego|cn)_[a-z_]+' rust-fuego-wallet/fuego-sdk/fuego-ffi/src/lib.rs | sed 's/fn //;s/(//' | sort -u)
DART=$(grep -oE "lookupFunction<[^,]+,[^>]+>\('[a-z_]+'" lib/ffi/fuego_native.dart | grep -oE "'[a-z_]+'" | tr -d "'" | sort -u)
comm -23 <(echo "$DART") <(echo "$RUST")   # must be EMPTY
```

Reverse direction (Rust exports with no Dart caller) is informational, not an error — 15 exports (swap-pair, HTLC, chain helpers, payment proof) are intentionally reserved for the transaction-builder plan.

## Test contract

`native/crypto/src/lib.rs` tests mirror the Dart caller contracts. Notable: `fuego_generate_address` needs a **200-byte** output buffer (matches `calloc<Int8>(200)` in `crypto_bindings.dart`); a 100-byte buffer correctly fails with -1 — that is the API working, not a bug. The one historical test failure (`tests::test_address_generation`) was the test under-sizing the buffer; fixed 2026-09.

## Local verification loop

```bash
cargo test --manifest-path rust-fuego-wallet/fuego-sdk/fuego-ffi/Cargo.toml
cargo test --manifest-path native/crypto/Cargo.toml
```

Known baseline (Sep 2026): both pass; 0 tests in fuego-crypto/fuego-vault crates; `cargo clippy -D warnings` and `cargo fmt --check` DO NOT pass on this codebase yet (81+ warnings, 10 clippy errors, fmt diffs in fuego-ffi) — so CI runs clippy as non-blocking. Do not treat a clippy failure as your regression unless you introduced it.

## Mobile builds

Mobile CI (`fuego-wallet-mobile-ci.yml`) is the only place that builds both crates:
- Android: `cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -t x86 --platform 25 -- build --release` in each crate, outputs copied to `android/app/src/main/jniLibs/<abi>/`
- iOS: `cargo build --release --target aarch64-apple-ios` in each crate

Library load names the Dart side expects: `libfuego_ffi.so|dylib|dll` / `libfuego_crypto.so|dylib`, resolved by `FuegoNative._openLibrary()` and `CryptoBindings.init()`. If a service silently "falls back to RPC", the first suspect is a missing jniLib or a symbol lookup failing at `DynamicLibrary.open`.
