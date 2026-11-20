# Network catalog — one list, two owners

Status: **implemented.** Branch: `feat/network-catalog`. Suite pin: `524454dd43ccf77ec58ff6f525e105a83a1c5a5d`.

Post-implementation notes:

- GLEEC (`SwapPair` 12, wallet ticker `GLEEC`, yaml `gleec`, name `Gleec Chain`) joined the ready set and is in `SwapPairSdk` now. It was hand-written before.
- ZEC (22), DOGE (20) and DASH (21) are activated next: full-node RPC settings, config plumbing, `ChainTypeSdk` arms, and reserve-proof prefix/magic. The ready set is 25.
- `SwapPairSdk.fromId` throws on unknown ids. `tryFromId` returns null.
- `dex_cubit` offer/trade/status parsing uses `tryFromJson` and filters nulls.

Do not complete inactive pairs in this work. Do not assign new `SwapPair` IDs. Do not treat `/home/ar/fuego`'s live `xfg-swapd` catalog as the contract. That binary is ahead of the pin.

## Capability

After this ships, Valise and the pinned fuego-suite agree on which networks exist, which integer is on the wire, and which of those networks the wallet is allowed to trade. DeXFG, peer swap, swap settings, and the Rust SDK read that agreement. They do not keep private copies of it.

The user-visible outcome: the pair picker is a filter over one catalog, not a hand-counted enum. Pairs that are not active stay in the catalog with a reason, and in a generated backlog. They do not appear as tradable rows until a later task flips their activation.

## Why the current lists disagree

Six catalogs overlap, and two of them use a different integer than the wire. (DART enum is now generated from the catalog.)

| List | Where | What it counts | ID space |
|---|---|---|---|
| `SwapPair` | `fuego-suite/src/SwapDaemon/SwapTypes.h` | 0–28, including gaps the wallet hides | **wire uint8. This is the pair identity.** |
| `swapPairToString` | `SwapTypes.cpp` | same 29, but names are not wallet tickers | string, partially aliased |
| registration | `SwapDaemon.cpp` | client registered only if host/SPV is set; ZANO/TON/SIA/DOT refuse even then | runtime, per process |
| `chains.yaml` | repo root | 33 EVMs only. Comment says non-EVM stay hand-written | chain key, not SwapPair |
| `EvmChainKey` | `lib/models/erc20_token.dart` | same 33, hand-copied | chainId |
| `SwapPairSdk` | `lib/models/network_catalog.g.dart` | 25 ready (incl. GLEEC, ZEC, DOGE, DASH) | C++ ids, gaps omitted |
| `ChainTypeSdk` | same file | 23, including Fuego | **a second integer space. Fuego=0, Solana=1, Optimism=22. Not wire IDs.** |
| Rust `SwapPair` | `fuego-sdk/.../types.rs` | 0–11 only | wire IDs, truncated |
| Rust `ChainType` | `fuego-sdk/.../chain/mod.rs` | 13, no numeric id | symbol |
| `ChainInfo.swapableChains` | `lib/models/chain_info.dart` | the same tickers again | ticker |

DeXFG's picker is `SwapPairSdk.values` (`lib/screens/dex/dex_screen.dart`). Peer swap is `ChainInfo.swapableChains`, now the generated ready tickers. Settings EVM rows are `kReadyEvmKeys`. All three read the generated catalog.

`SwapPairSdk.fromId` throws on an unknown id. `ChainTypeSdk.fromId` maps an unknown id to Fuego, but that is a local proof-adapter id and is not documented as a wire id.

Wire calls that matter (`getswapoffers`, `getswapprice`, `getswaptrades`) already send the numeric `SwapPair` id to fuegod on 18180. The Rust SDK is not on that path. It is a second implementation of the same integers, checked only for the methods `fuegod-wire-check` happens to round-trip. FFI pair helpers stop at POLY=11.

Display ticker and wire name are not the same string. `swapPairFromString` accepts some aliases and rejects others.

