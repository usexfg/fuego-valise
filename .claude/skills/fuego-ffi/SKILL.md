---
name: fuego-ffi
description: Rust↔Dart FFI boundary for Fuego Valise. Covers the fuego-ffi crate (rust-fuego-wallet/fuego-sdk/fuego-ffi), its Dart bindings (lib/ffi/fuego_native.dart), CryptoNight compiled from the fuego-suite submodule, and how libfuego_ffi is built, bundled and loaded on macOS, Linux, Windows, Android and iOS. Use this skill whenever a task touches fuego-ffi, FuegoNative, dart:ffi typedefs, lookupFunction, cn_slow_hash/CryptoNight/mining hashes, vault/key/address FFI calls, FuegoBytes/FuegoResult, fuego_string_free/fuego_bytes_free, a "Failed to lookup symbol" or "Failed to load dynamic library" error, libfuego_ffi.{dylib,so,a,dll}, force_load/STRIP_STYLE in the iOS Xcode project, jniLibs, or a fuego-suite submodule bump that could change the crypto sources, even if the user never says "FFI".
---

# fuego-ffi

The wallet's native crypto (keys, addresses, vault, CryptoNote signatures,
CryptoNight mining hash, swap-pair metadata) crosses one boundary: the Rust
crate `fuego-ffi` exports C functions, and `FuegoNative` in Dart binds them.
Nothing checks that boundary at compile time. A wrong Dart typedef compiles,
links and often works, then corrupts memory on a different CPU or input
size. Treat every change here as ABI work.

## Where things live

| Piece | Path |
|---|---|
| C exports | `rust-fuego-wallet/fuego-sdk/fuego-ffi/src/lib.rs` (`crate-type = ["cdylib","staticlib"]`) |
| CryptoNight build | `rust-fuego-wallet/fuego-sdk/fuego-ffi/build.rs`, which compiles C from `fuego-suite/src/crypto` |
| Dart bindings | `lib/ffi/fuego_native.dart` (`FuegoNative`, typedef pairs at the bottom, `FuegoBytes`/`FuegoResult` structs) |
| Callers | `lib/services/fuego_vault_service.dart`, `lib/services/pool_mining_service.dart`, `lib/bloc/dex/dex_cubit.dart` |
| Rust crypto it wraps | `rust-fuego-wallet/fuego-sdk/fuego-crypto`, `fuego-vault`, `fuego-sdk` |
| Per-platform load/link | `references/platforms.md` |
| CryptoNight paths, PoW, mining | `references/cryptonight.md` (read before touching `cn_slow_hash`, `mine_share`, `build.rs` or the pool miner) |
| Boundary checker | `scripts/check_ffi_bindings.py` |

`fuego-suite/` is a git submodule. There is no vendored copy of the C
crypto. `build.rs` panics with an instruction if the submodule is missing:
run `git submodule update --init fuego-suite`. Do not reintroduce a copy
under `native/` or `lib/native`. Those were deleted on purpose, because a
second copy drifts from the daemon that validates the hashes.

## Run the checker first and last

```bash
python3 .claude/skills/fuego-ffi/scripts/check_ffi_bindings.py --unused
```

For every symbol Dart looks up, it compares the Rust signature with the
Dart `Native` typedef: arity, C width and signedness per argument and
return. It also compares `#[repr(C)]` struct layouts with their Dart
`Struct` mirrors. An ERROR means the C ABI disagrees. A WARN means same
width, different signedness; `--strict` fails on those too. Run it before
editing so you know which errors already existed, and after, to show you
added none. It is regex-based, so if you write an unusual signature shape
and the checker stops seeing a symbol, fix the shape or the checker; do
not ignore the miss.

## Type mapping (Rust → Dart native / Dart)

| Rust | Dart native type | Dart type |
|---|---|---|
| `usize` | `Size` | `int` |
| `u8` / `i8` | `Uint8` / `Int8` | `int` |
| `u32` / `i32`, `c_int` | `Uint32` / `Int32` | `int` |
| `u64` / `i64` | `Uint64` / `Int64` | `int` |
| `bool` | `Bool` | `bool` |
| `*const u8`, `*mut u8` | `Pointer<Uint8>` | same |
| `*const c_char`, `*mut c_char` | `Pointer<Utf8>` | same |
| `FuegoBytes` (by value) | `FuegoBytes` | same |
| `()` | `Void` | `void` |

