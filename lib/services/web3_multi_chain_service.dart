import 'dart:developer' as dev;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:web3dart/web3dart.dart';
import 'package:solana/solana.dart' as solana;
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart' as solana_encoder;
import '../models/chain_registry.g.dart';
import '../models/erc20_token.dart';
import 'erc20_service.dart';

class Web3MultiChainService {
  Web3Client? _ethClient;
  solana.RpcClient? _solRpcClient;
  String _ethRpcUrl;
  String _solRpcUrl;

  // Per-chain EVM clients — fixes single-client bug where getEvmBalance(chain:'poly')
  // still queried ETH mainnet. Keys: eth/arb/base/bsc/poly.
  final Map<String, Web3Client> _evmClients = {};
  final Map<String, String> _evmRpcUrls = {};
  Erc20Service? _erc20;
  Erc20Service get erc20 {
    _erc20 ??= Erc20Service(rpcUrls: Map<String, String>.from(_evmRpcUrls));
    return _erc20!;
  }

  // Canonical defaults — generated from chains.yaml via tool/gen_chains.dart.
  // Getters (not consts): Dart can't const-index into a map literal.
  // defaultSolRpc stays hand-written: Solana is outside the EvmChainKey set.
  static String get defaultEthRpc => kChainRpcs['eth']!;
  static String get defaultArbRpc => kChainRpcs['arb']!;
  static String get defaultBaseRpc => kChainRpcs['base']!;
  static String get defaultBscRpc => kChainRpcs['bsc']!;
  static String get defaultPolyRpc => kChainRpcs['poly']!;
  static const defaultSolRpc = 'https://api.mainnet-beta.solana.com';

  /// Canonical EVM chain ids for all 33 supported chains (generated).
  static Map<String, int> get chainIds => kChainIds;

  /// Default per-chain RPC endpoints (generated from chains.yaml).
  static const Map<String, String> _defaultEvmRpcs = kChainRpcs;

  Web3MultiChainService({String ethRpcUrl = '', String solRpcUrl = ''})
      : _ethRpcUrl = ethRpcUrl.isEmpty ? defaultEthRpc : ethRpcUrl,
        _solRpcUrl = solRpcUrl.isEmpty ? defaultSolRpc : solRpcUrl {
    _ethClient = Web3Client(_ethRpcUrl, http.Client());
    _solRpcClient = solana.RpcClient(_solRpcUrl);
    for (final e in _defaultEvmRpcs.entries) {
      final url = e.key == 'eth' ? _ethRpcUrl : e.value;
      _evmRpcUrls[e.key] = url;
      _evmClients[e.key] = e.key == 'eth' ? _ethClient! : Web3Client(url, http.Client());
    }
    _erc20 = Erc20Service(rpcUrls: Map<String, String>.from(_evmRpcUrls));
  }

  Web3Client _evmClientFor(String chain) {
    final k = chain.toLowerCase();
    return _evmClients[k] ?? _ethClient!;
  }

  void setEthRpc(String rpcUrl) {
    _ethRpcUrl = rpcUrl.isEmpty ? defaultEthRpc : rpcUrl;
    _ethClient?.dispose();
    _ethClient = Web3Client(_ethRpcUrl, http.Client());
    // Keep per-chain map in sync — eth key is canonical for ETH mainnet
    _evmClients['eth']?.dispose();
    _evmClients['eth'] = _ethClient!;
    _evmRpcUrls['eth'] = _ethRpcUrl;
    _erc20?.setRpcUrl('eth', _ethRpcUrl);
  }

  /// Set RPC for a specific EVM chain (eth/arb/base/bsc/poly). Falls back to
  /// [setEthRpc] when chain == 'eth' for backward compat.
  void setEvmRpc(String chain, String rpcUrl) {
    final k = chain.toLowerCase();
    if (k == 'eth') {
      setEthRpc(rpcUrl);
      return;
    }
    final defaults = _defaultEvmRpcs[k];
    final url = rpcUrl.isEmpty ? (defaults ?? rpcUrl) : rpcUrl;
    if (url.isEmpty) return;
    _evmClients[k]?.dispose();
    _evmRpcUrls[k] = url;
    _evmClients[k] = Web3Client(url, http.Client());
    _erc20?.setRpcUrl(k, url);
  }

  void setSolRpc(String rpcUrl) {
    _solRpcUrl = rpcUrl.isEmpty ? defaultSolRpc : rpcUrl;
    _solRpcClient = solana.RpcClient(_solRpcUrl);
  }

  int getChainId(String chain) => chainIds[chain.toLowerCase()] ?? 1;

  Future<double> getEthBalance(String address) async {
    try {
      final balance = await _evmClientFor('eth').getBalance(EthereumAddress.fromHex(address));
      return balance.getValueInUnit(EtherUnit.ether);
    } catch (e) {
      dev.log('Error fetching ETH balance: $e');
      return 0.0;
    }
  }

