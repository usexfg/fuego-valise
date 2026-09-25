use std::env;
use std::path::PathBuf;

fn main() {
    // Compiled from the fuego-suite submodule so the FFI hashes exactly what fuegod hashes.
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let suite_src = manifest_dir.join("../../../fuego-suite/src");
    let cn_dir = suite_src.join("crypto");

    if !cn_dir.join("slow-hash.c").exists() {
        panic!(
            "fuego-suite submodule is not checked out (missing {}). \
             Run: git submodule update --init fuego-suite",
            cn_dir.display()
        );
    }

    let cn_sources = [
        "slow-hash.c",
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
        .files(cn_sources.iter().map(|f| cn_dir.join(f)))
        .include(&cn_dir)
        .include(&suite_src) // Common/int-util.h, Common/static_assert.h
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