| ID | Enum | `swapPairToString` | Wallet ticker | yaml key | `fromString` accepts wallet ticker? |
|---|---|---|---|---|---|
| 6 | `KMD_SPV` | `KMD_SPV` | KMD | (absent) | yes (`KMD`) |
| 7 | `BNB` | `BNB` | BNB | `bsc` | yes |
| 11 | `POLYGON` | `POLYGON` | POLY | `poly` | yes (`POLY`) |
| 13 | `ROBINHOOD` | `ROBINHOOD` | RHC | `rh` | **no** |
| 18 | `UNICHAIN` | `UNICHAIN` | UNI | `uni` | **no** |
| 19 | `PLASMA` | `PLASMA` | XPL | `xpl` | **no** |
| 23 | `PULSECHAIN` | `PULSECHAIN` | PLS | `pls` | yes (`PLS`) |
| 25 | `MONAD` | `MONAD` | MON | `monad` | **no** |
| 26 | `OPTIMISM` | `OPTIMISM` | OP | `op` | yes (`OP`) |

Rule this plan locks in: **the wire key is the uint8.** Valise does not send RHC, UNI, XPL, MON, or BSC to a daemon method that parses strings. Aliases are catalog data, not a second identity.

## Ownership (do not collapse this)

One list does not mean one file owned by nobody.

| Layer | Owner | Join key | Must not contain |
|---|---|---|---|
| Protocol identity | pinned `fuego-suite` `SwapPair` | uint8 | icons, colors, "show in the picker" |
| Presentation and wallet wiring | Valise `chains.yaml`, extended | `swap_pair_id` nullable, else `key` | a SwapPair id the pin does not have |
| Runtime registration | the running fuegod / xfg-swapd | same uint8 | a static claim that the process has a host configured |

Valise generates its Dart and Rust pair types **from the pin**, joined to the yaml overlay. It does not hand-edit `SwapPairSdk`, `ChainTypeSdk`, `swapableChains`, or the Rust `SwapPair` enum after that.

A pair is **executable** (allowed in the DeXFG picker and peer-swap chain list) only when all of these are true:

1. The pin has that `SwapPair` id.
2. `SwapDaemon.cpp` will `registerChain` for it when config is present. ZANO, TON, SIA, and DOT do not. They log and return.
3. The yaml row says `activation: ready` and has the presentation fields the UI needs (ticker, name, icon).

Everything else is in the catalog and in the generated backlog. It is not a tradable row.

Activation values, exhaustive:

| Value | Meaning | Picker |
|---|---|---|
| `ready` | Pin can register it, and Valise already wires it. 23, incl. GLEEC. | yes |
| `needs_wallet_wiring` | Pin can register it but Valise has no settings/RPC path. None today: ZEC, DOGE and DASH moved to `ready`. | no |
| `staged_in_suite` | Id reserved. `registerChain` is refused. ZANO, TON, SIA, DOT. | no |
| `wallet_only` | No `SwapPair` id. ERC-20 / account layer only. The 18. | no |
| `blocked` | Wallet-only, and a known reason it must not be cloned blindly. Tempo, and the zkEVM / RSK notes. | no |

`tier: swap` in yaml stops being the picker switch. It lied: it only covered EVMs, and it did not know about staged refusals. Keep the field during migration if settings code still reads it, but the generator is what settings must read. Delete the hand filter once call sites are moved.

## What this pass does not do

This is now implemented history, not an outstanding plan. Do not repeat any item.

- No new `SwapPair` id. The 18 wallet EVMs do not get ids here.
- No DASH/DOGE/ZEC settings screen, no DASH/DOGE/ZEC HTLC deploy, no ZEC/DOGE/DASH needs, no Optimism clones.
- No new fuegod or xfg-swapd RPC. There is no `getswapcatalog` on this pin. Adding one is a suite protocol change. Numeric ids on `/getswapoffers`, `/getswapprice`, `/getswaptrades` are already the efficient call. A catalog RPC is a follow-up so the UI can learn "this process did not register ZEC", which a static file cannot know.
- No self-hosted GitHub runner. One job on the existing `ubuntu-22.04` pool.
- No C++ `unified` beside the Valise binary. Unchanged.
- Do not copy pair ids out of `/home/ar/fuego`'s newer swapd. If those ids are wanted, they land in suite first, then the pin moves, then the generator notices.

## Decisions that need confirmation before code

Recommended answers are the ones the steps below assume. If a recommendation is rejected, stop and revise this file. Do not improvise a second catalog.

### D1. Where the machine-readable protocol list is born

**Recommend:** Phase 1 stays in Valise. `tool/gen_networks.dart` parses the pinned submodule:

- `fuego-suite/src/SwapDaemon/SwapTypes.h` `enum class SwapPair`
- `swapPairToString` / `swapPairFromString` in `SwapTypes.cpp`
- `msPerBlock` in `SwapTimelock.cpp`
- `PriceOracle::ctrDivisor`
- the `registerChain` vs "staged — not yet registered" blocks in `SwapDaemon.cpp`

