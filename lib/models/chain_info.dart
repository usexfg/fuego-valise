import 'dart:ui';

import 'chain_registry.g.dart';

/// Chain display metadata shared by the DEX marketplace (Orderbook/Trade/
/// Trades) and the Peer Swap section.
class ChainInfo {
  /// Display names.
  ///
  /// Canonical per-chain names are GENERATED from chains.yaml
  /// ([kChainNames], lowercase keys). The legacy UPPERCASE ticker aliases
  /// below are kept verbatim — the DEX UI keys by ticker ('MON', 'RHC',
  /// 'ZKS', …) while the ERC20 layer keys by chain key ('monad', 'rh',
  /// 'zksync', …). Both coexist: no key collision across cases.
  static final Map<String, String> names = {
    ...kChainNames,
    'BTC': 'Bitcoin',
    'LTC': 'Litecoin',
    'KMD': 'Komodo',
    'BCH': 'Bitcoin Cash',
    'ETH': 'Ethereum',
    'ARB': 'Arbitrum',
    'BASE': 'Base(ETH)',
    'BNB': 'BNB Chain',
    'SOL': 'Solana',
    'POLY': 'Polygon',
    'DCR': 'Decred',
    'XMR': 'Monero',
    'XFG': 'Fuego (Native)',
    'AVAX': 'Avalanche',
    'BOB': 'Bank of Bitcoin',
    'CRO': 'Cronos',
    'DASH': 'Dash',
    'DOGE': 'Dogecoin',
    'MON': 'Monad',
    'OP': 'Optimism',
    'PLS': 'Pulsechain',
    'RHC': 'Robinhood Chain(ETH)',
    'UNI': 'Unichain',
    'XPL': 'Plasma',
    'ZANO': 'Zano',
    'ZEC': 'Zcash',
    // ── DeXFG wallet-tier EVM expansion (33-chain ERC20 layer) ──
    'LINEA': 'Linea',
    'ZKS': 'ZKsync Era',
    'HYPER': 'HyperEVM',
    'INK': 'Ink',
    'RSK': 'Rootstock',
    'GNO': 'Gnosis',
    'FLR': 'Flare',
    'KAIA': 'Kaia',
    'SCR': 'Scroll',
    'ABS': 'Abstract',
    'PLUME': 'Plume',
    'SONEIUM': 'Soneium',
    'DOMA': 'Doma',
    'BEAM': 'Beam',
    'MOVR': 'Moonriver',
    'PEAQ': 'peaq',
    'TEMPO': 'Tempo',
    'SEI': 'Sei',
    'GLEEC': 'Gleec Chain',
  };

  static const Map<String, String> desc = {
    'BTC': 'Digital gold — the original UTXO chain with deepest liquidity.',
    'LTC': 'Fast, lightweight Bitcoin fork with low fees and mature SPV.',
    'KMD': 'Komodo — delayed PoW with built-in atomic swap support.',
    'BCH': 'Bitcoin Cash — high-throughput UTXO chain for everyday payments.',
    'ETH': 'Smart contract platform — largest DeFi ecosystem.',
    'ARB': 'Arbitrum — Ethereum L2 with fast finality and low gas.',
    'BASE': 'Base — Coinbase L2 on the OP Stack, fast and cheap.',
    'BNB': 'BNB Chain — EVM-compatible, high throughput, low fees.',
    'POLY': 'Polygon — Ethereum sidechain with fast 2s blocks.',
    'AVAX': 'Avalanche — EVM C-Chain with sub-second finality and low fees.',
    'GLEEC': 'Gleec Chain — EVM-compatible network for low-cost transfers.',
    'RHC': 'Robinhood Chain — EVM L1 using ETH for transaction fees.',
    'CRO': 'Cronos — EVM-compatible network in the Crypto.com ecosystem.',
    'BOB': 'BOB — OP Stack Bitcoin rollup with EVM smart contracts.',
    'UNI': 'Unichain — OP Stack L2 optimized for on-chain markets.',
    'XPL': 'Plasma — EVM network focused on stablecoin payments.',
    'PLS': 'PulseChain — EVM-compatible network with low transaction fees.',
    'MON': 'Monad — high-throughput EVM L1 with parallel execution.',
    'OP': 'Optimism — OP Stack Ethereum L2 with low-cost execution.',
    'SOL': 'Solana — high-performance non-EVM chain with sub-second slots.',
    'DCR': 'Decred — hybrid PoW/PoS with built-in governance and Neutrino SPV.',
    'XMR': 'Monero — privacy coin using ring signatures and stealth addresses.',
    'XFG': 'Fuego  - Private Banking & Purchasing Power Chain',
  };

