#!/usr/bin/env python3
"""
check_suite_sync.py — Detect drift between fuego-suite C++ RPC structs
and fuego-valise Dart JSON field reads.

Parses KV_MEMBER / KV_MEMBER_RENAME macros from suite C++ headers and
compares them against json['field'] patterns in valise Dart sources.

Exit code 0 = in sync, 1 = drift found.

Usage:
  python3 tool/check_suite_sync.py --suite /path/to/fuego-suite
"""

import re
import sys
import argparse
from pathlib import Path

# --- C++ header → struct map sources ---
SUITE_HEADERS = [
    "src/Rpc/CoreRpcServerCommandsDefinitions.h",
    "src/PaymentGate/PaymentServiceJsonRpcMessages.h",
]

# Structs to track (C++ struct name → label for error messages)
TRACKED_STRUCTS: dict[str, dict] = {
    # walletd JSON-RPC
    "GetBalance::Response": {
        "label": "walletd getBalance response",
        "dart_file": "lib/core/daemon_client.dart",
        "dart_method": "getBalanceDetailed",
        "required_fields": [
            "availableBalance",
            "lockedAmount",
            "lockedDepositBalance",
            "unlockedDepositBalance",
            "lockedHeatBalance",
            "unlockedHeatBalance",
        ],
    },
    "SendTransaction::Request": {
        "label": "walletd sendTransaction request",
        "dart_file": "lib/core/daemon_client.dart",
        "dart_method": "sendTransaction",
        "required_fields": ["transfers"],
        "forbidden_fields": ["destinations"],
    },
    "GetTransactions::Response": {
        "label": "walletd getTransactions response",
        "dart_file": "lib/services/fuego_rpc_service.dart",
        "dart_method": "getTransactions",
        "required_fields": ["items"],
        "forbidden_fields": ["transfers"],
    },
    # Daemon HTTP endpoints
    "COMMAND_RPC_GET_HEAT_METRICS::response": {
        "label": "fuegod heat_metrics response",
        "dart_file": "lib/models/heat_amm.dart",
        "dart_class": "HeatMetrics",
        "required_fields": [
            "heat_supply",
            "heat_on_deposit",
            "burned_xfg",
            "total_burned_xfg",
            "redemption_price_num",
            "redemption_price_denom",
            "treasury_balance",
            "swf_burned_xfg_pending_heat",
            "epoch_swap_fees",
            "vault_heat_cd_fee_pool",
            "vault_heat_lp_reserve",
            "vault_heat_general",
            "vault_heat_swf",
            "vault_xfg_cd_fee_pool",
            "vault_xfg_lp_reserve",
            "vault_xfg_general",
        ],
        "forbidden_fields": ["swf_heat_balance"],
    },
    "COMMAND_RPC_AMM_POOL_INFO::response": {
        "label": "fuegod amm_pool_info response",
        "dart_file": "lib/models/heat_amm.dart",
        "dart_class": "PoolInfo",
        "required_fields": [
            "reserve_xfg",
            "reserve_heat",
            "total_lp_shares",
            "spot_price",
            "epoch_swap_fees",
            "hearth_twap",
            "height",
        ],
    },
    "COMMAND_RPC_AMM_QUOTE::response": {
        "label": "fuegod amm_quote response",
        "dart_file": "lib/models/heat_amm.dart",
        "dart_class": "AmmQuote",
        "required_fields": [
            "expected_output",
            "price_impact_bps",
            "fee",
        ],
    },
}

# --- Regex patterns ---
# Matches: KV_MEMBER(fieldName) or KV_MEMBER_RENAME(fieldName, "json_key")
_KV_MEMBER = re.compile(r'KV_MEMBER(?:_RENAME)?\s*\(\s*(\w+)\s*(?:,\s*"([^"]+)")?\s*\)')
# Dart json field read: json['key'] or json["key"]
_DART_JSON_FIELD = re.compile(r"""json\[['"]([^'"]+)['"]\]""")
# Dart map field write: 'key': value
_DART_MAP_KEY = re.compile(r"""'([a-z_][a-zA-Z0-9_]*)'\s*:""")