It emits `lib/models/network_catalog.g.dart` and a Rust include. CI fails if any enum arm is unclassified, if yaml names an id the pin does not have, or if the generated files drift.

Phase 2, a separate suite PR, not this pass: suite emits `networks.json` from the same sources and the Valise parser becomes a checksum against that file. Do not block the untangle on that PR. Parsing a stable enum is brittle if someone reformats the header; the CI fixture is a checked-in extract of the pin, so a format break fails loudly instead of silently dropping ZEC.

**Reject:** making `chains.yaml` the inventor of wire ids. Valise does not own the uint8.

### D2. What the picker shows

**Recommend:** executable only (`activation: ready`). That remains 23 pairs until a later task sets ZEC (or anyone else) to `ready`. The other rows are visible in the generated backlog, not as disabled trade buttons. A disabled row that cannot lock is the same false catalog in a different widget.

### D3. Rust in the same change

**Recommend:** yes. Generate `#[repr(u8)] enum SwapPair` for ids 0–28 with `from_id() -> Option<Self>`. Unknown stays `None`. FFI must not map an unknown id to ETH or to POLY. Do not put DeXFG's orderbook calls through the Rust SDK. Dart already speaks fuegod JSON.

### D4. Display names

**Recommend:** keep wallet tickers (POLY, RHC, UNI, XPL, PLS, OP, MON, KMD, BNB). Do not rename the UI to `POLYGON` / `KMD_SPV` / `ROBINHOOD`. Those strings stay `wire_name` on the row. Confirm before anyone "normalizes" them.

### D5. Base branch

**Recommend:** `feat/network-catalog` cut from `feat/portfolio-home`, because DeXFG's picker was just edited there. Do not fold this into the portfolio PR. If that PR merges first, rebase onto master.

## Implementation contract

### Actors

- Wallet UI (DeXFG, peer swap, swap settings, ERC-20 account screens)
- `tool/gen_networks.dart` (the only writer of generated pair lists)
- pinned fuego-suite (read-only input)
- CI job `network-catalog`

### Surfaces that must read the catalog

- `lib/screens/dex/dex_screen.dart` pair picker
- `lib/screens/dex/peer_swap_screen.dart` (`swapableChains`)
- `lib/bloc/dex/dex_cubit.dart` pair↔chain switch and `_loadOffersFromFuegod` (fan out only `ready` ids, not every enum arm and not staged ids)
- `lib/screens/settings/swap_settings_screen.dart` and `SwapConfigService` EVM swap set
- Rust `SwapPair` and its FFI `from_id`

### Surfaces that must not grow a new list

- `ChainInfo.names` / `swapableChains` — become lookups into the catalog, or be deleted
- `EvmChainKey` — generated from yaml rows with `family: evm`. The golden test in `test/chains_registry_test.dart` stays, pointed at the generated enum
- hand `SwapPairSdk` / `ChainTypeSdk` integer constructors

### Invariants

1. Every `SwapPair` arm in the pin has exactly one catalog row.
2. No yaml `swap_pair_id` points at an id the pin lacks. No duplicate ids.
3. Display tickers are unique. Wire names are unique. A display ticker may differ from the wire name; that difference is an explicit `aliases` entry.
4. `activation: ready` is rejected by the generator if the pin classifies the id as `staged_in_suite` or the id is absent.
5. Unknown wire ids do not become ETH, Fuego, or pair 0.
6. Wallet-only rows have `swap_pair_id: null`. They are not passed to `getswapoffers`.
7. Generated files are committed. CI runs `--check`. A Dependabot submodule bump fails this job until the generator is re-run. That is the point.

### `ChainTypeSdk` integer

Do not preserve it as a public id. Before deleting it, confirm no fuegod or xfg-swapd response field is documented or parsed as that integer. `PaymentProofSdk.fromJson` reads `chain_id` into `ChainTypeSdk.fromId`. Rust `ChainType` serializes as a unit-variant name, not that integer, so this field is likely a Dart-only fiction. The implementation step verifies that with a grep of producers. If a daemon actually emits those integers, stop and record the field. Do not guess a mapping.

Until that grep is done, call sites may keep a generated view type, but its identity is the catalog `key` / `swap_pair_id`, not `ChainTypeSdk.id`.

### Communication path (unchanged, just honest)