  static const Map<String, Map<String, String>> info = {
    'BTC': {
      'type': 'UTXO',
      'connect': 'Electrum SPV (public servers)',
      'user': 'No setup needed. Full node only for advanced RPC mode.',
      'htlc': 'P2WSH SegWit',
    },
    'LTC': {
      'type': 'UTXO',
      'connect': 'Electrum SPV (public servers)',
      'user': 'No setup needed. Full node only for advanced RPC mode.',
      'htlc': 'P2WSH SegWit',
    },
    'KMD': {
      'type': 'UTXO',
      'connect': 'Electrum SPV (public servers)',
      'user': 'No setup needed. Full node only for advanced RPC mode.',
      'htlc': 'P2SH',
    },
    'BCH': {
      'type': 'UTXO',
      'connect': 'Electrum SPV (public servers)',
      'user': 'No setup needed. Full node only for advanced RPC mode.',
      'htlc': 'P2SH',
    },
    'ETH': {
      'type': 'EVM',
      'connect': 'Ethereum JSON-RPC (Infura/Alchemy)',
      'user': 'No setup needed — public RPC used by default.',
      'htlc': 'HashedTimelock.sol',
    },
    'ARB': {
      'type': 'EVM L2',
      'connect': 'Arbitrum JSON-RPC',
      'user': 'No setup needed — public RPC used by default.',
      'htlc': 'HashedTimelock.sol',
    },
    'BASE': {
      'type': 'EVM L2',
      'connect': 'Base JSON-RPC',
      'user': 'No setup needed — public RPC used by default.',
      'htlc': 'HashedTimelock.sol',
    },
    'BNB': {
      'type': 'EVM',
      'connect': 'BSC JSON-RPC',
      'user': 'No setup needed — public RPC used by default.',
      'htlc': 'HashedTimelock.sol',
    },
    'POLY': {
      'type': 'EVM',
      'connect': 'Polygon JSON-RPC',
      'user': 'No setup needed — public RPC used by default.',
      'htlc': 'HashedTimelock.sol',
    },
    'SOL': {
      'type': 'Non-EVM',
      'connect': 'Solana JSON-RPC (public)',
      'user': 'No setup needed — public RPC used by default.',
      'htlc': 'On-chain HTLC program',
    },
    'DCR': {
      'type': 'UTXO',
      'connect': 'Neutrino SPV (built-in) or dcrd RPC',
      'user': 'No setup needed for SPV mode.',
      'htlc': 'P2SH',
    },
    'XMR': {
      'type': 'CryptoNote',
      'connect': 'monerod + monero-wallet-rpc',
      'user':
          'Run your own node (recommended) or use a remote node from monero.fail.',
      'htlc': 'Ring signatures + adaptor sigs',
    },
    'XFG': {
      'type': 'CryptoNote (Native)',
      'connect': 'Embedded fuegod daemon',
      'user': 'Built into the wallet — no setup needed.',
      'htlc': 'Ring signatures + adaptor sigs',
    },
    'AVAX': {
      'type': 'EVM',
      'connect': 'Avalanche JSON-RPC',
      'user': 'Public RPC used by default — set a funded key in Swap Settings.',
      'htlc': 'HashedTimelock.sol',
    },
    'GLEEC': {
      'type': 'EVM',
      'connect': 'Gleec JSON-RPC',
      'user': 'Public RPC used by default — set a funded key in Swap Settings.',
      'htlc': 'HashedTimelock.sol',
    },
    'RHC': {
      'type': 'EVM',
      'connect': 'Robinhood Chain JSON-RPC',
      'user': 'Public RPC used by default — set a funded key in Swap Settings.',
      'htlc': 'HashedTimelock.sol',
    },
    'CRO': {
      'type': 'EVM',
      'connect': 'Cronos JSON-RPC',
      'user': 'Public RPC used by default — set a funded key in Swap Settings.',
      'htlc': 'HashedTimelock.sol',
    },
    'BOB': {
      'type': 'EVM L2',
      'connect': 'BOB JSON-RPC',
      'user': 'Public RPC used by default — set a funded key in Swap Settings.',
      'htlc': 'HashedTimelock.sol',
    },
    'UNI': {
      'type': 'EVM L2',
      'connect': 'Unichain JSON-RPC',
      'user': 'Public RPC used by default — set a funded key in Swap Settings.',
      'htlc': 'HashedTimelock.sol',
    },
    'XPL': {
      'type': 'EVM',
      'connect': 'Plasma JSON-RPC',
      'user': 'Public RPC used by default — set a funded key in Swap Settings.',
      'htlc': 'HashedTimelock.sol',
    },
    'PLS': {
      'type': 'EVM',
      'connect': 'PulseChain JSON-RPC',
      'user': 'Public RPC used by default — set a funded key in Swap Settings.',
      'htlc': 'HashedTimelock.sol',
    },
    'MON': {
      'type': 'EVM',
      'connect': 'Monad JSON-RPC',
      'user': 'Public RPC used by default — set a funded key in Swap Settings.',
      'htlc': 'HashedTimelock.sol',
    },
    'OP': {
      'type': 'EVM L2',
      'connect': 'Optimism JSON-RPC',
      'user': 'Public RPC used by default — set a funded key in Swap Settings.',
      'htlc': 'HashedTimelock.sol',
    },
    'DASH': {'type': 'UTXO', 'wired': 'false'},
    'DOGE': {'type': 'UTXO', 'wired': 'false'},
    'ZANO': {'type': 'CryptoNote', 'wired': 'false'},
    'ZEC': {'type': 'UTXO', 'wired': 'false'},
  };