`usize` is 64-bit on every target the app ships (arm64, x86_64), so
`Int32` is the wrong width even when small values happen to work: the
arm64 and x86-64 calling conventions leave the upper 32 bits of an
`int32` argument unspecified, so the callee has no guarantee about them. A
length read as `usize` can then pick up garbage and `slice::from_raw_parts`
reads out of bounds. Use `Size` and match signedness for anything new.
Struct fields follow the same rule: `FuegoBytes.len` is `@Size()`.

## Conventions every export follows

- `#[no_mangle] pub unsafe extern "C" fn fuego_<area>_<verb>`. Mark it
  `unsafe` when it dereferences a raw pointer. The `fuego_` prefix is how
  the iOS and CI symbol checks find exports.
- **Return shapes.** Use exactly one of these:
  - A JSON or hex C string (`CString::into_raw`). The caller frees it with
    `fuego_string_free`.
  - `FuegoBytes { ptr, len }` built from `into_boxed_slice` +
    `mem::forget`. The caller frees it with `fuego_bytes_free(ptr, len)`.
    Its `from_raw_parts(ptr, len, len)` requires capacity == len, which is
    why the boxed slice is mandatory.
  - `FuegoResult { ok, error }`. `error` is null or a C string the caller
    frees.
  - A plain scalar or `bool`, or `c_int` with 0 for success and a negative
    value for failure, plus out-pointers.
- **Panics.** A panic unwinding out of `extern "C"` aborts the process.
  No export uses `std::panic::catch_unwind` today. New exports that call
  into non-trivial Rust (bincode, vault, serde) should wrap the body and
  return the failure value on `Err`.
- **Null pointers.** Check every pointer argument for null before use, and
  return the function's documented failure value: `""`,
  `{"error":"..."}`, an empty `FuegoBytes`, `false`, or `-1`. Never panic
  across the boundary. A panic unwinding out of `extern "C"` aborts the
  app. Replace `unwrap()` on inputs with an error return. `CString::new`
  on JSON you built yourself is the one accepted `unwrap`.
- **Fixed-size inputs.** Keys, hashes and seeds are exactly 32 bytes and
  signatures 64. Rust reads that many bytes from the pointer, so the Dart
  side must `assert` the length before allocating.
- **Memory ownership.** Rust frees only what Rust allocated, and Dart
  frees only what Dart allocated (`calloc`/`toNativeUtf8` →
  `calloc.free`). Every `Pointer<Utf8>` result goes through `_freeString`,
  and every `FuegoBytes` through `_bytesToList`, which copies, then frees.
  Read a returned string with `toDartString()` before freeing it.
- **Secrets.** Secret keys, seeds and vault bytes pass through native
  memory. Before `calloc.free`, zero Dart-allocated buffers holding
  secrets (`ptr.asTypedList(n).fillRange(0, n, 0)`). New Rust code
  returning secrets should zero its copies too. The `zeroize` crate is not
  yet a dependency, so adding it is a deliberate choice, not a silent one.
  Existing code does neither; do not copy that gap into new functions.

## Adding a function

1. Rust: add the export in `lib.rs` in the matching `// ── section ──`,
   following the conventions above. Add a `#[cfg(test)]` test that calls
   the `extern "C"` function itself, not only the inner Rust function.
   The existing CryptoNight vector tests are the model.
2. Dart: add a `_XNative`/`_XDart` typedef pair at the bottom of
   `fuego_native.dart` using the mapping table. Add a method on
   `FuegoNative` that allocates inputs, calls, copies the result out,
   frees everything, and decodes JSON with `jsonDecode` from
   `dart:convert`. The existing `_parseJson` splits on `,` and `:`, so it
   breaks on any value containing either; do not reuse it for new
   structured results.
3. No per-platform link changes are needed. The cdylib and staticlib
   export every `#[no_mangle]` symbol, and iOS force-loads the whole
   archive. Only a **new crate**, a **new C source file**, or a
   **new system library** touches `build.rs` or the platform wiring (see
   `references/platforms.md`).
4. Verify (next section).

## Verification gates

Run what applies. Say plainly which gates you could not run and why.

