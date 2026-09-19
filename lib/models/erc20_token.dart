// ERC20 token registry for EVM chains.
// Addresses verified against mainnet deployments 2025-2026. Decimals are
// queried at runtime via decimals() as source of truth — these defaults
// only seed UI formatting before the first RPC succeeds.

import 'chain_registry.g.dart';



/// Canonical EVM chain key used by Web3MultiChainService.
enum EvmChainKey {
  eth('eth', 1),
  arb('arb', 42161),
  base('base', 8453),
  bsc('bsc', 56),
  poly('poly', 137),
  op('op', 10),
  avax('avax', 43114),
  cro('cro', 25),
  monad('monad', 143),
  xpl('xpl', 9745),
  pls('pls', 369),
  uni('uni', 130),
  rh('rh', 4663),
  bob('bob', 60808),
  gleec('gleec', 11169),
  linea('linea', 59144),
  zksync('zksync', 324),
  hyperevm('hyperevm', 999),
  ink('ink', 57073),
  rsk('rsk', 30),
  gnosis('gnosis', 100),
  flare('flare', 14),
  kaia('kaia', 8217),
  scroll('scroll', 534352),
  abstract('abstract', 2741),
  plume('plume', 98866),
  soneium('soneium', 1868),
  doma('doma', 97477),
  beam('beam', 4337),
  moonriver('moonriver', 1285),
  peaq('peaq', 3338),
  tempo('tempo', 4217),
  sei('sei', 1329);

  final String key;
  final int chainId;
  const EvmChainKey(this.key, this.chainId);

  static EvmChainKey? fromKey(String k) {
    for (final v in values) {
      if (v.key == k.toLowerCase()) return v;
    }
    return null;
  }
}

/// Single ERC20 token definition.
class Erc20Token {
  final String address; // 0x checksum or lowercase — both accepted
  final String symbol;
  final String name;
  final int decimals; // expected decimals — runtime query may override
  final EvmChainKey chain;
  final bool isNativeStable; // true for canonical USDT/USDC on that chain

  const Erc20Token({
    required this.address,
    required this.symbol,
    required this.name,
    required this.decimals,
    required this.chain,
    this.isNativeStable = true,
  });

  String get chainKey => chain.key;
  int get chainId => chain.chainId;

  /// Lowercase address for comparison.
  String get lcAddress => address.toLowerCase();

  Map<String, dynamic> toJson() => {
        'address': address,
        'symbol': symbol,
        'name': name,
        'decimals': decimals,
        'chain': chainKey,
        'chainId': chainId,
      };

  @override
  bool operator ==(Object other) =>
      other is Erc20Token &&
      other.lcAddress == lcAddress &&
      other.chain == chain;

  @override
  int get hashCode => Object.hash(lcAddress, chain);

  @override
  String toString() => '$symbol@$chainKey:$address';
}

/// Registry of well-known tokens per EVM chain.
///
/// Contract addresses are mainnet. For bridged variants the canonical
/// native stable is listed first. Entries that are not dollar stables carry
/// `isNativeStable: false`.
class Erc20Registry {
  // ETH mainnet
  static const usdtEth = Erc20Token(
    address: '0xdAC17F958D2ee523a2206206994597C13D831ec7',
    symbol: 'USDT',
    name: 'Tether USD',
    decimals: 6,
    chain: EvmChainKey.eth,
  );
  static const usdcEth = Erc20Token(
    address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
    symbol: 'USDC',
    name: 'USD Coin',
    decimals: 6,
    chain: EvmChainKey.eth,
  );

  // Arbitrum One
  static const usdtArb = Erc20Token(
    address: '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9',
    symbol: 'USDT',
    name: 'Tether USD (Arb)',
    decimals: 6,
    chain: EvmChainKey.arb,
  );
  static const usdcArb = Erc20Token(
    address: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831',
    symbol: 'USDC',
    name: 'USD Coin (Arb)',
    decimals: 6,
    chain: EvmChainKey.arb,
  );
  static const usdcArbNative = Erc20Token(
    address: '0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8',
    symbol: 'USDC.e',
    name: 'USD Coin (Bridged)',
    decimals: 6,
    chain: EvmChainKey.arb,
    isNativeStable: false,
  );

