# Marketing Context

*Last updated: 2026-09-14*

> Canonical context for all marketing work in this repo. Heatwave is an **unreleased teaser campaign** for the **Obsidian Reserve** house; the shipped product is **Fuego Valise** (`pubspec.yaml` version `5.11.0+1`). “Bank of XFG” is retired. “L'Avoir XFG” is not used.

## Product Overview
**One-liner:** Fuego Valise is a self-custody privacy wallet and cross-chain exchange client for XFG and ΗΞΔŦ (HEAT).
**What it does:** It combines a CryptoNote privacy wallet, 12-pair atomic swap interface, on-chain XFG/HEAT orderbook ("Hearth Floor"), HEAT certificates of deposit, aliases, and CPU mining in one Flutter app. Desktop can run a local unified daemon; mobile uses remote daemon failover.
**Product category:** Privacy crypto wallet / decentralized exchange client / sound-money banking alternative.
**Product type:** Open-source multi-platform wallet (Android, iOS, macOS, Linux, Windows).
**Business model:** No custodial accounts or subscription; protocol fees exist in-product (e.g., swap fee split, CD creation fee). Marketing must not imply regulated banking, deposits, insurance, or guaranteed yield.

## Target Audience
**Target companies:** Not company-targeted; individual privacy-conscious crypto users and operators.
**Decision-makers:** Self-directed wallet users, privacy maximalists, cross-chain traders, inflation-hedged savers, desktop node operators.
**Primary use case:** Hold XFG/HEAT privately and exchange across chains without custodial bridges.
**Jobs to be done:**
- Preserve privacy while holding and transferring XFG/HEAT.
- Exchange between XFG and external chains through atomic swap flows.
- Park HEAT in fixed-term CDs and track protocol yield/fee flows.
**Use cases:**
- Desktop user runs local `fuego_walletd`/fuegod/xfg-swapd and executes swaps.
- Mobile user connects through remote daemon and manages balances/CDs.
- Community member follows teaser campaign and joins official channels.

## Personas

| Persona | Role | Cares about | Challenge | Value we promise |
|---------|------|-------------|-----------|------------------|
| Privacy maximalist | User | Ring signatures, local control, no tracking | Custodial and surveillance-heavy tools | Private-by-default wallet architecture |
| Cross-chain trader | User | Atomic execution, clear swap state, no bridge custody | Wrapped assets, opaque bridge risk | 12-pair swap surface with explicit status |
| Sound-money saver | User | Purchasing-power preservation, transparent fees | Fiat-pegged stablecoin inflation drift | HEAT flatcoin narrative and CD mechanics |
| Node sovereign | Technical influencer | Local daemon, SPV/RPC control, verifiable infra | Black-box hosted wallets | Local/remote daemon topology and documented ports |
| Luxury-house observer | Champion | Restraint, rarity, cultural identity | Crypto hype and neon casino aesthetics | Obsidian Reserve voice and visual system |

## Problems & Pain Points
**Core problem:** Users who want privacy and cross-chain exchange are pushed toward custodial exchanges, wrapped assets, or surveillance-heavy wallets.
**Why alternatives fall short:**
- Centralized exchanges require custody and identity exposure.
- Bridges introduce custodial or smart-contract risk.
- Typical crypto marketing overpromises yield and understates operational constraints.
**What it costs them:** Privacy leakage, counterparty risk, confusing swap recovery paths, and mistrust.
**Emotional tension:** Fear of being watched, fear of irreversible mistakes, fatigue with hype.

## Competitive Landscape

| Competitor | Type | How they fall short |
|-----------|------|---------------------|
| Centralized exchanges | Indirect | Custody, KYC, withdrawal risk |
| Wrapped-asset bridges | Direct | Custodial/contract risk and non-native settlement |
| Generic multi-chain wallets | Secondary | Broad asset support but weaker privacy posture |
| Monero-only wallets | Secondary | Strong privacy but no Fuego/HEAT-specific flows |
| DEX aggregators | Secondary | Convenience over sovereignty and privacy |

## Differentiation
**Key differentiators:**
- XFG privacy chain plus HEAT flatcoin mechanics in one wallet.
- 12 cross-chain swap pairs with HTLC/PTLC/BRIDGE lock types.
- Dual-mode daemon architecture: local embedded node on desktop, remote failover on mobile.
- House brand system: obsidian/champagne/midnight luxury identity instead of fintech neon.
**How we do it differently:** Treat privacy and restraint as the product experience, not a settings page.
**Why that's better:** Lower custody dependence, clearer operational model, stronger brand trust.
**Why customers choose us:** They want private exchange without casino aesthetics or custodial framing.

## Objections

| Objection | Response |
|-----------|----------|
| "Is this a real bank?" | No. Obsidian Reserve is a campaign house name; Fuego Valise is self-custody software with no deposits or insurance. |
| "Is v1.11 Heatwave released?" | No. Heatwave is a teaser concept; current package version is 5.11.0+1 unless release notes say otherwise. |
| "Are CD yields guaranteed?" | No. UI may display APY figures, but marketing must not promise returns or financial performance. |
| "Can every chain claim/refund in SPV mode?" | No. UTXO SPV is read-only; claim/refund requires RPC mode for those chains. |

