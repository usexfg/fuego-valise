use std::env;
use std::fs;
use std::path::PathBuf;

// fuego-suite's slow-hash.c has two defects on the portable (non-AES-NI, non-ARM-crypto)
// path, which every Android ABI compiles. Until they are fixed upstream (see
// patches/slow-hash-portable.patch), the compiled copy is corrected here. Each fix is an
// exact-text replacement: if suite already carries the fix it is skipped, and if the
// text changed in some other way the build stops so the change gets reviewed.
struct SourceFix {
    name: &'static str,
    buggy: &'static str,
    fixed: &'static str,
}

const SLOW_HASH_FIXES: &[SourceFix] = &[
    // Light mode swaps which chunks are *loaded*; stores always go to the fixed
    // ^0x10/^0x20/^0x30 offsets, exactly as VARIANT2_SHUFFLE_ADD_SSE2/_NEON do.
    // Storing through the swapped pointers gave a different CN-UPX/2 (Fuego PoW) hash.
    SourceFix {
        name: "VARIANT2_PORTABLE_SHUFFLE_ADD light-mode store offsets",
        buggy: r#"    uint64_t* chunk1 = (light ? U64((base_ptr) + ((offset) ^ 0x30)) : U64((base_ptr) + ((offset) ^ 0x10))); \
    uint64_t* chunk2 = U64((base_ptr) + ((offset) ^ 0x20)); \
    uint64_t* chunk3 = (light ? U64((base_ptr) + ((offset) ^ 0x10)) : U64((base_ptr) + ((offset) ^ 0x30))); \
    \
    const uint64_t chunk1_old[2] = { chunk1[0], chunk1[1] }; \
    \
    uint64_t b1[2]; \
    memcpy(b1, b + 16, 16); \
    chunk1[0] = chunk3[0] + b1[0]; \
    chunk1[1] = chunk3[1] + b1[1]; \
    \
    uint64_t a0[2]; \
    memcpy(a0, a, 16); \
    chunk3[0] = chunk2[0] + a0[0]; \
    chunk3[1] = chunk2[1] + a0[1]; \
    \
    uint64_t b0[2]; \
    memcpy(b0, b, 16); \
    chunk2[0] = chunk1_old[0] + b0[0]; \
    chunk2[1] = chunk1_old[1] + b0[1]; \"#,
        fixed: r#"    uint64_t* p10 = U64((base_ptr) + ((offset) ^ 0x10)); \
    uint64_t* p20 = U64((base_ptr) + ((offset) ^ 0x20)); \
    uint64_t* p30 = U64((base_ptr) + ((offset) ^ 0x30)); \
    const uint64_t* src1 = light ? p30 : p10; \
    const uint64_t* src3 = light ? p10 : p30; \
    const uint64_t chunk1[2] = { src1[0], src1[1] }; \
    const uint64_t chunk2[2] = { p20[0], p20[1] }; \
    const uint64_t chunk3[2] = { src3[0], src3[1] }; \
    \
    uint64_t b1[2]; \
    memcpy(b1, b + 16, 16); \
    uint64_t a0[2]; \
    memcpy(a0, a, 16); \
    uint64_t b0[2]; \
    memcpy(b0, b, 16); \
    p10[0] = chunk3[0] + b1[0]; \
    p10[1] = chunk3[1] + b1[1]; \
    p20[0] = chunk1[0] + b0[0]; \
    p20[1] = chunk1[1] + b0[1]; \
    p30[0] = chunk2[0] + a0[0]; \
    p30[1] = chunk2[1] + a0[1]; \"#,
    },
    // data+35 is not 8-byte aligned; the direct uint64_t load faults (SIGBUS) on armv7.
    SourceFix {
        name: "VARIANT1_INIT64 unaligned nonce load",
        buggy: "(state.hs.w[24] ^ (*((const uint64_t*)NONCE_POINTER)))",
        fixed: "(state.hs.w[24] ^ cn_load_u64_unaligned(NONCE_POINTER))",
    },
    SourceFix {
        name: "unaligned load helper",
        buggy: "#define VARIANT1_INIT64() \\\n",
        fixed: "static inline uint64_t cn_load_u64_unaligned(const uint8_t *p) { uint64_t v; memcpy(&v, p, sizeof(v)); return v; }\n\n#define VARIANT1_INIT64() \\\n",
    },
];

fn main() {
    // Compiled from the fuego-suite submodule so the FFI hashes exactly what fuegod hashes.
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let suite_src = manifest_dir.join("../../../fuego-suite/src");
    let cn_dir = suite_src.join("crypto");

    if !cn_dir.join("slow-hash.c").exists() {
        panic!(
            "fuego-suite submodule is not checked out (missing {}). \
             Run: git submodule update --init fuego-suite",
            cn_dir.display()
        );
    }

    let mut slow_hash = fs::read_to_string(cn_dir.join("slow-hash.c")).unwrap();
    for fix in SLOW_HASH_FIXES {
        match (slow_hash.matches(fix.buggy).count(), slow_hash.contains(fix.fixed)) {
            (1, _) => slow_hash = slow_hash.replacen(fix.buggy, fix.fixed, 1),
            (0, true) => {}
            (n, _) => panic!(
                "fuego-suite slow-hash.c changed around \"{}\" ({} matches): \
                 review build.rs SLOW_HASH_FIXES against the new source",
                fix.name, n
            ),
        }
    }
    let patched = out_dir.join("slow-hash.c");
    fs::write(&patched, slow_hash).unwrap();

    let cn_sources = [
        "hash.c",
        "oaes_lib.c",
        "aesb.c",
        "blake256.c",
        "groestl.c",
        "jh.c",
        "skein.c",
        "keccak.c",
        "hash-extra-blake.c",
        "hash-extra-groestl.c",
        "hash-extra-jh.c",
        "hash-extra-skein.c",
    ];

    let mut build = cc::Build::new();

    build
        .file(&patched)
        .files(cn_sources.iter().map(|f| cn_dir.join(f)))
        .include(&cn_dir)
        .include(&suite_src) // Common/int-util.h, Common/static_assert.h
        // The portable and ARM-without-crypto paths otherwise put the 2 MiB scratchpad
        // on the stack; Dart isolate threads have ~1 MiB. AES-NI/ARM-crypto paths ignore it.
        .define("FORCE_USE_HEAP", None)
        .flag_if_supported("-std=c11")
        .flag_if_supported("-O2");

    // Only add -maes on x86_64
    let target = env::var("TARGET").unwrap_or_default();
    if target.contains("x86_64") {
        build.flag("-maes");
    }

    build.compile("cryptonight");

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed={}", cn_dir.display());
    println!("cargo:rerun-if-changed={}", suite_src.join("Common").display());
}
