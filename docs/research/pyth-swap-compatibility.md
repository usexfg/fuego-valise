# Pyth qualification — 2026-10-03

This is a researched integration assessment, not permission to implement, subscribe, deploy or fund anything. Refresh primary documentation before acting on it.

## Three different requests

| Request | Classification | Integration decision |
|---|---|---|
| Add Pythnet as a settlement chain | Oracle-specific Solana-derived appchain, not EVM | Exclude from the native EVM batch. Pyth is retiring Pythnet; do not build a new settlement adapter against its historical infrastructure. |
| Swap the PYTH asset | Solana SPL token, or a wrapped token on a chosen existing network | Requires a token-aware swap integration; neither the SOL native client nor the EVM native-value client provides it. |
| Use Pyth for counterparty prices | Oracle-provider integration | A separate price source for existing settlement assets, not a chain client or a swap pair by itself. |

Pyth's [official repository](https://github.com/pyth-network/pythnet) identifies Pythnet as a Solana-derived application-specific chain. Its [current contract directory](https://docs.pyth.network/price-feeds/core/contract-addresses) and [retirement announcement](https://www.pyth.network/blog/pyth-s-next-chapter-infrastructure-upgrade-and-a-revenue-based-economic-model) identify the shutdown. Do not conflate Pythnet with Solana mainnet or claim an exact shutdown completion date from the announcement.

The [official PYTH address directory](https://docs.pyth.network/pyth-token/pyth-token-addresses) identifies the Solana token and wrapped representations on Ethereum, Arbitrum, Base and other networks. The selected network/mint or contract address is the asset identity; `PYTH` alone is not enough. A wrapped representation also adds bridge risk. Token addresses, oracle contract addresses and swap registry addresses are not interchangeable.

## What PYTH swaps would require

At reviewed suite `a36eccb5b`, `src/SwapDaemon/Ethereum/HashedTimelock.sol` escrows `msg.value` and pays native currency. `src/SwapDaemon/Solana/SolRpcClient.h` and its client pass native SOL lamports. Appending a `PYTH` descriptor would still lock the wrong asset.

1. Choose one settlement network and exact official token representation. Verify decimals and executable token semantics against that network. Define asset identity separately from the network/gas coin, bind it in authenticated negotiation, and persist it for recovery. Do not silently turn an existing native pair into a token pair or reuse its ID.
2. Implement the authorized escrow path. ERC-20 needs token-address-bound HTLC/PTLC state, allowance/approval, safe token calls, exact balance-delta checks, reentrancy protection and token claim/refund. Solana SPL needs token-program/mint checks, escrow token accounts, correct account ownership/PDA authority, token transfers and rent/fee handling. Preserve the selected hash/point convention; native PTLC capability does not prove token PTLC capability.
3. Extend the chain adapter's balances, reserve proofs and lock/verify/claim/refund/secret extraction. Verify actual receipt/account state, token identity, sender, recipient, exact credited value, expiry, canonical confirmations and claim observation. Native gas/rent must be funded separately from the token balance. Reject unsupported transfer semantics rather than returning apparent success.
4. Reconcile catalog/relay, signed wire and database versions, config, token pricing/divisor, dashboard, CLI, Dart/Rust wallet models, exact atomics and the suite pin. Existing wallet token visibility is not executable swap support.
5. Retain gates until authorized funded tests cover both XFG/token legs and roles, wrong-token/account substitution, allowance failures, insufficient gas/rent, malformed amounts, unauthorized/replayed claims, independent preimage observation, refund, restart and reorg/recovery. No existing native test establishes these token cases.

This is reusable token-swap infrastructure plus a PYTH deployment choice, not a descriptor-only EVM addition. The ERC-20 route reuses the existing EVM transport/signing infrastructure; the SPL route targets the original Solana representation. Choosing between them requires the operator's asset/network preference, not an inferred permission to bridge.

## What using Pyth as our oracle would require

The [August 26, 2026 upgrade guide](https://docs.pyth.network/price-feeds/core/upgrade/preparing) says Hermes now needs API-key authentication; a trial is offered and ongoing use requires a paid plan. Do not assume historical anonymous endpoints or prices remain usable. Keep credentials server-side, confirm terms/feed coverage and obtain authority before opening an account or buying service.

Add a provider path feeding the existing `PriceOracle`, with exact native-settlement feed IDs, explicit price-unit direction and decimal/exponent handling. ETH-gas chains use an ETH price, not the network's governance-token price. A counterparty/USD feed does not automatically supply the XFG/USD side of the quote; record that source/policy separately.

Define whether prices are display-only or authorize funding. For execution prices, verify signed updates or independently read the correct verified on-chain oracle with a documented trust model; an HTTP JSON price alone is not equivalent to a verified update. The [upgraded architecture](https://docs.pyth.network/price-feeds/core/upgrade/how-it-works) uses router signatures and Merkle proofs, not the legacy Pythnet/Wormhole verification assumption. Follow current verification contracts/signers instead of implementing an old payload trust policy.

Enforce publish-time/future-time checks, bounded confidence, positive valid prices, exponent/range limits, stale/deviation/outage rejection, cache provenance and recovery behavior. Follow Pyth's [price-feed safety guidance](https://docs.pyth.network/price-feeds/core/best-practices). Test provider failure and malformed/forged/stale data; keep new admission unavailable when its required oracle fails while preserving claim/refund recovery. If on-chain update submission is selected, account for update fees and separate broadcast authority.

An oracle integration can improve rate coverage. It does not deploy a swap registry, add a signer, remove missing XFG funding evidence, or make a token/native-chain adapter production-ready.