  Future<double> getEvmBalance(String address, {String chain = 'eth'}) async {
    // Tempo has no native gas token — eth_getBalance returns a constant fake
    // (0x9612...26c9). Report 0 and use TIP-20 balances via Erc20Service instead.
    if (chain.toLowerCase() == 'tempo') {
      dev.log('Tempo has no native balance — use TIP-20 token balances');
      return 0.0;
    }
    try {
      final client = _evmClientFor(chain);
      final balance = await client.getBalance(EthereumAddress.fromHex(address));
      return balance.getValueInUnit(EtherUnit.ether);
    } catch (e) {
      dev.log('Error fetching $chain balance: $e');
      return 0.0;
    }
  }

  // ── ERC20 delegation (USDT/USDC via Erc20Service) ──────────────────

  Future<BigInt> getErc20Balance({
    required String holderAddress,
    required String tokenAddress,
    String chain = 'eth',
  }) =>
      erc20.balanceOf(chainKey: chain, tokenAddress: tokenAddress, holderAddress: holderAddress);

  Future<double> getErc20BalanceAsDouble({
    required String holderAddress,
    required Erc20Token token,
  }) =>
      erc20.balanceAsDouble(token: token, holderAddress: holderAddress);

  Future<int> getErc20Decimals({required String tokenAddress, String chain = 'eth'}) =>
      erc20.decimals(chainKey: chain, tokenAddress: tokenAddress);

  Future<BigInt> getErc20Allowance({
    required String owner,
    required String spender,
    required String tokenAddress,
    String chain = 'eth',
  }) =>
      erc20.allowance(chainKey: chain, tokenAddress: tokenAddress, owner: owner, spender: spender);

  Future<String> sendErc20({
    required String privateKey,
    required String tokenAddress,
    required String toAddress,
    required BigInt amountBaseUnits,
    String chain = 'eth',
  }) =>
      erc20.transfer(
        chainKey: chain,
        privateKey: privateKey,
        tokenAddress: tokenAddress,
        toAddress: toAddress,
        amountBaseUnits: amountBaseUnits,
      );

  Future<String> sendErc20Token({
    required String privateKey,
    required Erc20Token token,
    required String toAddress,
    required String amountDisplay,
  }) =>
      erc20.transferToken(
        token: token,
        privateKey: privateKey,
        toAddress: toAddress,
        amountDisplay: amountDisplay,
      );

  Future<String> approveErc20({
    required String privateKey,
    required String tokenAddress,
    required String spender,
    required BigInt amountBaseUnits,
    String chain = 'eth',
  }) =>
      erc20.approve(
        chainKey: chain,
        privateKey: privateKey,
        tokenAddress: tokenAddress,
        spender: spender,
        amountBaseUnits: amountBaseUnits,
      );

  Future<double> getSolBalance(String address) async {
    try {
      final balance = await _solRpcClient!.getBalance(address);
      return balance.value / 1000000000.0;
    } catch (e) {
      dev.log('Error fetching SOL balance: $e');
      return 0.0;
    }
  }

  Future<double> getBalance(String address, String chain) async {
    final k = chain.toLowerCase();
    if (k == 'sol') return getSolBalance(address);
    if (EvmChainKey.values.any((e) => e.key == k)) {
      return getEvmBalance(address, chain: k);
    }
    return 0.0;
  }

  /// [amountDisplay] is a decimal string. Taking a double and doing
  /// `BigInt.from(amount * 1e18)` is wrong for ~99.9% of decimal inputs (up to
  /// thousands of wei, in either direction) because the product is rounded to
  /// the nearest double before truncation. [Erc20Amount.toBaseUnits] does the
  /// same conversion exactly on the digits.
  Future<String> sendEth(String privateKey, String toAddress, String amountDisplay, {String chain = 'eth'}) async {
    try {
      final credentials = EthPrivateKey.fromHex(privateKey);
      final receiver = EthereumAddress.fromHex(toAddress);
      final weiAmount = Erc20Amount.toBaseUnits(amountDisplay, 18);
      if (weiAmount <= BigInt.zero) {
        throw ArgumentError('amount must be > 0');
      }
      final txHash = await _evmClientFor(chain).sendTransaction(
        credentials,
        Transaction(to: receiver, value: EtherAmount.inWei(weiAmount)),
        chainId: getChainId(chain),
      );
      return txHash;
    } catch (e) {
      throw Exception('$chain transfer failed: $e');
    }
  }