  /// PTLC descriptor per chain (point commitment / adaptor).
  static const Map<String, String> ptlc = {
    'BTC': 'P2WSH point commitment (Taproot scriptless Phase2)',
    'LTC': 'P2WSH point commitment',
    'SOL': 'ed25519 adaptor ClaimPtlc (Phase4) — now BRIDGE',
    'ETH': 'HashedTimelock + PtlcLocked event (BRIDGE)',
    'ARB': 'HashedTimelock + PtlcLocked event (BRIDGE)',
    'BASE': 'HashedTimelock + PtlcLocked event (BRIDGE)',
    'BNB': 'HashedTimelock + PtlcLocked event (BRIDGE)',
    'POLY': 'HashedTimelock + PtlcLocked event (BRIDGE)',
    'AVAX': 'HashedTimelock + PtlcLocked event (BRIDGE)',
    'GLEEC': 'HashedTimelock + PtlcLocked event (BRIDGE)',
    'RHC': 'HashedTimelock + PtlcLocked event (BRIDGE)',
    'CRO': 'HashedTimelock + PtlcLocked event (BRIDGE)',
    'BOB': 'HashedTimelock + PtlcLocked event (BRIDGE)',
    'UNI': 'HashedTimelock + PtlcLocked event (BRIDGE)',
    'XPL': 'HashedTimelock + PtlcLocked event (BRIDGE)',
    'PLS': 'HashedTimelock + PtlcLocked event (BRIDGE)',
    'MON': 'HashedTimelock + PtlcLocked event (BRIDGE)',
    'OP': 'HashedTimelock + PtlcLocked event (BRIDGE)',
    'BCH': 'HashedTimelock + DLEQ bridge',
    'XMR': 'native adaptor (no HTLC)',
    'ZANO': 'native adaptor (no HTLC)',
    'XFG': 'MuSig2 adaptor T=t*G (always PTLC)',
  };

  /// Chains where pure PTLC (point) is supported (others use BRIDGE).
  static const Set<String> supportsPtlc = {'BTC', 'LTC', 'XMR', 'ZANO'};

  static bool isPtlcSupported(String ticker) => supportsPtlc.contains(ticker);

  static const Map<String, int> decimals = {
    'BTC': 8, 'LTC': 8, 'BCH': 8, 'KMD': 8, 'DCR': 8, 'DASH': 8, 'DOGE': 8, 'ZEC': 8,
    'ETH': 18, 'ARB': 18, 'BASE': 18, 'BNB': 18, 'POLY': 18, 'AVAX': 18, 'GLEEC': 18,
    'RHC': 18, 'CRO': 18, 'BOB': 18, 'UNI': 18, 'XPL': 18, 'PLS': 18, 'MON': 18, 'OP': 18,
    'LINEA': 18, 'ZKS': 18, 'HYPER': 18, 'INK': 18, 'RSK': 18, 'GNO': 18,
    'FLR': 18, 'KAIA': 18, 'SCR': 18, 'ABS': 18, 'PLUME': 18, 'SONEIUM': 18, 'DOMA': 18,
    'BEAM': 18, 'MOVR': 18, 'PEAQ': 18, 'TEMPO': 18, 'SEI': 18,
    'SOL': 9, 'XMR': 12, 'ZANO': 12, 'XFG': 7,
  };