  // Base
  static const usdcBase = Erc20Token(
    address: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
    symbol: 'USDC',
    name: 'USD Coin (Base)',
    decimals: 6,
    chain: EvmChainKey.base,
  );
  static const usdtBase = Erc20Token(
    address: '0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2',
    symbol: 'USDT',
    name: 'Tether USD (Base)',
    decimals: 6,
    chain: EvmChainKey.base,
  );

  // Venice AI (VVV) on Base — not a stablecoin. Access token for private
  // inference through the Venice API; 18 decimals, verified on BaseScan at
  // https://basescan.org/token/0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf
  static const vvvBase = Erc20Token(
    address: '0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf',
    symbol: 'VVV',
    name: 'Venice Token',
    decimals: 18,
    chain: EvmChainKey.base,
    isNativeStable: false,
  );

  // BNB Chain — BEP20 stablecoins use 18 decimals on BSC
  static const usdtBsc = Erc20Token(
    address: '0x55d398326f99059fF775485246999027B3197955',
    symbol: 'USDT',
    name: 'Tether USD (BSC)',
    decimals: 18,
    chain: EvmChainKey.bsc,
  );
  static const usdcBsc = Erc20Token(
    address: '0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d',
    symbol: 'USDC',
    name: 'USD Coin (BSC)',
    decimals: 18,
    chain: EvmChainKey.bsc,
  );

  // Polygon PoS
  static const usdtPoly = Erc20Token(
    address: '0xc2132D05D31c914a87C6611C10748AEb04B58e8F',
    symbol: 'USDT',
    name: 'Tether USD (Polygon)',
    decimals: 6,
    chain: EvmChainKey.poly,
  );
  static const usdcPoly = Erc20Token(
    address: '0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359',
    symbol: 'USDC',
    name: 'USD Coin (Polygon)',
    decimals: 6,
    chain: EvmChainKey.poly,
  );

  // OP Mainnet
  static const usdtOp = Erc20Token(
    address: '0x94b008aA00579c1307B0EF2c499aD98a8ce58e58',
    symbol: 'USDT',
    name: 'Tether USD (OP)',
    decimals: 6,
    chain: EvmChainKey.op,
  );
  static const usdcOp = Erc20Token(
    address: '0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85',
    symbol: 'USDC',
    name: 'USD Coin (OP)',
    decimals: 6,
    chain: EvmChainKey.op,
  );
  static const usdcOpBridged = Erc20Token(
    address: '0x7F5c764cBc14f9669B88837ca1490cCa17c31607',
    symbol: 'USDC.e',
    name: 'USD Coin (Bridged, OP)',
    decimals: 6,
    chain: EvmChainKey.op,
    isNativeStable: false,
  );

  // Avalanche C-Chain
  static const usdtAvax = Erc20Token(
    address: '0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7',
    symbol: 'USDT',
    name: 'Tether USD (Avalanche)',
    decimals: 6,
    chain: EvmChainKey.avax,
  );
  static const usdcAvax = Erc20Token(
    address: '0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E',
    symbol: 'USDC',
    name: 'USD Coin (Avalanche)',
    decimals: 6,
    chain: EvmChainKey.avax,
  );

  // Cronos — native Circle USDC launched Jun 2026; old bridged relabeled USDC.e
  static const usdtCro = Erc20Token(
    address: '0x66e428c3f67a68878562e79A0234c1F83c208770',
    symbol: 'USDT',
    name: 'Tether USD (Cronos)',
    decimals: 6,
    chain: EvmChainKey.cro,
  );
  static const usdcCro = Erc20Token(
    address: '0x3D7F2C478aAfdB65542BCB44bCeeC05849999d2D',
    symbol: 'USDC',
    name: 'USD Coin (Cronos)',
    decimals: 6,
    chain: EvmChainKey.cro,
  );