**Anti-persona (NOT a good fit):** Users seeking regulated banking, insured deposits, guaranteed yield, leveraged trading, or custodial convenience.

## Switching Dynamics
**Push (away from current):** Distrust of custodial exchanges, bridge exploits, surveillance fatigue, hype-driven wallets.
**Pull (toward us):** Privacy posture, atomic swap narrative, HEAT sound-money identity, luxury restraint.
**Habit (keeping them stuck):** Existing exchange accounts, familiar wallets, fear of running daemons.
**Anxiety (about switching):** Fear of irreversible transactions, confusing swap states, unverified claims.

## Customer Language
**How they describe the problem:**
- "I don't want to hand keys to an exchange."
- "Bridges feel like black boxes."
- "Everything in crypto looks like a casino."
**How they describe us:**
- "Private bank aesthetic without asking permission."
- "The wallet that feels like a vault."
**Words to use:** private exchange, vault, reserve, dispatch, ledger, provenance, sound money, rare, quiet, certain.
**Words to avoid:** bank, banker, banking, trust, guaranteed returns, insured deposits, bank charter, risk-free, anonymous guarantee, moon, yield farm, casino.

| Term | Meaning |
|------|---------|
| XFG | Fuego privacy coin |
| ΗΞΔŦ / HEAT | Purchasing-power-tracking flatcoin minted by burning XFG |
| Fuego Valise | Actual wallet product name |
| Obsidian Reserve | Campaign house identity |
| Bank of XFG | Retired — do not use |
| Heatwave | Fictional v1.11 teaser campaign identity |
| Hearth Floor | On-chain XFG/HEAT orderbook exchange |
| Private Exchange | House term for atomic swap UX |
| Reserve | House term for deposit-like CD action |
| Dispatch | House term for send/transfer |
| Ledger | House term for transaction history |
| Provenance | House term for explorer/reference links |

## Brand Voice
**Tone:** Cold, precise, literary, confident.
**Style:** Declarative sentences, minimal punctuation, no hype.
**Personality:** Rare, private, disciplined, exact, timeless.
**Voice DO's:** Use inversion (weakness → strength), negative space, understated CTAs.
**Voice DON'T's:** No emojis in campaign copy, no exclamation stacking, no fabricated proof, no regulated-bank implication.

## Style Guide
**Grammar:** Short sentences. Periods over exclamation points. No growth-hacker slang.
**Capitalization:** Headlines may use title case in print; product/binaries remain exact (`fuego_walletd`, `xfg-swapd`).
**Formatting:** Obsidian background, Champagne Gold primary, Midnight Blue accent, Cream Parchment text.
**Preferred terms:** Exchange, Reserve, Dispatch, Holdings, Ledger, Provenance.

## Proof Points
**Metrics:**
- 12 swap pairs in Dart models (`lib/models/swap_models.dart`).
- 33 EVM/wallet chains listed in `chains.yaml`.
- Desktop/mobile platform coverage documented in `README.md`.
**Customers:** Community project; no customer logos.
**Testimonials:**
> "Built with 🔥 for The Fuego Mob" — README community line (do not use in luxury copy).

| Value Theme | Supporting Proof |
|-------------|-----------------|
| Privacy | CryptoNote lineage, ring-signature documentation in README |
| Cross-chain reach | 12 swap pairs in `lib/models/swap_models.dart` |
| Sovereignty | Local/remote daemon topology in AGENTS.md and README |
| Brand discipline | `assets/brand/design-tokens.json`, `docs/brand/BRAND_GUIDE.md` |

## Content & SEO Context
**Target keywords:**

| Cluster | Primary Keyword | Secondary Keywords | Intent |
|---------|----------------|-------------------|--------|
| Privacy wallet | privacy crypto wallet | CryptoNote wallet, self-custody wallet | informational |
| Atomic swaps | cross-chain atomic swaps | HTLC swap, PTLC swap, private exchange | informational |
| Fuego | Fuego wallet | XFG wallet, Fuego Valise | navigational |
| HEAT flatcoin | purchasing power crypto | inflation-tracking flatcoin, HEAT crypto | informational |

**Internal links map:**

| Page | URL | Use for | Anchor text |
|------|-----|---------|-------------|
| Repo README | `README.md` | product truth baseline | Fuego Valise documentation |
| Brand guide | `docs/brand/BRAND_GUIDE.md` | visual/copy rules | Obsidian Case brand system |
| Teaser doc | `docs/marketing/HEATWAVE_TEASER.md` | campaign fiction disclaimer | Heatwave teaser |

**Writing examples:**
- `docs/marketing/HEATWAVE_TEASER.md` — house voice draft, requires disclaimers and truth edits.

## Goals
**Business goal:** Build anticipation for a future Heatwave-branded release preview without misleading users about shipping status.
**Conversion action:** Join official Fuego channels / watch for release notes / read teaser hub.
**Current metrics:** Not instrumented in repo; campaign measurement plan required.