  static const Map<String, String> explorerTx = {
    'BTC': 'https://mempool.space/tx/{txid}',
    'LTC': 'https://litecoinspace.org/tx/{txid}',
    'BCH': 'https://blockchair.com/bitcoin-cash/transaction/{txid}',
    'KMD': 'https://kmdexplorer.io/tx/{txid}',
    'DCR': 'https://dcrdata.decred.org/tx/{txid}',
    'DASH': 'https://blockchair.com/dash/transaction/{txid}',
    'DOGE': 'https://blockchair.com/dogecoin/transaction/{txid}',
    'ZEC': 'https://blockchair.com/zcash/transaction/{txid}',
    'ETH': 'https://etherscan.io/tx/{txid}',
    'ARB': 'https://arbiscan.io/tx/{txid}',
    'BASE': 'https://basescan.org/tx/{txid}',
    'BNB': 'https://bscscan.com/tx/{txid}',
    'POLY': 'https://polygonscan.com/tx/{txid}',
    'AVAX': 'https://snowscan.xyz/tx/{txid}',
    'BOB': 'https://explorer.gobob.xyz/tx/{txid}',
    'CRO': 'https://cronoscan.com/tx/{txid}',
    'SOL': 'https://solscan.io/tx/{txid}',
    'XMR': 'https://xmrchain.net/tx/{txid}',
    'ZANO': 'https://explorer.zano.org/transaction/{txid}',
    'XFG': 'https://explorer.fuego.foundation/tx/{txid}',
  };

  static String explorerTxUrl(String ticker, String txid) {
    final tmpl = explorerTx[ticker];
    if (tmpl == null || txid.isEmpty) return '';
    return tmpl.replaceAll('{txid}', txid);
  }

  static double amountToDecimal(String ticker, int atomic) {
    final d = decimals[ticker] ?? 7;
    return atomic / _pow10(d);
  }

  static double _pow10(int n) {
    double r = 1;
    for (int i = 0; i < n; i++) r *= 10;
    return r;
  }

  /// Brand palette.
  ///
  /// Generated entries from chains.yaml ([kChainColors], lowercase keys,
  /// alpha FF) merged under the legacy UPPERCASE ticker palette kept
  /// verbatim below.
  static final Map<String, Color> colors = {
    for (final e in kChainColors.entries) e.key: Color(0xFF000000 | e.value),
    // Legacy ticker-keyed palette — verbatim.
    'BTC': const Color(0xFFF7931A),
    'LTC': const Color(0xFFBFBBBB),
    'KMD': const Color(0xFF2B6DE9),
    'BCH': const Color(0xFF8DC351),
    'ETH': const Color(0xFF627EEA),
    'ARB': const Color(0xFF28A0F0),
    'BASE': const Color(0xFF0052FF),
    'BNB': const Color(0xFFF0B90B),
    'POLY': const Color(0xFF8247E5),
    'SOL': const Color(0xFF9945FF),
    'DCR': const Color(0xFF2970FF),
    'XMR': const Color(0xFFFF6600),
    'XFG': const Color(0xFFC5A059), // Champagne gold — Obsidian Reserve house
    'AVAX': const Color(0xFFE84142),
    'BOB': const Color(0xFFFF6D00),
    'CRO': const Color(0xFF002D74),
    'DASH': const Color(0xFF008CE7),
    'DOGE': const Color(0xFFC2A633),
    'MON': const Color(0xFF836EF9),
    'OP': const Color(0xFFFF0420),
    'PLS': const Color(0xFF9C27B0),
    'RHC': const Color(0xFF6B7280),
    'UNI': const Color(0xFFFF007A),
    'XPL': const Color(0xFF4FA9E0),
    'ZANO': const Color(0xFF6A5AF9),
    'ZEC': const Color(0xFFF4B728),
    // Wallet-tier expansion colors
    'LINEA': const Color(0xFF61DFFF),
    'ZKS': const Color(0xFF8C8DFC),
    'HYPER': const Color(0xFF97FCE4),
    'INK': const Color(0xFF7132F5),
    'RSK': const Color(0xFFE9B64E),
    'GNO': const Color(0xFF1D6C4E),
    'FLR': const Color(0xFFE6413E),
    'KAIA': const Color(0xFFFF1D01),
    'SCR': const Color(0xFFEBC28E),
    'ABS': const Color(0xFF202020),
    'PLUME': const Color(0xFFFF3D00),
    'SONEIUM': const Color(0xFF937DFF),
    'DOMA': const Color(0xFF4F46E5),
    'BEAM': const Color(0xFF0BDBB5),
    'MOVR': const Color(0xFFF5B700),
    'PEAQ': const Color(0xFF7A2BF5),
    'TEMPO': const Color(0xFF111111),
    'SEI': const Color(0xFF9E1F19),
    'GLEEC': const Color(0xFF00A3C4),
  };