  // Monad — USDT is the LayerZero OFT "USDT0"
  static const usdcMonad = Erc20Token(
    address: '0x754704Bc059F8C67012fEd69BC8A327a5aafb603',
    symbol: 'USDC',
    name: 'USD Coin (Monad)',
    decimals: 6,
    chain: EvmChainKey.monad,
  );
  static const usdt0Monad = Erc20Token(
    address: '0xe7cd86e13AC4309349F30B3435a9d337750fC82D',
    symbol: 'USDT0',
    name: 'Tether USD (Monad, OFT)',
    decimals: 6,
    chain: EvmChainKey.monad,
  );

  // Plasma (XPL) — native Tether-issued USDT0, zero-gas P2P transfers
  static const usdt0Xpl = Erc20Token(
    address: '0xb8ce59fc3717ada4c02eadf9682a9e934f625ebb',
    symbol: 'USDT0',
    name: 'Tether USD (Plasma)',
    decimals: 6,
    chain: EvmChainKey.xpl,
  );

  // PulseChain — ONLY the redeemable bridged versions; forked pUSDT/pUSDC
  // carry no real-world value and must never be listed.
  static const eusdtPls = Erc20Token(
    address: '0x0cb6f5a34ad42ec934882a05265a7d5f59b51a2f',
    symbol: 'eUSDT',
    name: 'Tether USD (Bridged to PulseChain)',
    decimals: 6,
    chain: EvmChainKey.pls,
  );
  static const eusdcPls = Erc20Token(
    address: '0x15d38573d2feeb82e7ad5187ab8c1d52810b1f07',
    symbol: 'eUSDC',
    name: 'USD Coin (Bridged to PulseChain)',
    decimals: 6,
    chain: EvmChainKey.pls,
  );

  // Unichain
  static const usdcUni = Erc20Token(
    address: '0x078D782b760474a361dDA0AF3839290b0EF57AD6',
    symbol: 'USDC',
    name: 'USD Coin (Unichain)',
    decimals: 6,
    chain: EvmChainKey.uni,
  );
  static const usdt0Uni = Erc20Token(
    address: '0x9151434b16b9763660705744891fa906f660ecc5',
    symbol: 'USDT0',
    name: 'Tether USD (Unichain, OFT)',
    decimals: 6,
    chain: EvmChainKey.uni,
  );

  // Robinhood Chain — Paxos USDG is the canonical dollar stable there;
  // USDT/USDC not confirmed on-chain yet.
  static const usdgRh = Erc20Token(
    address: '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168',
    symbol: 'USDG',
    name: 'Global Dollar (Robinhood Chain)',
    decimals: 6,
    chain: EvmChainKey.rh,
  );

  // Linea / ZKsync Era — Circle-verified native USDC
  static const usdcLinea = Erc20Token(
    address: '0x176211869cA2b568f2A7D4EE941E073a821EE1ff',
    symbol: 'USDC',
    name: 'USD Coin (Linea)',
    decimals: 6,
    chain: EvmChainKey.linea,
  );
  static const usdcZksync = Erc20Token(
    address: '0x1d17CBcF0D6D143135aE902365D2E5e2A16538D4',
    symbol: 'USDC',
    name: 'USD Coin (ZKsync Era)',
    decimals: 6,
    chain: EvmChainKey.zksync,
  );