| Call | Process | Port | Pair key |
|---|---|---|---|
| Orderbook, price, trades | fuegod (embedded swap relay) | 18180 | uint8 `SwapPair` |
| Lock / claim / refund | xfg-swapd | 18902 | uint8, and only if that process registered the client |
| Wallet proxy | fuego_walletd | 18189 | not a pair list |

`_loadOffersFromFuegod` currently issues one `getswapoffers` per `SwapPairSdk` value. After this, it issues one per `activation: ready` row. Do not add a batch RPC in this pass. 23 short local calls are not the defect. The defect was those pairs being a private list.

xfg-swapd registration remains config-gated. A `ready` row means "this pin is capable and the wallet knows how to ask." It does not mean the local process has a funded key. Settings already own that. Do not paint a ready pair as live on 18902 unless a health probe says the client registered. If no such probe exists, say so in the UI copy only when the user opens swap settings — do not invent a status field.

## Generator shape

`tool/gen_networks.dart` (name flexible; one tool, not a second generator beside `gen_chains.dart` that can drift). Either extend `gen_chains.dart` or replace its pair-blind output. One command:

```text
dart run tool/gen_networks.dart           # write generated files
dart run tool/gen_networks.dart --check   # exit 1 on drift
```

Inputs:

- pinned suite sources listed under D1
- `chains.yaml` presentation overlay

Outputs:

- `lib/models/network_catalog.g.dart` — rows, `ready` filter, lookup by id, lookup by ticker, lookup by key
- Rust `swap_pair_generated.rs` included by `types.rs` — `repr(u8)`, `TryFrom<u8>`, `as_str` is the **wire** name, display ticker is not this function
- `docs/networks.backlog.md` generated, committed, covered by `--check`

Parser failure modes that must exit 1, not skip the arm:

- enum arm with no `swapPairToString` case
- enum arm with no `msPerBlock` case
- enum arm with no `ctrDivisor` case
- enum arm neither registered nor explicitly staged in `SwapDaemon.cpp`
- yaml `swap_pair_id` not in the enum
- two rows, one id
- `activation: ready` on a staged id
- display ticker collision

`ctrDivisor` for SIA is `1e24`. Record it on the row and in the backlog as "does not fit a uint64 atomic amount; do not activate." Do not "fix" the divisor in Valise.

Schema addition on `chains.yaml`, backward compatible for the 33 EVMs:

```yaml
swap_pair_id: 22          # omit or null if wallet_only
activation: needs_wallet_wiring
# existing key, ticker, name, family, rpc, gasToken, color, icon, confirmBlocks
# chainId stays required for family: evm, optional otherwise
```

Non-EVM ready pairs (BTC, LTC, BCH, KMD, DCR, SOL, XMR) get rows too, so the file is the presentation list for every network the wallet knows, not "EVMs only, everything else handwritten." `family` already allows `utxo | cryptonote | sol`. The generator's required-field set must allow a missing `chainId` when `family != evm`.

`EvmChainKey` is emitted from `family: evm` rows in yaml order. Do not keep the hand enum.

## Steps

Each step is one PR-sized change. Step 1 is implemented. The open-question decisions are recorded as post-implementation notes at the top of this file. Do not re-open D1–D4 unless something here breaks the repo contract.

### Step 1 — Generator and backlog, no UI switch

Context: catalogs listed above. Pin `524454d`. Do not edit `SwapDaemon` sources.

Tasks:

- Add the parser and `chains.yaml` rows for every pin id, with activation set so the ready set equals the first implementation's `SwapPairSdk` tickers. ZEC/DOGE/DASH are `needs_wallet_wiring`. ZANO/TON/SIA/DOT are `staged_in_suite`. The 18 EVMs stay `wallet_only`; Tempo, zkSync, Abstract, RSK also get `blocked` notes in the backlog text, not a new activation unless the schema needs it. A note field is enough.
- Emit Dart catalog, Rust include, `docs/networks.backlog.md`.
- Tests: ready tickers equal `SwapPairSdk.values`; every pin id appears once; SIA divisor recorded; RHC/UNI/XPL/MON recorded as display aliases the C++ parser does not accept; unknown id is not ETH.
- Wire `dart run tool/gen_networks.dart --check` into `.github/workflows/fuego-wallet-ci.yml` as job `network-catalog`. No new runner, no fuegod build. The existing `fuegod-wire-check` job stays.

Exit: CI job green. UI still uses the old enums. Generated ready set matches them.

Rollback: delete the tool, the generated files, the workflow job, and the yaml fields.

### Step 2 — UI and settings read the catalog

