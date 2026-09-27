#!/usr/bin/env python3
"""Keep the Rust SDK (rust-fuego-wallet) and the Dart wallet in step with fuego-suite.

fuego-suite is the source of truth for consensus parameters, tx-extra tags,
fuegod RPC routes (and whether each one is an HTTP endpoint or a /json_rpc
method), RPC request/response field names, and the walletd JSON-RPC messages
that fuego_walletd emulates.

  sync      extract the contract from a suite checkout, write
            tool/suite_contract.lock.json and regenerate
            rust-fuego-wallet/fuego-sdk/fuego-sdk/src/suite.rs
  generate  regenerate suite.rs from the committed lock (no suite checkout)
  check     verify suite.rs matches the lock, report suite changes since the
            lock (when --suite is given), and verify SDK / proxy / Dart code
            against the contract

Exit status is 1 when any error-level finding is reported.
"""
from __future__ import annotations

import argparse
import ast
import json
import re
import subprocess
import sys
from pathlib import Path

SCHEMA = 1
LOCK_REL = "tool/suite_contract.lock.json"
RUST_OUT_REL = "rust-fuego-wallet/fuego-sdk/fuego-sdk/src/suite.rs"

SUITE_FILES = {
    "config": "src/CryptoNoteConfig.h",
    "tx_extra": "src/CryptoNoteCore/TransactionExtra.h",
    "rpc_defs": "src/Rpc/CoreRpcServerCommandsDefinitions.h",
    "protocol_defs": "src/CryptoNoteProtocol/CryptoNoteProtocolDefinitions.h",
    "rpc_server": "src/Rpc/RpcServer.cpp",
    "currency": "src/CryptoNoteCore/Currency.cpp",
    "walletd_h": "src/PaymentGate/PaymentServiceJsonRpcMessages.h",
    "walletd_cpp": "src/PaymentGate/PaymentServiceJsonRpcMessages.cpp",
    "walletd_server": "src/PaymentGate/PaymentServiceJsonRpcServer.cpp",
}

# Parameters the SDK mirrors. A missing name is an error: a rename in the suite
# must be resolved here deliberately, never dropped silently.
PARAMETERS = [
    "COIN",
    "MINIMUM_FEE",
    "DEFAULT_DUST_THRESHOLD",
    "MIN_TX_MIXIN_SIZE_V2",
    "MIN_TX_MIXIN_SIZE_V10",
    "MAX_TX_MIXIN_SIZE",
    "CRYPTONOTE_MAX_BLOCK_NUMBER",
    "CRYPTONOTE_DEFAULT_TX_SPENDABLE_AGE",
    "CRYPTONOTE_MINED_MONEY_UNLOCK_WINDOW",
    "CRYPTONOTE_LOCKED_TX_ALLOWED_DELTA_BLOCKS",
    "CRYPTONOTE_LOCKED_TX_ALLOWED_DELTA_SECONDS",
    "CRYPTONOTE_PUBLIC_ADDRESS_BASE58_PREFIX",
    "CRYPTONOTE_PUBLIC_ADDRESS_BASE58_PREFIX_TESTNET",
    "EPOCH_DURATION_BLOCKS",
    "TESTNET_EPOCH_DURATION_BLOCKS",
    "DEPOSIT_MIN_TERM",
    "DEPOSIT_MAX_TERM",
    "TESTNET_DEPOSIT_MIN_TERM",
    "TESTNET_DEPOSIT_MAX_TERM",
    "HEAT_TERM",
    "DEPOSIT_TERM_LP",
    "DEPOSIT_TERM_POOL_XFG",
    "DEPOSIT_TERM_POOL_HEAT",
    "DEPOSIT_TERM_SWAP_RECEIVE_XFG",
    "DIGM_TERM",
    "HEAT_MINT_MIN_HEAT",
    "HEAT_MINT_PREMIUM_BPS",
    "HEARTH_FEE_BPS",
    "HEARTH_FEE_DIVISOR",
    "SWAP_FEE_RATE_BPS",
    "SWAP_FEE_RATE_DIVISOR",
    "ALIAS_REGISTRATION_FEE",
    "ALIAS_REGISTRATION_FEE_MAX_RANDOM",
    "UPGRADE_HEIGHT_V10",
    "UPGRADE_HEIGHT_V11",
    "UPGRADE_HEIGHT_V12",
    "FUEGO_DEV_FUND_ADDRESS",
]

# fuegod commands the SDK talks to through typed structs (suite.rs `fuegod`).
FUEGOD_STRUCTS = [
    "COMMAND_RPC_SEND_RAW_TX",
    "COMMAND_RPC_AMM_POOL_INFO",
    "COMMAND_RPC_ESTIMATE_CD_YIELD",
    "COMMAND_RPC_IS_KEY_IMAGE_SPENT",
    "COMMAND_RPC_GET_ALIAS",
]

# walletd JSON-RPC methods fuego_walletd serves with suite-shaped messages.
WALLETD_METHODS = [
    "getBalance",
    "getStatus",
    "getAddresses",
    "getTransactions",
    "sendTransaction",
    "createIntegrated",
]

