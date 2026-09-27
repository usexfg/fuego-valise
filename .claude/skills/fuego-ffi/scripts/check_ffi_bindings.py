#!/usr/bin/env python3
"""Cross-check fuego-ffi's Rust C exports against the Dart bindings.

Checks, per symbol Dart looks up:
  - the symbol is exported by fuego-ffi (#[no_mangle] pub extern "C")
  - argument count matches
  - each argument and the return type have the same C width and signedness
And for every #[repr(C)] struct Dart mirrors: field order and field types.

Usage: check_ffi_bindings.py [--root REPO] [--strict] [--unused]
Exit 1 on any error (missing symbol, arity, width/struct mismatch).
--strict also fails on signedness-only mismatches (same width, e.g. u32 vs Int32).
"""
import argparse
import os
import re
import subprocess
import sys

RUST = "rust-fuego-wallet/fuego-sdk/fuego-ffi/src/lib.rs"
DART = "lib/ffi/fuego_native.dart"

# C-level type: (kind, width_bits, signed). Pointers compare by pointee.
RUST_SCALARS = {
    "u8": ("int", 8, False), "i8": ("int", 8, True),
    "u16": ("int", 16, False), "i16": ("int", 16, True),
    "u32": ("int", 32, False), "i32": ("int", 32, True), "c_int": ("int", 32, True),
    "c_uint": ("int", 32, False),
    "u64": ("int", 64, False), "i64": ("int", 64, True),
    "usize": ("int", "ptr", False), "isize": ("int", "ptr", True),
    "bool": ("bool", 8, False), "()": ("void", 0, False),
    "f32": ("float", 32, True), "f64": ("float", 64, True),
    "c_char": ("char", 8, None), "c_void": ("void", 0, False),
}
DART_SCALARS = {
    "Uint8": ("int", 8, False), "Int8": ("int", 8, True),
    "Uint16": ("int", 16, False), "Int16": ("int", 16, True),
    "Uint32": ("int", 32, False), "Int32": ("int", 32, True),
    "Uint64": ("int", 64, False), "Int64": ("int", 64, True),
    "Size": ("int", "ptr", False), "UintPtr": ("int", "ptr", False),
    "IntPtr": ("int", "ptr", True), "Bool": ("bool", 8, False), "Void": ("void", 0, False),
    "Float": ("float", 32, True), "Double": ("float", 64, True),
    "Char": ("char", 8, None), "Utf8": ("char", 8, None),
}


def repo_root(arg):
    if arg:
        return arg
    try:
        return subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
    except Exception:
        return os.getcwd()