Context: step 1 generated a `ready` filter equal to today's picker.

Tasks:

- DeXFG picker and peer-swap chain list iterate `ready` rows.
- `dex_cubit` offer fan-out uses those ids only.
- `fromId` style helpers return null / error. Call sites that assumed ETH must handle absence. Do not keep the fallback "for safety."
- Swap settings EVM list comes from catalog rows with `family: evm` and `activation: ready`, not `kChains.where(tier == swap)` copied by hand.
- Delete `ChainInfo.swapableChains` once grep shows no readers.
- Leave `ChainTypeSdk` call sites compiling via a thin generated adapter if step 3 is not in this PR. The adapter's id must not be documented as a wire id.

Exit: picker count is 23 (incl. GLEEC), but the source is the catalog. A unit test fails if someone adds a `SwapPairSdk` value that is not `ready`, or a `ready` row the picker cannot see.

Rollback: revert the call-site switch. Step 1 files can stay.

### Step 3 — Rust enum and FFI

Context: `rust-fuego-wallet/fuego-sdk/fuego-sdk/src/types.rs` `SwapPair` ends at `XfgPoly = 11`. FFI in `fuego-ffi/src/lib.rs` matches on it.

Tasks:

- Include the generated `repr(u8)` enum. `from_id` is `Option`. Remove the old 12-arm enum.
- FFI returns a clear error on unknown id. No silent POLY/ETH.
- `cargo test -p fuego-sdk` and the FFI tests. If `fuegod_wire` does not speak pairs, do not pretend it covers this. Add a focused test that ids 0–28 round-trip the wire name and that 29 is `None`.
- Do not extend `ChainType` into a second numeric protocol. SPV helpers key by symbol from the catalog, or stay as they are if they are not on the pair-list path. Do not invent ChainType ids for ZEC.

Exit: Rust cannot disagree with the pin about a known id.

Rollback: restore `types.rs`. Dart catalog from steps 1–2 still stands.

### Step 4 — Delete the hand enums

Context: steps 2–3 callers are on the catalog.

Tasks:

- Remove hand `SwapPairSdk` if the generated type replaced it. If the name `SwapPairSdk` is kept, it is the generated type, not a hand list.
- Remove `ChainTypeSdk`'s integer after the producer grep in the contract section. If a producer exists, this step stops and the plan is amended.
- Update `test/swap_pair_expansion_test.dart` so it does not re-encode the tickers by hand. It now checks the generated catalog directly.
- Fix the comment in `swap_models.dart` that says the Dart enum is 1:1 with Rust. That sentence is how the next drift starts.
- One paragraph in `AGENTS.md` under the swap section: pair identity is the suite `SwapPair` uint8; Valise presentation is `chains.yaml`; the generated catalog is the join; do not add a pair id in Dart.

Exit: `rg` over `lib/` and `rust-fuego-wallet/` finds no hand list of pair ids. Generated files and yaml are the only copies.

## CI

Add to `.github/workflows/fuego-wallet-ci.yml`. Do not create a new workflow file unless the job needs a different checkout. It does not.

```yaml
network-catalog:
  name: Network catalog matches suite pin
  runs-on: ubuntu-22.04
  steps:
    - uses: actions/checkout@v4
      with:
        submodules: true
    - uses: subosito/flutter-action@v2
      with:
        flutter-version: "3.44.4"
        channel: stable
    - run: dart run tool/gen_networks.dart --check
    - run: cargo test --manifest-path rust-fuego-wallet/Cargo.toml -p fuego-sdk --lib swap_pair
```

The cargo line lands with step 3. Step 1's job is the Dart `--check` only.

No `runs-on` self-hosted label. No new runner registration. ubuntu-22.04 matches the wallet CI image already used for glibc.

What the job catches:

- someone adds `SwapPair::FOO` in a pin bump and Valise does not regenerate
- someone sets `activation: ready` on TON
- someone invents `swap_pair_id: 29` in yaml
- generated Dart/Rust/backlog drift from the pin

What it does not catch: a local xfg-swapd built from a different suite than the pin. That is an operator problem. The app's catalog follows the submodule the release was built with.

## Backlog — not this pass

Generated into `docs/networks.backlog.md` so it cannot rot. The content below is the seed. The generator must reproduce it from the pin plus yaml notes. If the generator and this section disagree, the generator wins after step 1, and this section is deleted from the plan.

### Needs Valise wiring only (suite client already registers when a host is set)