  // OpenUSDT (oUSDT) — Velodrome/Chainlink/Hyperlane collab. SuperchainERC20
  // standard means the SAME address on every OP-stack chain. Backed 1:1 with
  // native USDT locked on Ethereum + Celo; CCIP + Hyperlane secured.
  // Verified deployments per docs.openusdt.xyz among our chains:
  static const _ousdtAddress = '0x1217BfE6c773EEC6cc4A38b5Dc45B92292B6E189';
  static const ousdtOp = Erc20Token(
    address: _ousdtAddress,
    symbol: 'oUSDT',
    name: 'OpenUSDT (Optimism)',
    decimals: 6,
    chain: EvmChainKey.op,
    isNativeStable: false,
  );
  static const ousdtBase = Erc20Token(
    address: _ousdtAddress,
    symbol: 'oUSDT',
    name: 'OpenUSDT (Base)',
    decimals: 6,
    chain: EvmChainKey.base,
    isNativeStable: false,
  );
  static const ousdtBob = Erc20Token(
    address: _ousdtAddress,
    symbol: 'oUSDT',
    name: 'OpenUSDT (BOB)',
    decimals: 6,
    chain: EvmChainKey.bob,
    isNativeStable: false,
  );
  static const ousdtUni = Erc20Token(
    address: _ousdtAddress,
    symbol: 'oUSDT',
    name: 'OpenUSDT (Unichain)',
    decimals: 6,
    chain: EvmChainKey.uni,
    isNativeStable: false,
  );
  static const ousdtInk = Erc20Token(
    address: _ousdtAddress,
    symbol: 'oUSDT',
    name: 'OpenUSDT (Ink)',
    decimals: 6,
    chain: EvmChainKey.ink,
    isNativeStable: false,
  );

  // HyperEVM / Ink / Plume — Circle-verified native USDC
  static const usdcHyperEvm = Erc20Token(
    address: '0xb88339CB7199b77E23DB6E890353E22632Ba630f',
    symbol: 'USDC',
    name: 'USD Coin (HyperEVM)',
    decimals: 6,
    chain: EvmChainKey.hyperevm,
  );
  static const usdcInk = Erc20Token(
    address: '0x2D270e6886d130D724215A266106e6832161EAEd',
    symbol: 'USDC',
    name: 'USD Coin (Ink)',
    decimals: 6,
    chain: EvmChainKey.ink,
  );
  static const usdcPlume = Erc20Token(
    address: '0x222365EF19F7947e5484218551B56bb3965Aa7aF',
    symbol: 'USDC',
    name: 'USD Coin (Plume)',
    decimals: 6,
    chain: EvmChainKey.plume,
  );

  // Soneium — Sony OP-Stack L2 (1868), bridged stables + oUSDT mesh
  static const usdtSoneium = Erc20Token(
    address: '0x3A337a6adA9d885b6Ad95ec48F9b75f197b5AE35',
    symbol: 'USDT',
    name: 'Tether USD (Soneium)',
    decimals: 6,
    chain: EvmChainKey.soneium,
  );
  static const usdcSoneiumBridged = Erc20Token(
    address: '0xbA9986D2381edf1DA03B0B9c1f8b00dc4AacC369',
    symbol: 'USDC.e',
    name: 'USD Coin (Bridged, Soneium)',
    decimals: 6,
    chain: EvmChainKey.soneium,
    isNativeStable: false,
  );
  static const ousdtSoneium = Erc20Token(
    address: _ousdtAddress,
    symbol: 'oUSDT',
    name: 'OpenUSDT (Soneium)',
    decimals: 6,
    chain: EvmChainKey.soneium,
    isNativeStable: false,
  );

  // Sei — native Circle USDC (1329)
  static const usdcSei = Erc20Token(
    address: '0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392',
    symbol: 'USDC',
    name: 'USD Coin (Sei)',
    decimals: 6,
    chain: EvmChainKey.sei,
  );

  // Rootstock, Gnosis, Flare, Kaia, Scroll, Abstract, Doma, Beam,
  // Moonriver, peaq, Tempo: chains registered for custom-token use; no
  // stablecoin contract verified at registry-authoring time — add via Add Token
  // UI. Tempo has no native gas token (eth_getBalance returns constant).

