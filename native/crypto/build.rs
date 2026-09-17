use std::env;
use std::path::PathBuf;

fn main() {
    let cn_dir = PathBuf::from("src/cn");

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
        .include(cn_dir.parent().unwrap())  // for Common/ at src/Common
        .define("_GNU_SOURCE", None)
        .flag_if_supported("-std=gnu11")
        .flag_if_supported("-O2");

    // Only add -maes on x86_64
    let target = env::var("TARGET").unwrap_or_default();
    if target.contains("x86_64") {
        build.flag("-maes");
    }

    build.compile("cryptonight");
}
