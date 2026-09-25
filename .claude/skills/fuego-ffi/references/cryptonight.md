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

## Known defects on the portable path (in fuego-suite, so fuegod has them too)

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
3. **armv7 unaligned load in `VARIANT1_INIT64`.** An eval run reported
   `ldrd` at `data+35` faulting (SIGBUS) under qemu. The fix is a
   `memcpy`. Variant 1 only.
4. `_exit(1)` on variant 1 with fewer than 43 bytes, and variant ≥ 3
   silently hashed as variant 2. Validate arguments in the Rust export
   so the app is never killed.

Suite is a submodule, and this repo cannot patch it in place. Fixes 1 and
3 belong upstream in `fuego-suite/src/crypto/slow-hash.c`. After they
land, move the pin. Fix 2 and the argument checks from item 4 belong in
this repo's `build.rs` and `lib.rs`.

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

The in-tree tests (`cn_v0_vectors`, `cn_v2_vectors`) cover v0 and v2
with `light = 0` only. **Nothing tests variant 2 + light**, the actual
PoW. A known-answer vector for it must come from fuegod's own x86_64
path, which is consensus. For example, hash a mainnet block's hashing
blob, then check the result against that block's difficulty. An eval run
reported that suite's `tests/PowBytes` block 1,000,001 parent blob
hashes to
`ce75e0286b8039a0db4f02c026d2a908c0b82da8de0daec1310e6c2387000000`.
Re-derive it before pinning it in a test.

## Share checking in `fuego_mine_share`

Stratum sends a 4-byte little-endian target `t`. A share is valid when
the hash, read as a little-endian 256-bit number, satisfies
`hash_u64_at_offset_24 < u64::MAX / (u32::MAX / t)`. That is xmrig's
check on the **last** 8 bytes. `fuego_mine_share` compares the **first**
4 bytes against `t`, so the pool rejects the shares it reports and misses
real ones. Fixing this changes the function's semantics, so add a test
with a known share when you do.