# KV-binary (de)serializers in fuego-sdk/src/serialization.rs and the command
# whose struct tree must contain every field name they read or write.
BIN_SERIALIZERS = {
    "get_random_outs_request": "COMMAND_RPC_GET_RANDOM_OUTPUTS_FOR_AMOUNTS",
    "parse_get_random_outs_response": "COMMAND_RPC_GET_RANDOM_OUTPUTS_FOR_AMOUNTS",
    "get_random_commitment_outs_request": "COMMAND_RPC_GET_RANDOM_COMMITMENT_OUTPUTS",
    "parse_get_random_commitment_outs_response": "COMMAND_RPC_GET_RANDOM_COMMITMENT_OUTPUTS",
    "query_blocks_lite_request": "COMMAND_RPC_QUERY_BLOCKS_LITE",
    "parse_kv_query_blocks_lite_response": "COMMAND_RPC_QUERY_BLOCKS_LITE",
    "get_o_indexes_request": "COMMAND_RPC_GET_TX_GLOBAL_OUTPUTS_INDEXES",
    "parse_get_o_indexes_response": "COMMAND_RPC_GET_TX_GLOBAL_OUTPUTS_INDEXES",
}

# Dart models that mirror fuegod responses field for field.
DART_MODELS = {
    "lib/models/heat_amm.dart": {
        "HeatMetrics": "COMMAND_RPC_GET_HEAT_METRICS.response",
        "PoolInfo": "COMMAND_RPC_AMM_POOL_INFO.response",
        "AmmQuote": "COMMAND_RPC_AMM_QUOTE.response",
        "OrderBookState": "COMMAND_RPC_GET_ORDER_BOOK.response",
        "OrderBookLevel": "COMMAND_RPC_GET_ORDER_BOOK.response.OrderBookLevelJson",
    },
}

# Rust files whose daemon calls are validated against the route table.
RUST_DAEMON_CALLERS = [
    "rust-fuego-wallet/core/src/daemon.rs",
]
RUST_PROXY = "rust-fuego-wallet/core/src/server.rs"
PROXY_OWN_ROUTES = {"/json_rpc", "/health", "/status", "/scan_balance"}

RUST_KEYWORDS = {
    "as", "break", "const", "continue", "crate", "else", "enum", "extern", "false",
    "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut",
    "pub", "ref", "return", "self", "static", "struct", "super", "trait", "true",
    "type", "unsafe", "use", "where", "while", "async", "await", "dyn", "abstract",
    "become", "box", "do", "final", "macro", "override", "priv", "typeof",
    "unsized", "virtual", "yield", "try",
}


class SyncError(Exception):
    pass


# --------------------------------------------------------------------- lexing