  static const List<Erc20Token> all = [
    usdtEth, usdcEth,
    usdtArb, usdcArb, usdcArbNative,
    usdcBase, usdtBase, ousdtBase, vvvBase,
    usdtBsc, usdcBsc,
    usdtPoly, usdcPoly,
    usdtOp, usdcOp, usdcOpBridged, ousdtOp,
    usdtAvax, usdcAvax,
    usdtCro, usdcCro,
    usdcMonad, usdt0Monad,
    usdt0Xpl,
    eusdtPls, eusdcPls,
    usdcUni, usdt0Uni, ousdtUni,
    usdgRh,
    usdcLinea, usdcZksync,
    usdcHyperEvm,
    usdcInk, ousdtInk,
    ousdtBob,
    usdcPlume,
    usdtSoneium, usdcSoneiumBridged, ousdtSoneium,
    usdcSei,
  ];

  static List<Erc20Token> forChain(String chainKey) {
    final k = chainKey.toLowerCase();
    return all.where((t) => t.chainKey == k).toList();
  }

  static List<Erc20Token> forChainKey(EvmChainKey chain) =>
      all.where((t) => t.chain == chain).toList();

  static Erc20Token? find(String chainKey, String symbol) {
    final k = chainKey.toLowerCase();
    final s = symbol.toUpperCase();
    for (final t in all) {
      if (t.chainKey == k && t.symbol.toUpperCase() == s) return t;
    }
    return null;
  }

  static Erc20Token? findByAddress(String chainKey, String address) {
    final k = chainKey.toLowerCase();
    final a = address.toLowerCase();
    for (final t in all) {
      if (t.chainKey == k && t.lcAddress == a) return t;
    }
    return null;
  }

  /// Every EVM chain key the wallet can talk to. Not every one of these has
  /// a registry token — several are chain-only until a contract is verified.
  static List<String> get supportedChainKeys =>
      EvmChainKey.values.map((e) => e.key).toList();

  /// Human display label for chain key.
  ///
  /// Names come from the generated chain registry (chains.yaml). Unknown
  /// keys fall back to an uppercased key, matching the old switch default.
  static String displayNameFor(String chainKey) =>
      kChainNames[chainKey.toLowerCase()] ?? chainKey.toUpperCase();
}

/// Amount helpers for ERC20 integer <-> display conversion.
class Erc20Amount {
  /// Convert display string (e.g. "1.5") to base units BigInt.
  static BigInt toBaseUnits(String display, int decimals) {
    final clean = display.trim();
    if (clean.isEmpty) return BigInt.zero;
    final parts = clean.split('.');
    final whole = BigInt.parse(parts[0].isEmpty ? '0' : parts[0]);
    final fracStr = parts.length > 1 ? parts[1] : '';
    final padded = (fracStr + '0' * decimals).substring(0, decimals);
    final frac = padded.isEmpty ? BigInt.zero : BigInt.parse(padded);
    final base = BigInt.from(10).pow(decimals);
    return whole * base + (whole.isNegative ? -frac : frac);
  }

  /// Convert base units BigInt to display string with [decimals].
  static String fromBaseUnits(BigInt baseUnits, int decimals) {
    if (decimals == 0) return baseUnits.toString();
    final base = BigInt.from(10).pow(decimals);
    final whole = baseUnits ~/ base;
    final frac = (baseUnits.remainder(base).abs()).toString().padLeft(decimals, '0');
    final trimmed = frac.replaceAll(RegExp(r'0+$'), '');
    if (trimmed.isEmpty) return whole.toString();
    return '${whole.toString()}.$trimmed';
  }

  static double toDouble(BigInt baseUnits, int decimals) {
    if (decimals == 0) return baseUnits.toDouble();
    return baseUnits.toDouble() / BigInt.from(10).pow(decimals).toDouble();
  }
}