def extract_cpp_fields(header_path: Path) -> dict[str, set[str]]:
    """Return {struct_name: {json_field, ...}} from a C++ header."""
    text = header_path.read_text(errors="replace")
    structs: dict[str, set[str]] = {}
    current: str | None = None

    for line in text.splitlines():
        # Detect struct/namespace context
        struct_m = re.search(r'\bstruct\s+(\w+)', line)
        if struct_m:
            current = struct_m.group(1)
            structs.setdefault(current, set())

        if current:
            for m in _KV_MEMBER.finditer(line):
                # KV_MEMBER_RENAME uses second arg as JSON key; plain KV_MEMBER uses field name
                json_key = m.group(2) if m.group(2) else m.group(1)
                structs[current].add(json_key)

    return structs


def extract_dart_fields(dart_path: Path) -> set[str]:
    """Return all json['key'] string keys used in a Dart file."""
    text = dart_path.read_text(errors="replace")
    fields: set[str] = set()
    fields.update(_DART_JSON_FIELD.findall(text))
    fields.update(_DART_MAP_KEY.findall(text))
    return fields


def check_dart_field_presence(
    dart_fields: set[str],
    required: list[str],
    forbidden: list[str],
    label: str,
) -> list[str]:
    errors: list[str] = []
    for f in required:
        if f not in dart_fields:
            errors.append(f"  MISSING   '{f}' in {label}")
    for f in forbidden:
        if f in dart_fields:
            errors.append(f"  FORBIDDEN '{f}' still present in {label}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Detect suite↔valise RPC drift")
    parser.add_argument("--suite", required=True, help="Path to fuego-suite root")
    parser.add_argument(
        "--valise",
        default=".",
        help="Path to fuego-valise root (default: cwd)",
    )
    args = parser.parse_args()

    suite_root = Path(args.suite)
    valise_root = Path(args.valise)

    all_errors: list[str] = []

    # 1. Check required_fields / forbidden_fields against Dart sources
    for struct_name, spec in TRACKED_STRUCTS.items():
        dart_path = valise_root / spec["dart_file"]
        if not dart_path.exists():
            all_errors.append(f"Dart file not found: {dart_path}")
            continue
        dart_fields = extract_dart_fields(dart_path)
        label = f"{spec['dart_file']} ({spec.get('dart_method') or spec.get('dart_class', '')})"
        errs = check_dart_field_presence(
            dart_fields,
            spec.get("required_fields", []),
            spec.get("forbidden_fields", []),
            label,
        )
        all_errors.extend(errs)

    # 2. Scan C++ headers for new KV_MEMBER fields not yet in Dart
    #    (best-effort; struct matching is approximate)
    cpp_fields_by_struct: dict[str, set[str]] = {}
    for rel in SUITE_HEADERS:
        h = suite_root / rel
        if h.exists():
            cpp_fields_by_struct.update(extract_cpp_fields(h))

    # For each tracked struct, check whether any C++ field is completely absent
    for struct_name, spec in TRACKED_STRUCTS.items():
        # Use the last component of struct_name as the C++ struct identifier
        cpp_struct_key = struct_name.split("::")[-1]
        cpp_fields = cpp_fields_by_struct.get(cpp_struct_key, set())
        if not cpp_fields:
            continue

        dart_path = valise_root / spec["dart_file"]
        if not dart_path.exists():
            continue
        dart_fields = extract_dart_fields(dart_path)

        for field in cpp_fields:
            if field and field not in dart_fields and field != "status":
                all_errors.append(
                    f"  UNTRACKED '{field}' in C++ {struct_name}"
                    f" not referenced in {spec['dart_file']}"
                )

    if all_errors:
        print("suite-sync DRIFT DETECTED:")
        for e in all_errors:
            print(e)
        return 1

    print("suite-sync OK — no drift detected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