  static const Map<String, String> icons = {
    'BTC': 'assets/coin-icons/btc.png',
    'LTC': 'assets/coin-icons/ltc.png',
    'KMD': 'assets/coin-icons/kmd.png',
    'BCH': 'assets/coin-icons/bch.png',
    'ETH': 'assets/coin-icons/eth.png',
    'ARB': 'assets/coin-icons/arb.png',
    'BASE': 'assets/coin-icons/base.png',
    'BNB': 'assets/coin-icons/bnb.png',
    'POLY': 'assets/coin-icons/matic.png',
    'SOL': 'assets/coin-icons/sol.png',
    'DCR': 'assets/coin-icons/dcr.png',
    'XMR': 'assets/coin-icons/monero.png',
    'XFG': 'assets/coin-icons/xfg.png',
    'AVAX': 'assets/coin-icons/avax.png',
    'BOB': 'assets/coin-icons/bob.png',
    'CRO': 'assets/coin-icons/cronos.png',
    'DASH': 'assets/coin-icons/dash.png',
    'DOGE': 'assets/coin-icons/doge.png',
    'MON': 'assets/coin-icons/monad.png',
    'OP': 'assets/coin-icons/op.jpg',
    'PLS': 'assets/coin-icons/pls.png',
    'RHC': 'assets/coin-icons/rhc.png',
    'UNI': 'assets/coin-icons/uni.png',
    'XPL': 'assets/coin-icons/xpl.png',
    'ZANO': 'assets/coin-icons/zano.png',
    'ZEC': 'assets/coin-icons/zec.png',
    // DeXFG wallet-tier expansion logos
    'LINEA': 'assets/coin-icons/linea.png',
    'ZKS': 'assets/coin-icons/zksync.png',
    'HYPER': 'assets/coin-icons/hyperevm.png',
    'INK': 'assets/coin-icons/ink.png',
    'RSK': 'assets/coin-icons/rootstock.png',
    'GNO': 'assets/coin-icons/gnosis.png',
    'FLR': 'assets/coin-icons/flare.png',
    'KAIA': 'assets/coin-icons/kaia.png',
    'SCR': 'assets/coin-icons/scroll.png',
    'ABS': 'assets/coin-icons/abstract.png',
    'PLUME': 'assets/coin-icons/plume.png',
    'SONEIUM': 'assets/coin-icons/soneium.png',
    'DOMA': 'assets/coin-icons/doma.png',
    'BEAM': 'assets/coin-icons/beam.png',
    'MOVR': 'assets/coin-icons/moonriver.png',
    'PEAQ': 'assets/coin-icons/peaq.png',
    'TEMPO': 'assets/coin-icons/tempo.png',
    'SEI': 'assets/coin-icons/sei.png',
    'GLEEC': 'assets/coin-icons/gleec.png',
  };

  /// Chains a direct peer swap can actually run on (the ones the local
  /// xfg-swapd has chain clients for). Everything else is display-only.
  static const List<String> swapableChains = [
    'BTC',
    'LTC',
    'BCH',
    'KMD',
    'DCR',
    'ETH',
    'ARB',
    'BASE',
    'BNB',
    'POLY',
    'AVAX',
    'GLEEC',
    'RHC',
    'CRO',
    'BOB',
    'UNI',
    'XPL',
    'PLS',
    'MON',
    'OP',
    'SOL',
    'XMR',
  ];

  /// DeXFG 33-chain EVM expansion: live in the wallet's ERC20 layer
  /// (Erc20Service / EvmChainKey — balances, send, approve via Tokens tab)
  /// but NOT wired into xfg-swapd, so no CLI swaps.
  ///
  /// DERIVED from chains.yaml ([kWalletTierKeys]) — uppercased to match
  /// the ticker-keyed convention of this class. Icon files pending;
  /// UI falls back to [colors] letter-marks until real logos land.
  static final Set<String> walletOnlyChains =
      kWalletTierKeys.map((k) => k.toUpperCase()).toSet();
}