  /// [amountDisplay] is a decimal string — an HTLC lock is checked for an
  /// exact amount by the counterparty, so the value must be exact.
  Future<String> lockHtlc({
    required String privateKey, required String htlcAddress,
    required String hashlock, required int timelock,
    required String amountDisplay, String chain = 'eth',
  }) async {
    try {
      final credentials = EthPrivateKey.fromHex(privateKey);
      final receiver = EthereumAddress.fromHex(htlcAddress);
      final weiAmount = Erc20Amount.toBaseUnits(amountDisplay, 18);
      if (weiAmount <= BigInt.zero) {
        throw ArgumentError('amount must be > 0');
      }
      final txHash = await _evmClientFor(chain).sendTransaction(
        credentials,
        Transaction(
          to: receiver,
          value: EtherAmount.inWei(weiAmount),
          data: Uint8List.fromList(_encodeLockCall(hashlock, timelock)),
        ),
        chainId: getChainId(chain),
      );
      return txHash;
    } catch (e) {
      throw Exception('$chain HTLC lock failed: $e');
    }
  }

  Future<String> claimHtlc({
    required String privateKey, required String htlcAddress,
    required String preimage, String chain = 'eth',
  }) async {
    try {
      final credentials = EthPrivateKey.fromHex(privateKey);
      final txHash = await _evmClientFor(chain).sendTransaction(
        credentials,
        Transaction(
          to: EthereumAddress.fromHex(htlcAddress),
          data: Uint8List.fromList(_encodeClaimCall(preimage)),
        ),
        chainId: getChainId(chain),
      );
      return txHash;
    } catch (e) {
      throw Exception('$chain HTLC claim failed: $e');
    }
  }

  Future<String> refundHtlc({
    required String privateKey, required String htlcAddress, String chain = 'eth',
  }) async {
    try {
      final credentials = EthPrivateKey.fromHex(privateKey);
      final txHash = await _evmClientFor(chain).sendTransaction(
        credentials,
        Transaction(
          to: EthereumAddress.fromHex(htlcAddress),
          data: Uint8List.fromList(_encodeRefundCall()),
        ),
        chainId: getChainId(chain),
      );
      return txHash;
    } catch (e) {
      throw Exception('$chain HTLC refund failed: $e');
    }
  }

  Future<String> sendSol(String privateKeyBase58, String toAddress, String amountSolDisplay) async {
    try {
      final keyBytes = base58decode(privateKeyBase58);
      final sender = await solana.Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: keyBytes.toList());
      // Same exact-digits conversion as the EVM path; SOL is 9 decimals.
      final lamports = Erc20Amount.toBaseUnits(amountSolDisplay, 9).toInt();
      if (lamports <= 0) {
        throw ArgumentError('amount must be > 0');
      }
      final message = solana.Message(instructions: [
        solana.SystemInstruction.transfer(
          fundingAccount: sender.publicKey,
          recipientAccount: solana.Ed25519HDPublicKey.fromBase58(toAddress),
          lamports: lamports,
        ),
      ]);
      final blockhash = await _solRpcClient!.getLatestBlockhash();
      final compiledMessage = message.compile(recentBlockhash: blockhash.value.blockhash, feePayer: sender.publicKey);
      final signature = await sender.sign(compiledMessage.toByteArray());
      final tx = solana_encoder.SignedTx(signatures: [signature], compiledMessage: compiledMessage);
      return await _solRpcClient!.sendTransaction(tx.encode(), preflightCommitment: solana.Commitment.confirmed);
    } catch (e) {
      throw Exception('SOL transfer failed: $e');
    }
  }

  static List<int> _encodeLockCall(String hashlock, int timelock) {
    final data = <int>[];
    data.addAll([0xb0, 0x6c, 0x95, 0x5c]);
    data.addAll(_pad32Bytes(_hexToBytes(hashlock)));
    data.addAll(_pad32BigInt(BigInt.from(timelock)));
    return data;
  }

  static List<int> _encodeClaimCall(String preimage) {
    final data = <int>[];
    data.addAll([0x43, 0x7e, 0x29, 0x20]);
    data.addAll(_pad32Bytes(_hexToBytes(preimage)));
    return data;
  }

  static List<int> _encodeRefundCall() => [0x2e, 0x1a, 0x4d, 0x40];

  static List<int> _pad32BigInt(BigInt value) => _hexToBytes(value.toRadixString(16).padLeft(64, '0'));
  static List<int> _pad32Bytes(List<int> bytes) => bytes.length >= 32 ? bytes.sublist(0, 32) : List<int>.filled(32 - bytes.length, 0) + bytes;

  static List<int> _hexToBytes(String hex) {
    final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
    final bytes = <int>[];
    for (var i = 0; i < clean.length; i += 2) {
      bytes.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  void dispose() {
    _ethClient?.dispose();
    for (final c in _evmClients.values) {
      if (c != _ethClient) c.dispose();
    }
    _evmClients.clear();
    _erc20?.dispose();
  }

  /// Derive EIP-55 checksummed address from a 64-hex private key. Returns '' on failure.
  static String deriveAddressFromPrivateKey(String privateKey) {
    try {
      final clean = privateKey.startsWith('0x') ? privateKey.substring(2) : privateKey;
      if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(clean)) return '';
      final creds = EthPrivateKey.fromHex(clean);
      return creds.address.hexEip55;
    } catch (_) {
      return '';
    }
  }
}