def split_top(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "<(":
            depth += 1
        elif ch in ">)":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return [x.strip() for x in out if x.strip()]


def rust_type(t, structs):
    t = " ".join(t.split())
    m = re.fullmatch(r"\*\s*(?:const|mut)\s+(.+)", t)
    if m:
        return ("ptr", rust_type(m.group(1), structs))
    if t in RUST_SCALARS:
        return RUST_SCALARS[t]
    if t in structs:
        return ("struct", t)
    return ("unknown", t)


def dart_type(t, structs):
    t = " ".join(t.split())
    m = re.fullmatch(r"Pointer<(.+)>", t)
    if m:
        return ("ptr", dart_type(m.group(1), structs))
    if t in DART_SCALARS:
        return DART_SCALARS[t]
    if t in structs:
        return ("struct", t)
    return ("unknown", t)


def compare(r, d):
    """Return None if compatible, ('warn', msg) or ('error', msg)."""
    if r[0] == "ptr" and d[0] == "ptr":
        # void* on either side is opaque and matches any pointer.
        if r[1][0] == "void" or d[1][0] == "void":
            return None
        return compare(r[1], d[1])
    if r[0] != d[0]:
        return ("error", "kind")
    if r[0] == "struct":
        return None if r[1] == d[1] else ("error", "struct")
    if r[0] in ("void", "char", "unknown"):
        return None if r == d or r[0] == "char" else ("error", "type")
    if r[1] != d[1]:
        return ("error", "width")
    if r[2] != d[2]:
        return ("warn", "signedness")
    return None


def fmt(t):
    if t[0] == "ptr":
        return "*" + fmt(t[1])
    if t[0] in ("struct", "unknown"):
        return t[1]
    if t[0] == "int":
        w = "size" if t[1] == "ptr" else t[1]
        return ("i" if t[2] else "u") + str(w)
    return t[0]


def parse_rust(src):
    structs = {}
    for m in re.finditer(r"#\[repr\(C\)\]\s*pub\s+struct\s+(\w+)\s*\{(.*?)\}", src, re.S):
        fields = []
        for f in split_top(re.sub(r"//[^\n]*", "", m.group(2))):
            name, _, ty = f.partition(":")
            fields.append((name.replace("pub", "").strip(), ty.strip()))
        structs[m.group(1)] = fields
    fns = {}
    pat = r'#\[no_mangle\]\s*pub\s+(?:unsafe\s+)?extern\s+"C"\s+fn\s+(\w+)\s*\((.*?)\)\s*(?:->\s*([^{]+?))?\s*\{'
    for m in re.finditer(pat, src, re.S):
        args = [a.partition(":")[2].strip() for a in split_top(re.sub(r"//[^\n]*", "", m.group(2)))]
        fns[m.group(1)] = (args, (m.group(3) or "()").strip())
    return fns, structs


def parse_dart(src):
    looks = {}
    for m in re.finditer(r"lookupFunction<\s*(\w+)\s*,\s*\w+\s*>\(\s*'(\w+)'", src, re.S):
        looks.setdefault(m.group(2), set()).add(m.group(1))
    for m in re.finditer(r"lookup<\s*NativeFunction<\s*(\w+)\s*>\s*>\(\s*'(\w+)'", src, re.S):
        looks.setdefault(m.group(2), set()).add(m.group(1))
    typedefs = {}
    for m in re.finditer(r"typedef\s+(\w+)\s*=\s*(.+?)\s+Function\s*\((.*?)\)\s*;", src, re.S):
        args = []
        for a in split_top(m.group(3)):
            toks = a.split()
            # drop a trailing parameter name: "Pointer<Uint8> blob" -> "Pointer<Uint8>"
            args.append(" ".join(toks[:-1]) if len(toks) > 1 and re.fullmatch(r"\w+", toks[-1]) else a)
        typedefs[m.group(1)] = (args, m.group(2).strip())
    structs = {}
    for m in re.finditer(r"class\s+(\w+)\s+extends\s+Struct\s*\{(.*?)\n\}", src, re.S):
        fields = []
        for fm in re.finditer(r"(?:@(\w+)\(\)\s*)?external\s+([\w<>]+)\s+(\w+)\s*;", m.group(2)):
            ann, ty, name = fm.groups()
            fields.append((name, ann or ty))
        structs[m.group(1)] = fields
    return looks, typedefs, structs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root")
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--unused", action="store_true", help="list exports Dart never looks up")
    a = ap.parse_args()
    root = repo_root(a.root)
    rsrc = open(os.path.join(root, RUST)).read()
    dsrc = open(os.path.join(root, DART)).read()
    fns, rstructs = parse_rust(rsrc)
    looks, typedefs, dstructs = parse_dart(dsrc)

    errors, warns = [], []

    def check(where, r, d):
        res = compare(r, d)
        if res:
            msg = f"{where}: rust {fmt(r)} vs dart {fmt(d)} ({res[1]})"
            (errors if res[0] == "error" else warns).append(msg)

    for sym, natives in sorted(looks.items()):
        if sym not in fns:
            errors.append(f"{sym}: looked up by Dart but not exported by fuego-ffi")
            continue
        rargs, rret = fns[sym]
        for native in sorted(natives):
            if native not in typedefs:
                errors.append(f"{sym}: typedef {native} not found")
                continue
            dargs, dret = typedefs[native]
            if len(rargs) != len(dargs):
                errors.append(f"{sym}: rust takes {len(rargs)} args, {native} declares {len(dargs)}")
                continue
            for i, (ra, da) in enumerate(zip(rargs, dargs)):
                check(f"{sym} arg{i}", rust_type(ra, rstructs), dart_type(da, dstructs))
            check(f"{sym} return", rust_type(rret, rstructs), dart_type(dret, dstructs))

    for name, dfields in sorted(dstructs.items()):
        if name not in rstructs:
            errors.append(f"struct {name}: Dart Struct has no #[repr(C)] Rust counterpart")
            continue
        rfields = rstructs[name]
        if [f[0] for f in rfields] != [f[0] for f in dfields]:
            errors.append(f"struct {name}: field order/names differ: rust {[f[0] for f in rfields]} vs dart {[f[0] for f in dfields]}")
            continue
        for (fname, rt), (_, dt) in zip(rfields, dfields):
            check(f"struct {name}.{fname}", rust_type(rt, rstructs), dart_type(dt, dstructs))

    for e in errors:
        print("ERROR  " + e)
    for w in warns:
        print("WARN   " + w)
    if a.unused:
        for sym in sorted(set(fns) - set(looks)):
            print("UNUSED " + sym)
    print(f"{len(looks)} Dart lookups, {len(fns)} Rust exports, {len(errors)} errors, {len(warns)} warnings")
    sys.exit(1 if errors or (a.strict and warns) else 0)


if __name__ == "__main__":
    main()