Do not do these now.

**ZEC (22)** — `ZecChainClient`, transparent UTXO, P2SH. No ZEC SPV in this tree. Claim/refund need a zcashd-style node with `-txindex` and a WIF. `msPerBlock` 150000. Divisor 1e8 zatoshis. Valise still has no ZEC settings screen. Left: settings RPC/WIF, catalog `activation: ready` only after that screen exists. Not an enum patch by itself.

**DOGE (20)** — `DogeChainClient` registers iff `dogeHost` is set. No SPV branch. Divisor 1e8. Valise has no settings screen.

All three live in the generated backlog section `Needs Valise wiring`: DOGE (20, doge), DASH (21, dash), and ZEC (22, zec). The generator includes DOGE (20), DASH (21), and ZEC (22).

### Staged in suite (id reserved, registerChain refused)

**ZANO (24)** — CryptoNote sources exist (`ZanoChainClient`). SwapDaemon logs and does not register. Not an XMR drop-in: shared view key / adaptor path is unfinished. Divisor 1e12. Left: finish suite registration, then a pin bump, then the generator will refuse `ready` until that pin actually registers it.

**TON (27)** — left out on purpose. Source comment: `TonRpcClient` apiKey / htlcAddress signature mismatch. `msPerBlock` 5000. Divisor 1e9.

**SIA (17)** — left out on purpose. Registration refused. `ctrDivisor` returns `1e24` (hastings). That magnitude does not fit the uint64 amount model, and it is not an exact integer in an IEEE double. Do not activate by ignoring the divisor.

**DOT (28)** — not UTXO, EVM, or CryptoNote. `PolkadotChainClient` is a stub (SCALE / `pallet-hashTimeLock` or XCM). Registration refused. Divisor 1e10 planck. No template to clone.

### No SwapPair id (wallet tier in `chains.yaml`)

These are ERC-20 / account networks. They are not pairs until suite assigns an id **after** 28 and ships a client. Valise must not reserve the id locally.

Template, when that work starts: `OptimismChainClient` is an `EthChainClient` subclass. A real activation still needs a new enum arm, config fields, `registerChain`, `swapPairToString`, `msPerBlock`, `ctrDivisor`, a `HashedTimelock.sol` deploy (CREATE2 sameness is not guaranteed on every chain — Gleec already special-cases its own registry), yaml `swap_pair_id`, and `activation: ready` only after settings can pass a host. Then the pin bumps and the generator updates. That is the whole task. It is not a Dart enum edit.

Skip, do not clone blindly:

- **Tempo** — `gasToken` empty. No native asset to lock.
- **zkSync, Abstract** — zkEVM CREATE2 may not match the ETH HTLC address. Gleec's comment in `SwapDaemon.cpp` is the precedent: a shared `ethHtlcRegistry` is only valid where CREATE2 put the contract at the same address.
- **RSK** — RBTC and a different address format. Not an Optimism clone until that is proven.

Later candidates, same Optimism-shaped work, still not this pass: linea, hyperevm, ink, gnosis, flare, kaia, scroll, plume, soneium, doma, beam, moonriver, peaq, sei. Fourteen. Plus the three special cases above if someone proves the clone. Seventeen excluding Tempo. Eighteen wallet-tier keys today: linea, zksync, hyperevm, ink, rsk, gnosis, flare, kaia, scroll, abstract, plume, soneium, doma, beam, moonriver, peaq, tempo, sei.

### String aliases that are already a footgun

Even for `ready` pairs, do not send display tickers to `swapPairFromString`. Missing aliases on this pin: `RHC`, `UNI`, `XPL`, `MON`. `BSC` is a yaml key, not a wire name; the ticker `BNB` is accepted. Fixing the C++ aliases is a suite change. This pass avoids the bug by sending uint8 only.

## Backlog B — activation plans

Backlog A above is the generated ledger. This section is the execution plan.
One rule decides every flip: a row becomes `activation: ready` only when the
pinned suite registers the client **and** Valise can write a config the client
accepts. A label is not an activation.

Suite ids 0–28 are fixed. Proposed ids below 29+ are not real until the pin
contains them. Never put a proposed id in `chains.yaml` early: the generator
fails on an id the pin does not have, and that failure is correct.

### B1. Full-node UTXO pairs — ZEC (22), DOGE (20), DASH (21)

All three clients already exist in the pin. `SwapDaemon.cpp` registers each
one when its `*_rpc_host` is non-empty. None has an SPV branch: lock, claim
and refund are RPC calls, so the user runs a node. There is no suite change
and no new id. Activation is a settings surface plus config plumbing.

