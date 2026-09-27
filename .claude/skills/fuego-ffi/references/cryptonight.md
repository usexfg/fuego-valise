# CryptoNight in fuego-ffi

Read this before touching `fuego_cn_slow_hash`, `fuego_mine_share`,
`build.rs`, the pool miner, or a fuego-suite bump that changes
`src/crypto`.

## Fuego's PoW

The algorithm is CryptoNight variant 2, `light = 1` (CN-UPX/2). suite
selects it in `get_block_longhash`
(`fuego-suite/src/CryptoNoteCore/CryptoNoteFormatUtils.cpp`).
`fuego_mine_share` hardcodes `cn_slow_hash(blob, len, out, light=1,
variant=2, prehashed=0)`. The C argument order is `(light, variant)`.
The Rust export `fuego_cn_slow_hash` takes `(variant, light)`, the
reverse, and swaps them internally. Keep that straight in any binding.

`lib.rs` declares `cn_slow_hash` by hand in an `extern "C"` block. If
suite changes the signature in `src/crypto/hash-ops.h`, the build still
compiles and links, but the call passes wrong arguments. On a suite bump,
diff `hash-ops.h`.

## Which code path each target compiles

`slow-hash.c` picks an implementation at compile time:

| Target | Path | Shuffle macro | Scratchpad |
|---|---|---|---|
| x86_64 (desktop, Android x86_64) | AES-NI (`-maes`), soft-AES fallback at runtime | `VARIANT2_SHUFFLE_ADD_SSE2` | `hp_state` (heap/mmap) |
| arm64 Apple (macOS, iOS) | NEON + crypto (`__ARM_FEATURE_CRYPTO` defined by Apple clang) | `VARIANT2_SHUFFLE_ADD_NEON` | heap |
| Android arm64-v8a, armeabi-v7a | ARM without crypto (the NDK clang does not define `__ARM_FEATURE_CRYPTO`) | `VARIANT2_PORTABLE_SHUFFLE_ADD` | **stack, 2 MiB**, unless `FORCE_USE_HEAP` |
| Android x86 (i686), any `-DNO_AES` build | portable C | `VARIANT2_PORTABLE_SHUFFLE_ADD` | **stack, 2 MiB**, unless `FORCE_USE_HEAP` |

Check a target with
`clang --target=<triple> -dM -E -x c /dev/null | grep ARM_FEATURE_CRYPTO`.

## Defects on the portable path (in fuego-suite, so fuegod has them too)

This repo compiles corrected code: `build.rs` applies fixes 1 and 3 to a
copy in `OUT_DIR` and defines `FORCE_USE_HEAP`, and `fuego_cn_slow_hash`
rejects the arguments from item 4. The upstream patch for fixes 1 and 3
is `rust-fuego-wallet/fuego-sdk/fuego-ffi/patches/slow-hash-portable.patch`.
A fuegod built for ARM without the crypto extension, or with `NO_AES`,
still computes the wrong PoW until suite takes the patch.

1. **Wrong hash for variant 2 + light.** The SSE2/NEON macros load from
   the swapped offsets and store to the fixed offsets `^0x10`, `^0x20`,
   `^0x30`. `VARIANT2_PORTABLE_SHUFFLE_ADD` stores through the swapped
   pointers, so for `light` it writes `[^0x30] = old[^0x10] + b1` where
   SSE2 writes `[^0x30] = old[^0x20] + a`. Every Android build therefore
   computes a different Fuego PoW hash from fuegod on x86_64. A fuegod
   built for ARM without the crypto extension would reject the real
   chain. The fix is to read all three chunks, then store to the fixed
   offsets exactly as the SSE2 macro does. Non-light variants are
   unaffected.
2. **2 MiB stack array.** Without `FORCE_USE_HEAP` the scratchpad is a
   local array. Dart isolate and Flutter threads have roughly 1 MiB of
   stack, so the call overflows. The result is SIGSEGV/SIGBUS, or
   silently stepping over the guard page. `build.rs` should
   `.define("FORCE_USE_HEAP", None)`. The hardware-AES paths ignore it.
3. **armv7 unaligned load in `VARIANT1_INIT64`.** An `ldrd` at
   `data+35` faults (SIGBUS) on armv7. The fix is a `memcpy`. Variant 1
   only.
4. `_exit(1)` on variant 1 with fewer than 43 bytes, and variant ≥ 3
   silently hashed as variant 2. Validate arguments in the Rust export
   so the app is never killed.

Verified: with the fixes, the unpatched portable output `11a8d02b…` for
block 1,000,001 becomes `ce75e028…`. That is byte-identical to AES-NI and
meets the block's difficulty. The tests pass on x86_64, `-DNO_AES`,
aarch64 without crypto (qemu) and armv7 (qemu).

## Testing the non-x86 paths without ARM hardware

- The portable path on x86_64:
  `CFLAGS=-DNO_AES cargo test -p fuego-ffi`. Confirm with
  `objdump -d` that the test binary has no `aesenc`.
  `MONERO_USE_SOFTWARE_AES=1` only switches the x86 path to soft AES at
  runtime. It keeps the SSE2 shuffle, so it does not exercise the
  portable macro.
- Real ARM builds under qemu-user: cross-build the test binary for
  `aarch64-unknown-linux-gnu` / `armv7-unknown-linux-gnueabihf` and run it
  with `qemu-aarch64` / `qemu-arm`. `qemu -cpu max` with `+crypto` covers
  the Apple-style path.
- Stack: run the hash on a thread with a 1 MiB stack
  (`RUST_MIN_STACK=1048576` for test threads) to catch a missing
  `FORCE_USE_HEAP`.

The in-tree tests are:
- `cn_v0_vectors` and `cn_v2_vectors` (canonical vectors)
- `fuego_pow_meets_mainnet_difficulty` (variant 2 + light on mainnet
  block 1,000,001's parent blob, checked against the block's difficulty
  31,300,056 and pinned to `ce75e028…87000000`)
- argument rejection, stratum target semantics, and agreement between
  `mine_share` and `cn_slow_hash`

## Share checking in `fuego_mine_share`

`fuego_mine_share(blob, blob_len, target, target_len, …)` takes the
stratum target as sent: 4 or 8 bytes, little-endian. It checks shares the
way pools (xmrig) do. The u64 at hash offset 24 must be below
`u64::MAX / (u32::MAX / t)` for a 4-byte `t`, or below the 8-byte value
directly. It returns 0 when found, -1 when nothing in range qualifies,
and -2 on bad arguments.