| Gate | Command |
|---|---|
| Boundary | `python3 .claude/skills/fuego-ffi/scripts/check_ffi_bindings.py` |
| Rust unit + CN vectors | `cargo test --manifest-path rust-fuego-wallet/Cargo.toml -p fuego-ffi` |
| Dart analysis | `flutter analyze lib/ffi` |
| Symbols in the built library | Linux: `nm -D --defined-only rust-fuego-wallet/target/release/libfuego_ffi.so \| grep fuego_`. macOS: `nm -gU …/libfuego_ffi.dylib`. iOS app: `nm -gU build/ios/iphoneos/Runner.app/Runner \| grep _fuego_` |
| Wire format vs fuegod | `FUEGOD_RPC_URL=http://127.0.0.1:28180 cargo test -p fuego-sdk --test fuegod_wire -- --ignored` against `fuegod --testnet` (CI job `fuegod-wire-check`) |

CI coverage: `fuego-wallet-ci.yml` runs `cargo test -p fuego-ffi`.
`fuego-wallet-mobile-ci.yml` builds Android (cargo-ndk, four ABIs) and iOS,
then checks `_fuego_(mine_share|vault_from_seed|make_address)` in Runner.
`ios-release.yml` and `appstore-release.yml` build the iOS staticlib and
check symbols after archive. **No workflow builds `fuego_ffi.dll` for
Windows**, so Windows FFI is unverified.

## CryptoNight is not platform-neutral

The C in `slow-hash.c` compiles a different implementation per target
(AES-NI, ARM crypto, portable). The portable one gives a **different
Fuego PoW hash** and puts a 2 MiB scratchpad on the stack, and it is what
every Android ABI builds. The x86_64 tests cannot see either problem.
Read `references/cryptonight.md` before any mining or hashing work, and
test the portable path with `CFLAGS=-DNO_AES cargo test -p fuego-ffi`.

## Submodule bumps

Dependabot opens a PR when fuego-suite master moves. `build.rs` compiles
whatever is at the pin, so a suite change to `src/crypto` changes the
wallet's mining hash with no Rust diff. On such a PR:

- Run `git -C fuego-suite diff <old>..<new> --stat -- src/crypto src/Common`.
- Diff `src/crypto/hash-ops.h`. `lib.rs` declares `cn_slow_hash` by
  hand, so a changed C signature still links and passes wrong arguments.
- Check `get_block_longhash` in `src/CryptoNoteCore/CryptoNoteFormatUtils.cpp`
  still selects variant 2 + light. `fuego_mine_share` hardcodes that
  selection.
- Run `cargo test -p fuego-ffi`, then run it again with `CFLAGS=-DNO_AES`
  (portable path). The CN v0/v2 known-answer vectors are the guard. They
  do not cover variant 2 + light, so also compare that hash between the
  old and new pins. If a vector fails, the suite changed consensus-relevant hashing.
  Stop and report; never update the expected hex to make it pass.
- If suite adds or renames a `.c` file the hash depends on, update the
  `cn_sources` list in `build.rs`. A link error naming a missing symbol
  such as `blake256_hash` or `groestl` is the usual sign.

## Known debt (as of this skill's writing)

`check_ffi_bindings.py` reports these. They are real, not checker noise.
Fix them when you are asked to, or when you touch the function anyway, and
say so.
- Ten `usize` parameters are bound as `Int32`: the `len`/`*_len`
  arguments of `bytes_free`, `cn_fast_hash`, `base58_encode`, `sign`,
  `verify`, the four `vault_*` calls and `mine_share`.
- `u32`/`u64` parameters are bound as signed `Int32`/`Int64`. This is
  harmless at the bit level, but the checker flags it under `--strict`.
- `fuego_cn_slow_hash` and `fuego_mine_share` are safe `extern "C" fn`s
  that dereference raw pointers without null checks.
- Secret buffers are freed without zeroing, and `vaultGetSeed` returns
  the seed as an immutable Dart `String`.
- CryptoNight portable-path defects (wrong v2-light hash, stack
  scratchpad, armv7 alignment) and `fuego_mine_share` comparing the
  wrong hash bytes against the pool target. See `references/cryptonight.md`.
- `Vault::get_address(n)` uses keys `n` (spend) and `n+1` (view). The
  Dart subaddress store starts at `n = 1`
  (`lib/models/subaddress.dart`, `WalletCubit.createSubaddress`), so
  subaddress 1's spend secret is the main wallet's view secret. Anyone
  holding the view key can spend from it, and the main-key scan cannot
  see funds sent to it. The vault already has a non-overlapping
  `100 + 2n` scheme (`get_subaddress_spend_index`) that Dart does not
  use.
- `fuego_make_address` always uses the mainnet prefix. No FFI call
  takes the network.
- 13 exports have no Dart caller (`--unused` lists them). They are not
  dead: they are future API for swaps. Delete one only when asked.