def strip_comments(src: str) -> str:
    """Remove // and /* */ comments, keeping string/char literals and line count."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(src[i:j + 1])
            i = j + 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            end = n if j < 0 else j + 2
            out.append("\n" * src.count("\n", i, end))
            i = end
        else:
            out.append(c)
            i += 1
    return "".join(out)


def matching_brace(text: str, open_pos: int) -> int:
    depth = 0
    for k in range(open_pos, len(text)):
        if text[k] == "{":
            depth += 1
        elif text[k] == "}":
            depth -= 1
            if depth == 0:
                return k
    raise SyncError("unbalanced braces")


# ------------------------------------------------------- constant expressions

_INT_LIT = re.compile(r"\b(0[xX][0-9A-Fa-f]+|\d+)(?:[uU](?:ll|LL|l|L)?|(?:ll|LL|l|L)[uU]?)?\b")
_WIDTH = {"uint8_t": 8, "uint16_t": 16, "uint32_t": 32, "uint64_t": 64, "size_t": 64,
          "unsigned": 32, "unsigned int": 32}


def _lit(m: re.Match) -> str:
    s = m.group(1)
    if s.lower().startswith("0x"):
        return str(int(s, 16))
    if len(s) > 1 and s.startswith("0"):
        return str(int(s, 8))
    return s


def _to_python(expr: str) -> str:
    e = re.sub(r"\bUINT64_C\s*\(", "(", expr.strip())
    e = re.sub(r"static_cast\s*<\s*(\w+)\s*>\s*\(", lambda m: f"__cast_{m.group(1)}(", e)
    e = re.sub(r"\(\s*(uint8_t|uint16_t|uint32_t|uint64_t|size_t)\s*\)",
               lambda m: f"__cast_{m.group(1)}*", e)
    e = _INT_LIT.sub(_lit, e)
    e = re.sub(r"\btrue\b", "1", e)
    e = re.sub(r"\bfalse\b", "0", e)
    return e


def _mask(type_name: str, value: int) -> int:
    width = _WIDTH.get(type_name)
    return value & ((1 << width) - 1) if width else value


def eval_c_expr(expr: str, resolve) -> int:
    tree = ast.parse(_to_python(expr), mode="eval")

    def cast(name: str, v: int) -> int:
        return _mask(name[len("__cast_"):], v)

    def ev(node):
        if isinstance(node, ast.Expression):
            return ev(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, int):
            return node.value
        if isinstance(node, ast.Name):
            return resolve(node.id)
        if isinstance(node, ast.UnaryOp):
            v = ev(node.operand)
            if isinstance(node.op, ast.USub):
                return -v
            if isinstance(node.op, ast.UAdd):
                return v
            if isinstance(node.op, ast.Invert):
                return ~v
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) \
                and node.func.id.startswith("__cast_") and len(node.args) == 1:
            return cast(node.func.id, ev(node.args[0]))
        if isinstance(node, ast.BinOp):
            if isinstance(node.op, ast.Mult) and isinstance(node.left, ast.Name) \
                    and node.left.id.startswith("__cast_"):
                return cast(node.left.id, ev(node.right))
            a, b = ev(node.left), ev(node.right)
            op = node.op
            if isinstance(op, ast.Add):
                return a + b
            if isinstance(op, ast.Sub):
                return a - b
            if isinstance(op, ast.Mult):
                return a * b
            if isinstance(op, (ast.Div, ast.FloorDiv)):
                q = abs(a) // abs(b)
                return q if (a >= 0) == (b >= 0) else -q
            if isinstance(op, ast.Mod):
                return a - b * (abs(a) // abs(b) * (1 if (a >= 0) == (b >= 0) else -1))
            if isinstance(op, ast.LShift):
                return a << b
            if isinstance(op, ast.RShift):
                return a >> b
            if isinstance(op, ast.BitOr):
                return a | b
            if isinstance(op, ast.BitAnd):
                return a & b
            if isinstance(op, ast.BitXor):
                return a ^ b
        raise SyncError(f"unsupported constant expression: {expr!r}")

    return ev(tree)


def c_string(literal: str) -> str:
    return bytes(literal.strip()[1:-1], "utf-8").decode("unicode_escape")


# ------------------------------------------------------------------ extractors

_DECL = re.compile(
    r"\bconst(?:expr)?\s+(?P<type>(?:unsigned\s+)?[A-Za-z_][\w:]*)\s+(?P<name>[A-Za-z_]\w*)"
    r"\s*(?P<arr>\[\s*\d*\s*\])?\s*=\s*(?P<expr>[^;]+);")


def extract_parameters(config_src: str) -> dict:
    decls: dict[str, list[tuple[str, str]]] = {}
    for m in _DECL.finditer(strip_comments(config_src)):
        decls.setdefault(m.group("name"), []).append((m.group("type"), m.group("expr").strip()))

    cache: dict[str, int] = {}

    def resolve(name: str) -> int:
        if name in cache:
            return cache[name]
        if name not in decls:
            raise SyncError(f"unknown identifier in CryptoNoteConfig.h expression: {name}")
        ctype, expr = decls[name][0]
        cache[name] = _mask(ctype, eval_c_expr(expr, resolve))
        return cache[name]

    out = {}
    for name in PARAMETERS:
        if name not in decls:
            raise SyncError(f"parameter {name} not found in {SUITE_FILES['config']}")
        variants = {e for _, e in decls[name]}
        if len(variants) > 1:
            raise SyncError(f"parameter {name} has conflicting definitions: {sorted(variants)}")
        ctype, expr = decls[name][0]
        if expr.startswith('"'):
            out[name] = {"type": "string", "value": c_string(expr), "expr": expr}
        else:
            out[name] = {"type": ctype, "value": resolve(name), "expr": expr}
    return out


def extract_testnet_heights(currency_src: str) -> dict:
    src = strip_comments(currency_src)
    start = src.find("if (isTestnet())")
    if start < 0:
        raise SyncError("testnet upgrade-height block not found in Currency.cpp")
    block = src[start:matching_brace(src, src.index("{", start)) + 1]
    heights = {f"V{v}": int(h) for v, h in re.findall(r"m_upgradeHeightV(\d+)\s*=\s*(\d+)\s*;", block)}
    for v in ("V10", "V11", "V12"):
        if v not in heights:
            raise SyncError(f"testnet upgrade height {v} not found in Currency.cpp")
    return {k: heights[k] for k in sorted(heights, key=lambda s: int(s[1:]))}


def extract_tx_extra_tags(tx_extra_src: str) -> dict:
    tags = {}
    for name, val in re.findall(r"^\s*#define\s+(TX_EXTRA_\w+)\s+(0[xX][0-9A-Fa-f]+|\d+)\b",
                                strip_comments(tx_extra_src), re.M):
        tags[name] = int(val, 0)
    if not tags:
        raise SyncError("no TX_EXTRA_* tags found")
    return dict(sorted(tags.items()))


def extract_routes(server_src: str) -> dict:
    src = strip_comments(server_src)
    http = {}
    for path, kind, cmd in re.findall(
            r'\{\s*"(/[^"]+)"\s*,\s*\{\s*(binMethod|jsonMethod|jsonMethodSwapAuth)\s*<\s*(\w+)\s*>', src):
        http[path] = {"kind": {"binMethod": "binary", "jsonMethod": "json",
                               "jsonMethodSwapAuth": "json_swap_auth"}[kind], "command": cmd}
    if '"/json_rpc"' in src:
        http["/json_rpc"] = {"kind": "json_rpc", "command": None}
    start = src.find("jsonRpcHandlers = {")
    if start < 0:
        raise SyncError("jsonRpcHandlers table not found in RpcServer.cpp")
    table = src[start:matching_brace(src, src.index("{", start)) + 1]
    handler_cmd = dict(re.findall(r"bool\s+RpcServer::(\w+)\s*\(\s*const\s+(\w+)::request\s*&", src))
    json_rpc = {}
    for method, handler in re.findall(r'\{\s*"([\w:]+)"\s*,\s*\{\s*makeMemberMethod\(\s*&RpcServer::(\w+)\s*\)', table):
        json_rpc[method] = {"command": handler_cmd.get(handler)}
    if not http or not json_rpc:
        raise SyncError("route extraction produced an empty table")
    return {"http": dict(sorted(http.items())), "json_rpc": dict(sorted(json_rpc.items()))}


_TOKEN = re.compile(r"""
    (?P<struct>\bstruct\s+(?P<sname>\w+)\s*\{)
  | (?P<typedef>\btypedef\s+(?P<ttype>[^;{}]+?)\s+(?P<tname>\w+)\s*;)
  | (?P<kv>\bKV_MEMBER\s*\(\s*(?P<kvname>\w+)\s*\))
  | (?P<bin>\bserializeAsBinary\s*\(\s*(?P<binmember>\w+)\s*,\s*"(?P<binwire>\w+)")
  | (?P<ser>\b(?:s|serializer)\s*\(\s*(?P<sermember>\w+)\s*,\s*"(?P<serwire>\w+)"\s*\))
  | (?P<open>\{)
  | (?P<close>\})
  | (?P<decl>(?<=[;{}])\s*(?P<dtype>(?:unsigned\s+)?[A-Za-z_][\w:]*(?:\s*<[^;{}()]*>)?)
        \s+(?P<dname>[A-Za-z_]\w*)\s*(?:=[^;{}]*)?;)
""", re.X)


def parse_structs(src: str) -> tuple[dict, dict]:
    """Return ({path: {'members': {name: type}, 'wire': [(member, wire, binary)]}}, aliases)."""
    text = strip_comments(src)
    structs: dict[str, dict] = {}
    aliases: dict[str, str] = {}
    stack: list[tuple[str, str | None]] = []

    def current_struct():
        for kind, path in reversed(stack):
            if kind == "struct":
                return path
        return None

    for m in _TOKEN.finditer(text):
        if m.group("struct"):
            parent = current_struct()
            path = f"{parent}.{m.group('sname')}" if parent else m.group("sname")
            structs.setdefault(path, {"members": {}, "wire": []})
            stack.append(("struct", path))
        elif m.group("typedef"):
            parent = current_struct()
            name = f"{parent}.{m.group('tname')}" if parent else m.group("tname")
            aliases[name] = " ".join(m.group("ttype").split())
        elif m.group("open"):
            stack.append(("block", None))
        elif m.group("close"):
            if stack:
                stack.pop()
        else:
            owner = current_struct()
            if owner is None:
                continue
            if m.group("kv"):
                structs[owner]["wire"].append((m.group("kvname"), m.group("kvname"), False))
            elif m.group("bin"):
                structs[owner]["wire"].append((m.group("binmember"), m.group("binwire"), True))
            elif m.group("ser"):
                structs[owner]["wire"].append((m.group("sermember"), m.group("serwire"), False))
            elif m.group("decl") and stack and stack[-1][0] == "struct":
                dtype = " ".join(m.group("dtype").split())
                if dtype not in {"return", "typedef", "using", "throw", "delete", "goto"}:
                    structs[owner]["members"][m.group("dname")] = dtype
    return structs, aliases


def attach_out_of_line_serializers(structs: dict, cpp_src: str) -> None:
    text = strip_comments(cpp_src)
    for m in re.finditer(r"\bvoid\s+([\w:]+)::serialize\s*\([^)]*\)\s*\{", text):
        path = m.group(1).replace("::", ".")
        if path not in structs:
            continue
        body = text[m.end() - 1:matching_brace(text, m.end() - 1) + 1]
        for sm in re.finditer(r'\b(?:s|serializer)\s*\(\s*(\w+)\s*,\s*"(\w+)"\s*\)', body):
            structs[path]["wire"].append((sm.group(1), sm.group(2), False))


def resolve_type_name(type_name: str, from_path: str, structs: dict) -> str | None:
    parts = from_path.split(".")
    for k in range(len(parts), -1, -1):
        cand = ".".join(parts[:k] + [type_name])
        if cand in structs:
            return cand
    return None


def resolve_struct_path(path: str, structs: dict, aliases: dict) -> str | None:
    """Follow typedefs; returns a struct path, 'EMPTY' for EMPTY_STRUCT, or None."""
    seen = set()
    while path not in structs:
        if path in seen or path not in aliases:
            return None
        seen.add(path)
        target = aliases[path]
        if target == "EMPTY_STRUCT":
            return "EMPTY"
        parent = path.rsplit(".", 1)[0] if "." in path else ""
        resolved = resolve_type_name(target, parent, structs) if parent else (target if target in structs else None)
        if resolved is None:
            return None
        path = resolved
    return path


_TEMPLATE = re.compile(r"^(?:std::)?(vector|list|set|deque)\s*<\s*(.+)\s*>$")


def collect_struct(path: str, structs: dict, out: dict) -> None:
    """Serialize a struct (and every struct it references) into `out`."""
    if path in out:
        return
    s = structs[path]
    fields = []
    out[path] = fields
    for member, wire, binary in s["wire"]:
        ctype = s["members"].get(member, "?")
        ref = None
        base = ctype
        tm = _TEMPLATE.match(ctype)
        if tm:
            base = tm.group(2).strip()
        target = resolve_type_name(base, path, structs)
        if target:
            ref = target
            collect_struct(target, structs, out)
        fields.append({"wire": wire, "type": ctype, "binary": binary, **({"ref": ref} if ref else {})})


def extract_commands(defs_src: str, protocol_src: str, routes: dict) -> dict:
    structs, aliases = parse_structs(defs_src)
    proto_structs, proto_aliases = parse_structs(protocol_src)
    for k, v in proto_structs.items():
        structs.setdefault(k, v)
    for k, v in proto_aliases.items():
        aliases.setdefault(k, v)
    commands = set(FUEGOD_STRUCTS) | set(BIN_SERIALIZERS.values())
    commands |= {r["command"] for r in routes["http"].values() if r["command"]}
    commands |= {r["command"] for r in routes["json_rpc"].values() if r["command"]}
    for model in DART_MODELS.values():
        commands |= {p.split(".")[0] for p in model.values()}
    out: dict = {}
    for cmd in sorted(commands):
        for part in ("request", "response"):
            p = resolve_struct_path(f"{cmd}.{part}", structs, aliases)
            if p == "EMPTY":
                out[f"{cmd}.{part}"] = []
            elif p is None:
                if cmd in FUEGOD_STRUCTS:
                    raise SyncError(f"{cmd}.{part} not found in {SUITE_FILES['rpc_defs']}")
            else:
                collect_struct(p, structs, out)
                if p != f"{cmd}.{part}":
                    out[f"{cmd}.{part}"] = [{"wire": "*", "type": "alias", "binary": False, "ref": p}]
    return dict(sorted(out.items()))


def extract_walletd(h_src: str, cpp_src: str, server_src: str) -> dict:
    structs, _aliases = parse_structs(h_src)
    attach_out_of_line_serializers(structs, cpp_src)
    methods = {}
    for method, req, resp in re.findall(
            r'handlers\.emplace\(\s*"(\w+)"\s*,\s*jsonHandler\s*<\s*([\w:]+)\s*,\s*([\w:]+)\s*>',
            strip_comments(server_src)):
        methods[method] = {"request": req.replace("::", "."), "response": resp.replace("::", ".")}
    out_structs: dict = {}
    selected = {}
    for method in WALLETD_METHODS:
        if method not in methods:
            raise SyncError(f"walletd method {method} not registered in PaymentServiceJsonRpcServer.cpp")
        selected[method] = methods[method]
        for part in ("request", "response"):
            path = methods[method][part]
            if path not in structs:
                raise SyncError(f"walletd message {path} not found")
            collect_struct(path, structs, out_structs)
    return {"methods": selected, "structs": dict(sorted(out_structs.items()))}


def suite_commit(suite: Path) -> str:
    try:
        return subprocess.check_output(["git", "-C", str(suite), "rev-parse", "HEAD"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def extract_contract(suite: Path) -> dict:
    read = {k: (suite / v).read_text(encoding="utf-8", errors="replace") for k, v in SUITE_FILES.items()}
    routes = extract_routes(read["rpc_server"])
    return {
        "schema": SCHEMA,
        "suite_commit": suite_commit(suite),
        "parameters": extract_parameters(read["config"]),
        "testnet_upgrade_heights": extract_testnet_heights(read["currency"]),
        "tx_extra_tags": extract_tx_extra_tags(read["tx_extra"]),
        "rpc": routes,
        "structs": extract_commands(read["rpc_defs"], read["protocol_defs"], routes),
        "walletd": extract_walletd(read["walletd_h"], read["walletd_cpp"], read["walletd_server"]),
    }


# ------------------------------------------------------------------ generation

_RUST_PARAM_TYPE = {"uint64_t": "u64", "size_t": "u64", "uint32_t": "u32", "uint16_t": "u16",
                    "uint8_t": "u8", "int": "i32", "int32_t": "i32", "int64_t": "i64", "string": "&str"}
_RUST_SCALAR = {"uint64_t": "u64", "size_t": "u64", "uint32_t": "u32", "uint16_t": "u16",
                "uint8_t": "u8", "int64_t": "i64", "int32_t": "i32", "int": "i32", "int16_t": "i16",
                "int8_t": "i8", "bool": "bool", "double": "f64", "float": "f32",
                "std::string": "String", "string": "String"}
_RUST_HEX = {"Crypto::Hash", "Crypto::PublicKey", "Crypto::SecretKey", "Crypto::KeyImage",
             "Crypto::Signature", "Hash", "PublicKey", "SecretKey", "KeyImage", "Signature",
             "BinaryArray", "CryptoNote::BinaryArray"}


def camel(path: str) -> str:
    name = path.replace("COMMAND_RPC_", "", 1) if path.startswith("COMMAND_RPC_") else path
    parts = [p for p in re.split(r"[._]", name) if p]
    return "".join(p.capitalize() if p.upper() == p else p[0].upper() + p[1:] for p in parts)


def snake(wire: str) -> str:
    s = re.sub(r"(?<=[a-z0-9])([A-Z])", r"_\1", wire).lower()
    return f"r#{s}" if s in RUST_KEYWORDS else s


def rust_field_type(field: dict, owner: str) -> str:
    ctype = field["type"]
    tm = _TEMPLATE.match(ctype)
    inner = tm.group(2).strip() if tm else ctype
    if field.get("ref"):
        base = camel(field["ref"])
    elif inner in _RUST_SCALAR:
        base = _RUST_SCALAR[inner]
    elif inner in _RUST_HEX:
        base = "String"
    else:
        raise SyncError(f"no Rust mapping for C++ type {ctype!r} ({owner}.{field['wire']}); "
                        f"extend _RUST_SCALAR/_RUST_HEX deliberately")
    return f"Vec<{base}>" if tm else base


def rust_struct(path: str, fields: list, doc: str) -> str:
    lines = [f"    /// {doc}",
             "    #[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]",
             "    #[serde(default)]",
             f"    pub struct {camel(path)} {{"]
    for f in fields:
        lines.append(f'        #[serde(rename = "{f["wire"]}")]')
        lines.append(f"        pub {snake(f['wire'])}: {rust_field_type(f, path)},")
    lines.append("    }")
    return "\n".join(lines)


def struct_closure(roots: list[str], structs: dict) -> list[str]:
    order: list[str] = []

    def visit(p: str):
        if p in order:
            return
        order.append(p)
        for f in structs.get(p, []):
            if f.get("ref"):
                visit(f["ref"])

    for r in roots:
        visit(r)
    return order


def generate_rust(contract: dict) -> str:
    out = [
        f"//! Generated by tool/check_suite_sync.py from fuego-suite {contract['suite_commit']}.",
        "//! Do not edit by hand: run `python3 tool/check_suite_sync.py sync --suite <fuego-suite>`.",
        "#![allow(dead_code, clippy::all)]",
        "",
        f'pub const SUITE_COMMIT: &str = "{contract["suite_commit"]}";',
        "",
    ]
    for name, p in contract["parameters"].items():
        rtype = _RUST_PARAM_TYPE.get(p["type"])
        if rtype is None:
            raise SyncError(f"no Rust type for parameter {name} ({p['type']})")
        out.append(f"/// CryptoNoteConfig.h: `{p['expr']}`")
        value = json.dumps(p["value"]) if rtype == "&str" else str(p["value"])
        out.append(f"pub const {name}: {rtype} = {value};")
    out.append("")
    for v, h in contract["testnet_upgrade_heights"].items():
        out.append(f"/// Currency.cpp testnet m_upgradeHeight{v}")
        out.append(f"pub const TESTNET_UPGRADE_HEIGHT_{v}: u32 = {h};")
    out += ["", "/// TransactionExtra.h tags.", "pub mod tx_extra {"]
    for name, v in contract["tx_extra_tags"].items():
        out.append(f"    pub const {name}: u8 = 0x{v:02X};")
    out += ["}", "", "/// fuegod routes (RpcServer.cpp): HTTP endpoints and /json_rpc methods.", "pub mod rpc {",
            "    #[derive(Debug, Clone, Copy, PartialEq, Eq)]",
            "    pub enum Transport {",
            "        /// KV-binary body (`binMethod`).",
            "        Binary,",
            "        /// JSON body, JSON response (`jsonMethod`).",
            "        Json,",
            "        /// JSON body gated by the swap auth token (`jsonMethodSwapAuth`).",
            "        JsonSwapAuth,",
            "        /// The JSON-RPC 2.0 dispatcher itself.",
            "        JsonRpc,",
            "    }", "",
            "    pub const HTTP_ROUTES: &[(&str, Transport)] = &["]
    kinds = {"binary": "Binary", "json": "Json", "json_swap_auth": "JsonSwapAuth", "json_rpc": "JsonRpc"}
    for path, r in contract["rpc"]["http"].items():
        out.append(f'        ("{path}", Transport::{kinds[r["kind"]]}),')
    out += ["    ];", "", "    pub const JSON_RPC_METHODS: &[&str] = &["]
    for m in contract["rpc"]["json_rpc"]:
        out.append(f'        "{m}",')
    out += ["    ];", "",
            "    pub fn http_route(path: &str) -> Option<Transport> {",
            "        HTTP_ROUTES.iter().find(|(p, _)| *p == path).map(|(_, t)| *t)",
            "    }", "",
            "    pub fn is_json_rpc_method(method: &str) -> bool {",
            "        JSON_RPC_METHODS.contains(&method)",
            "    }",
            "}", ""]

    structs = contract["structs"]
    roots = []
    for cmd in FUEGOD_STRUCTS:
        for part in ("request", "response"):
            key = f"{cmd}.{part}"
            if key in structs and not (structs[key] and structs[key][0]["wire"] == "*"):
                roots.append(key)
    out += ["/// fuegod request/response structs (CoreRpcServerCommandsDefinitions.h).",
            "pub mod fuegod {", "    use serde::{Deserialize, Serialize};", ""]
    for p in struct_closure(roots, structs):
        out.append(rust_struct(p, structs[p], p.replace(".", "::")))
        out.append("")
    out.append("}")
    out.append("")

    wd = contract["walletd"]
    wroots = [m[part] for m in wd["methods"].values() for part in ("request", "response")]
    out += ["/// walletd JSON-RPC messages (PaymentServiceJsonRpcMessages).",
            "pub mod walletd {", "    use serde::{Deserialize, Serialize};", ""]
    for method, m in wd["methods"].items():
        out.append(f'    pub const {snake(method).upper()}: &str = "{method}";')
    out.append("")
    for p in struct_closure(wroots, wd["structs"]):
        out.append(rust_struct(p, wd["structs"][p], p.replace(".", "::")))
        out.append("")
    out.append("}")
    return "\n".join(out).rstrip() + "\n"


# ---------------------------------------------------------------------- checks

class Report:
    def __init__(self):
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.notes: list[str] = []

    def markdown(self) -> str:
        parts = ["# Suite sync report", ""]
        for title, items in (("Errors", self.errors), ("Warnings", self.warnings), ("Changes", self.notes)):
            if items:
                parts.append(f"## {title}")
                parts += [f"- {i}" for i in items]
                parts.append("")
        if not (self.errors or self.warnings or self.notes):
            parts.append("No drift: SDK, proxy and Dart models match the suite contract.")
        return "\n".join(parts) + "\n"


def all_wires(struct_path: str, structs: dict, seen=None) -> set[str]:
    seen = seen or set()
    if struct_path in seen or struct_path not in structs:
        return set()
    seen.add(struct_path)
    names = set()
    for f in structs[struct_path]:
        if f["wire"] != "*":
            names.add(f["wire"])
        if f.get("ref"):
            names |= all_wires(f["ref"], structs, seen)
    return names


def diff_contracts(old: dict, new: dict, rep: Report) -> None:
    for name in PARAMETERS:
        o, n = old["parameters"].get(name, {}), new["parameters"].get(name, {})
        if o.get("value") != n.get("value"):
            rep.notes.append(f"parameter `{name}`: {o.get('value')!r} -> {n.get('value')!r}")
    for key in ("testnet_upgrade_heights", "tx_extra_tags"):
        o, n = old.get(key, {}), new.get(key, {})
        for k in sorted(set(o) | set(n)):
            if o.get(k) != n.get(k):
                rep.notes.append(f"{key} `{k}`: {o.get(k)!r} -> {n.get(k)!r}")
    for table in ("http", "json_rpc"):
        o, n = old["rpc"][table], new["rpc"][table]
        for k in sorted(set(o) | set(n)):
            if k not in n:
                rep.notes.append(f"route removed ({table}): `{k}`")
            elif k not in o:
                rep.notes.append(f"route added ({table}): `{k}`")
            elif o[k] != n[k]:
                rep.notes.append(f"route changed ({table}) `{k}`: {o[k]} -> {n[k]}")
    for sect in ("structs",):
        o, n = old[sect], new[sect]
        for k in sorted(set(o) | set(n)):
            ow = [f["wire"] for f in o.get(k, [])]
            nw = [f["wire"] for f in n.get(k, [])]
            if ow != nw or o.get(k) != n.get(k):
                rep.notes.append(f"struct `{k}` fields: {ow} -> {nw}")
    o, n = old["walletd"]["structs"], new["walletd"]["structs"]
    for k in sorted(set(o) | set(n)):
        if o.get(k) != n.get(k):
            rep.notes.append(f"walletd `{k}` fields: {[f['wire'] for f in o.get(k, [])]} -> "
                             f"{[f['wire'] for f in n.get(k, [])]}")


def rust_fn_bodies(src: str) -> dict[str, str]:
    bodies = {}
    for m in re.finditer(r"\bfn\s+(\w+)\s*(?:<[^>{]*>)?\s*\(", src):
        depth, k = 1, m.end()
        while k < len(src) and depth:
            depth += {"(": 1, ")": -1}.get(src[k], 0)
            k += 1
        brace = src.find("{", k)
        semi = src.find(";", k)
        if brace < 0 or 0 <= semi < brace:
            continue
        try:
            bodies[m.group(1)] = src[brace:matching_brace(src, brace) + 1]
        except SyncError:
            continue
    return bodies


def check_rust_usage(valise: Path, contract: dict, rep: Report) -> None:
    http = contract["rpc"]["http"]
    json_rpc = contract["rpc"]["json_rpc"]
    call_patterns = [
        (re.compile(r'json_rpc(?:::<[^>]*>)?\(\s*"([\w:]+)"'), "json_rpc"),
        (re.compile(r'post_bin\(\s*"(/[^"]+)"'), "binary"),
        (re.compile(r'(?:post_json|get_json)(?:::<[^>]*>)?\(\s*"(/[^"]+)"'), "json"),
    ]
    for rel in RUST_DAEMON_CALLERS:
        src = (valise / rel).read_text(encoding="utf-8")
        for pattern, transport in call_patterns:
            for m in pattern.finditer(src):
                name = m.group(1)
                line = src.count("\n", 0, m.start()) + 1
                if transport == "json_rpc":
                    if name not in json_rpc:
                        where = " (it is an HTTP endpoint)" if f"/{name}" in http else ""
                        rep.errors.append(f"{rel}:{line} calls JSON-RPC method `{name}` which fuegod "
                                          f"does not register{where}")
                elif name not in http:
                    rep.errors.append(f"{rel}:{line} calls `{name}` which fuegod does not serve")
                elif transport == "binary" and http[name]["kind"] != "binary":
                    rep.errors.append(f"{rel}:{line} posts KV-binary to `{name}`, a {http[name]['kind']} endpoint")
                elif transport == "json" and http[name]["kind"] not in ("json", "json_swap_auth"):
                    rep.errors.append(f"{rel}:{line} posts JSON to `{name}`, a {http[name]['kind']} endpoint")

    proxy = (valise / RUST_PROXY).read_text(encoding="utf-8")
    for m in re.finditer(r'\.route\(\s*"(/[^"]+)"\s*,\s*(?:get|post)\((fuegod_get|fuegod_post)\)', proxy):
        path = m.group(1)
        if path not in PROXY_OWN_ROUTES and path not in http:
            line = proxy.count("\n", 0, m.start()) + 1
            rep.errors.append(f"{RUST_PROXY}:{line} forwards `{path}` which fuegod does not serve")

    ser_rel = "rust-fuego-wallet/fuego-sdk/fuego-sdk/src/serialization.rs"
    bodies = rust_fn_bodies((valise / ser_rel).read_text(encoding="utf-8"))
    for fn, cmd in BIN_SERIALIZERS.items():
        if fn not in bodies:
            rep.errors.append(f"{ser_rel}: serializer `{fn}` not found")
            continue
        wires = all_wires(f"{cmd}.request", contract["structs"]) | all_wires(f"{cmd}.response", contract["structs"])
        body = bodies[fn]
        for name in re.findall(r'write_kv_name\(\s*b"(\w+)"', body):
            if name not in wires:
                rep.errors.append(f"{ser_rel}: `{fn}` writes field `{name}` not in {cmd}")
        for names in re.findall(r'kv_\w+\(\s*[\w&]+\s*,\s*&\[([^\]]*)\]', body):
            cands = re.findall(r'"(\w+)"', names)
            if cands and not any(c in wires for c in cands):
                rep.errors.append(f"{ser_rel}: `{fn}` reads {cands}, none of which is in {cmd}")


def dart_from_json_fields(src: str, cls: str) -> set[str] | None:
    m = re.search(rf"factory\s+{cls}\.fromJson\s*\([^)]*\)\s*\{{", src)
    if not m:
        return None
    body = src[m.end() - 1:matching_brace(src, m.end() - 1) + 1]
    return set(re.findall(r"json\[\s*'(\w+)'\s*\]", body))


def check_dart(valise: Path, contract: dict, rep: Report) -> None:
    structs = contract["structs"]
    for rel, classes in DART_MODELS.items():
        src = (valise / rel).read_text(encoding="utf-8")
        for cls, path in classes.items():
            fields = dart_from_json_fields(src, cls)
            if fields is None:
                rep.errors.append(f"{rel}: `{cls}.fromJson` not found")
                continue
            if path not in structs:
                rep.errors.append(f"{rel}: `{cls}` maps to `{path}`, which the suite no longer defines")
                continue
            suite_fields = {f["wire"] for f in structs[path]}
            for f in sorted(fields - suite_fields):
                rep.errors.append(f"{rel}: `{cls}` reads `{f}`, which `{path}` does not send")
            for f in sorted(suite_fields - fields - {"status"}):
                rep.warnings.append(f"{rel}: `{cls}` ignores suite field `{f}` of `{path}`")


def load_lock(valise: Path) -> dict:
    path = valise / LOCK_REL
    if not path.exists():
        raise SyncError(f"{LOCK_REL} missing: run `sync --suite <fuego-suite>` first")
    return json.loads(path.read_text(encoding="utf-8"))


def write_outputs(valise: Path, contract: dict) -> None:
    (valise / LOCK_REL).write_text(json.dumps(contract, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    (valise / RUST_OUT_REL).write_text(generate_rust(contract), encoding="utf-8")


def cmd_sync(args) -> int:
    valise, suite = Path(args.valise), Path(args.suite)
    contract = extract_contract(suite)
    rep = Report()
    lock_path = valise / LOCK_REL
    if lock_path.exists():
        old = json.loads(lock_path.read_text(encoding="utf-8"))
        diff_contracts(old, contract, rep)
        strip = lambda c: {k: v for k, v in c.items() if k != "suite_commit"}
        if strip(old) == strip(contract):
            # Suite moved without touching anything valise depends on: keep
            # the pinned commit so unrelated suite commits open no PRs.
            print(f"contract unchanged at suite {contract['suite_commit'][:12]}; lock kept")
            return finish(rep, args)
    write_outputs(valise, contract)
    return finish(rep, args)


def cmd_generate(args) -> int:
    valise = Path(args.valise)
    (valise / RUST_OUT_REL).write_text(generate_rust(load_lock(valise)), encoding="utf-8")
    return 0


def cmd_check(args) -> int:
    valise = Path(args.valise)
    rep = Report()
    lock = load_lock(valise)
    generated = valise / RUST_OUT_REL
    if not generated.exists() or generated.read_text(encoding="utf-8") != generate_rust(lock):
        rep.errors.append(f"{RUST_OUT_REL} is stale relative to {LOCK_REL}: run `generate`")
    contract = lock
    if args.suite:
        fresh = extract_contract(Path(args.suite))
        diff_contracts(lock, fresh, rep)
        if rep.notes:
            rep.warnings.append(f"suite {fresh['suite_commit'][:12]} differs from lock "
                                f"{lock['suite_commit'][:12]}: run `sync` and review")
        contract = fresh
    check_rust_usage(valise, contract, rep)
    check_dart(valise, contract, rep)
    return finish(rep, args)


def finish(rep: Report, args) -> int:
    text = rep.markdown()
    print(text, end="")
    if getattr(args, "report", None):
        Path(args.report).write_text(text, encoding="utf-8")
    return 1 if rep.errors else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("sync", "generate", "check"):
        p = sub.add_parser(name)
        p.add_argument("--valise", default=str(Path(__file__).resolve().parent.parent))
        p.add_argument("--report")
        if name != "generate":
            p.add_argument("--suite", required=(name == "sync"))
    args = ap.parse_args()
    try:
        return {"sync": cmd_sync, "generate": cmd_generate, "check": cmd_check}[args.cmd](args)
    except SyncError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