Shared checklist per pair:

- [ ] Settings card: WIF, RPC host, RPC port, RPC user, RPC password.
- [ ] Secure storage: `swap_wif_<key>`, `swap_rpc_host_<key>`,
      `swap_rpc_port_<key>`, `swap_rpc_user_<key>`, `swap_rpc_pass_<key>`.
- [ ] Config writer emits `<key>_rpc_host`, `<key>_rpc_port`,
      `<key>_rpc_user`, `<key>_rpc_pass`, `<key>_wif`. It must not emit
      `<key>_mode=spv`; those keys are ignored by these clients and hide the
      fact that a node is required.
- [ ] Catalog: `activation: ready`, `enum_name`, `tier: swap`.
- [ ] `ChainTypeSdk` arm, `_chainForPair`, `_pairNameForChain`, reserve-proof
      address prefix and signmessage magic (see below).
- [ ] `ChainInfo`: `wired` is no longer `false`; the dialog says node + WIF.
- [ ] Acceptance: saved JSON shows the five `*_rpc_*`/`*_wif` keys, `xfg-swapd`
      logs `... chain client registered`, DeXFG lists `XFG/<ticker>`, and a
      test lock/claim/refund round-trips on the node.

#### B1a. ZEC (22)

- Node: `zcashd -txindex -rpcuser=… -rpcpassword=…` (or an RPC proxy), default
  port 8232.
- WIF prefix 0x80 (`5…`, `K…`, `L…`). Transparent P2PKH only.
- Address prefix 0x1CB8 (two-byte), signmessage magic
  `"\x18Zcash Signed Message:\n"`.
- Risk: shielded-only funds are invisible to this client. Say "transparent
  t-address" in the UI; do not imply Sapling support. The node must be
  unlocked for signing if it manages keys, though Valise signs from the WIF.
- Acceptance extras: t-address in the proof matches the WIF's pubkey hash;
  `msPerBlock` 150000, divisor 1e8.

#### B1b. DOGE (20)

- Node: `dogecoind -txindex -rpcuser=… -rpcpassword=…`, default port 22556.
- WIF prefix 0x9E (`Q…`), P2PKH 0x1E, signmessage magic
  `"\x19Dogecoin Signed Message:\n"`.
- Risk: pre-SegWit, legacy sighash. Fee estimate comes from the node; no
  Replace-by-Fee assumptions. Dust and 1 DOGE minimum output handling stay in
  the client.
- Acceptance extras: `msPerBlock` 60000, divisor 1e8.

#### B1c. DASH (21)

- Node: `dashd -txindex -rpcuser=… -rpcpassword=…`, default port 9998.
- WIF prefix 0xCC (`X…`), P2PKH 0x4C, signmessage magic
  `"\x19DarkCoin Signed Message:\n"`.
- Risk: standard transactions only. InstantSend/ChainLocks are not part of the
  swap proof; confirmation depth is the guarantee.
- Acceptance extras: `msPerBlock` 260000, divisor 1e8.

Order: ZEC, then DOGE, then DASH. One commit each so a bad activation is one
revert. Each commit includes the yaml flip, regenerated catalog, settings,
config test, and catalog-test assertions. `activation: ready` lands in the
same commit as the settings path, never before it.

### B2. EVM pairs — proposed ids 29–45

**One contract per chain, not one global deployment.** It is the same
`HashedTimelock.sol` source and bytecode, but every chain gets its own
deployment and its own address. CREATE2 yields the same address across chains
only when the factory, salt and init code match *and* the chain implements
CREATE2 the same way. Gleec already keeps a separate registry for this reason,
so "same address everywhere" is an assumption to prove per chain, not a
default.

#### B2a. Pre-flight every chain must pass

1. Suite assigns the next `SwapPair` id after 28. Ids are contiguous; a gap is
   a pin bug.
2. `chainId`, native gas token, default RPC, explorer tx URL, `confirmBlocks`
   and `msPerBlock` recorded in `chains.yaml`.
3. `HashedTimelock.sol` deployed; address + runtime bytecode hash recorded;
   `eth_getCode` non-empty on the public RPC.
4. Wrap/unwrap is native gas only. No ERC-20 pair, no gas-token abstraction.
5. A scripted lock → claim and lock → refund round-trip passes on that chain.

#### B2b. Suite template (`Optimism` clone)

`OptimismChainClient` is an `EthChainClient` subclass. A new pair needs, in
the pin: enum arm; `*Host/*Port/*PrivKeyHex/*Address/*ChainId/*HtlcBinPath`
fields in `ChainClientConfig` + loader; `registerChain` block; arm in
`swapPairToString`/`swapPairFromString`; `msPerBlock`; `ctrDivisor`;
`PriceOracle` row if the pair quotes XFG. The HTLC deploy is per chain. Then
the submodule pin moves and `tool/gen_networks.dart` picks the id up.

#### B2c. Valise template after the pin bump

`chains.yaml` row (`swap_pair_id`, `activation: ready`, `enum_name`, `tier:
swap`, RPC); regenerate; settings EVM card appears automatically from
`kReadyEvmKeys`; `_chainForPair`, `_pairNameForChain` and `_evmChainKey` arms;
`ChainTypeSdk` arm; orderbook + trades parse by uint8. No hand-written list.

#### B2d. Planned order (proposals, not ids)

| # | Key | Chain | Id (proposed) | Gate |
|---|-----|-------|---------------|------|
| 1 | `linea` | Linea | 29 | standard EVM + CREATE2 proof |
| 2 | `zksync` | zkSync Era | 30 | zkEVM CREATE2 / registry proof |
| 3 | `hyperevm` | HyperEVM | 31 | standard EVM |
| 4 | `ink` | Ink | 32 | OP Stack |
| 5 | `rsk` | Rootstock | 33 | RBTC + address-format proof |
| 6 | `gnosis` | Gnosis | 34 | standard EVM |
| 7 | `flare` | Flare | 35 | standard EVM |
| 8 | `kaia` | Kaia | 36 | standard EVM |
| 9 | `scroll` | Scroll | 37 | zkEVM + CREATE2 proof |
| 10 | `abstract` | Abstract | 38 | zkEVM CREATE2 / registry proof |
| 11 | `plume` | Plume | 39 | standard EVM |
| 12 | `soneium` | Soneium | 40 | OP Stack |
| 13 | `doma` | Doma | 41 | standard EVM |
| 14 | `beam` | Beam | 42 | standard EVM |
| 15 | `moonriver` | Moonriver | 43 | standard EVM |
| 16 | `peaq` | peaq | 44 | standard EVM |
| 17 | `sei` | Sei | 45 | standard EVM |

Tempo is excluded: `gasToken` is empty, so there is no native asset to lock.

#### B2e. Proof gates that keep a row `wallet_only`

- **zkSync, Abstract, Scroll**: deploy the HTLC and compare
  `eth_getCode`/address against Ethereum. If the address differs, store the
  per-chain address. If CREATE2 semantics differ, the shared-registry
  assumption is false; use a per-chain registry, not a local enum edit.
- **RSK**: RBTC is the gas asset, but the address format and HTLC bytecode
  environment must be proven. Treat as wallet-only until a lock/claim
  round-trip passes.
- A gate that fails does not block the other 14. Ship the proven ones, leave
  the gated rows `wallet_only`, and record the failing check in `note`.

#### B2f. Execution order

1. Suite PR: ids + client clone + HTLC deploy for the first chain; bump pin.
2. Valise: yaml row, regenerate, settings/UI arms, tests; flip `ready`.
3. Repeat per chain. Batch the standard EVMs; keep zkSync/Abstract/RSK
   separate until their proof gate passes.

## Verification

- `dart run tool/gen_networks.dart --check`
- `dart test test/chains_registry_test.dart test/swap_pair_expansion_test.dart` plus the new catalog test
- `cargo test -p fuego-sdk --lib swap_pair` after step 3
- `rg -n "enum SwapPairSdk|swapableChains|XfgPoly = 11" lib rust-fuego-wallet` returns nothing after step 4
- Picker widget test: item count equals catalog `ready` length, and that length is 23 until an activation flip is an explicit, reviewed yaml change

A green `fuegod-wire-check` does not prove the catalog. It does not iterate pairs.

## Plan mutation

If D2 is rejected and disabled rows are required in DeXFG, add a filter `shown_but_not_tradable` and a widget state. Do not mark those rows `ready`.

If D1 is rejected and a suite `networks.json` must land first, this plan's step 1 waits on a fuego-suite PR and a submodule bump. Do not parse headers and also hand-maintain a Valise JSON.

If a pin bump adds id 29 before this work merges, step 1's parser must fail until a yaml row exists. That failure is correct.
