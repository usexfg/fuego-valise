import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../models/chain_registry.g.dart';
import '../../models/network_config.dart';
import '../../services/swap_config_service.dart';
import '../../utils/theme.dart';

const Map<String, List<String>> _defaultServers = {
  'btc': ['electrum.blockstream.info:50002'],
  'ltc': ['ltc.merkle.io:50002'],
  'kmd': ['electrum.komodo.earth:11002'],
  'bch': ['electroncash.org:50002'],
  'dcr': ['localhost:19100'],
};

final List<ChainEntry> _evmSwapChains = kChains
    .where((chain) => chain.family == 'evm' && chain.tier == 'swap')
    .toList(growable: false);
final List<String> _evmSwapChainKeys = _evmSwapChains
    .map((chain) => chain.key)
    .toList(growable: false);
final Map<String, String> _defaultRpcUrls = {
  for (final chain in _evmSwapChains) chain.key: chain.rpc,
  'sol': 'http://127.0.0.1:8899',
};

final Map<String, Map<String, String>> _chainInfo = {
  'btc': {
    'name': 'Bitcoin',
    'icon': 'B',
    'desc': 'P2WSH SegWit HTLC',
    'type': 'spv',
  },
  'ltc': {
    'name': 'Litecoin',
    'icon': 'L',
    'desc': 'P2WSH SegWit HTLC',
    'type': 'spv',
  },
  'kmd': {'name': 'Komodo', 'icon': 'K', 'desc': 'P2SH HTLC', 'type': 'spv'},
  'bch': {
    'name': 'Bitcoin Cash',
    'icon': 'B',
    'desc': 'P2SH HTLC',
    'type': 'spv',
  },
  'dcr': {
    'name': 'Decred',
    'icon': 'D',
    'desc': 'SPV + RPC HTLC',
    'type': 'spv',
  },
  for (final chain in _evmSwapChains)
    chain.key: {
      'name': chain.name,
      'icon': chain.ticker.substring(0, 1),
      'desc': 'EVM HTLC (web3)',
      'type': 'evm',
    },
  'sol': {
    'name': 'Solana',
    'icon': 'S',
    'desc': 'SPL HTLC (web3)',
    'type': 'sol',
  },
  'xmr': {
    'name': 'Monero',
    'icon': 'M',
    'desc': 'Daemon + Wallet RPC',
    'type': 'rpc',
  },
};

class SwapSettingsScreen extends StatefulWidget {
  const SwapSettingsScreen({super.key, required this.networkConfig});

  final NetworkConfig networkConfig;

  @override
  State<SwapSettingsScreen> createState() => _SwapSettingsScreenState();
}

class _SwapSettingsScreenState extends State<SwapSettingsScreen> {
  final SwapConfigService _swapService = SwapConfigService();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final Map<String, TextEditingController> _wifControllers = {};
  final Map<String, TextEditingController> _serverControllers = {};
  final Map<String, List<String>> _serverLists = {};
  final Map<String, TextEditingController> _rpcControllers = {};
  final Map<String, TextEditingController> _chainIdControllers = {};
  final Map<String, TextEditingController> _htlcRegistryControllers = {};
  final Map<String, TextEditingController> _ptlcRegistryControllers = {};
  final _solProgramIdController = TextEditingController();
  final _xmrViewKeyController = TextEditingController();
  bool _swapdRunning = false;
  bool _isStarting = false;
  final _xfgSecretController = TextEditingController();

  bool get _isTestnet => widget.networkConfig.isTestnet;

  List<String> get _visibleRpcSwapChainKeys => [
    ..._evmSwapChainKeys,
    if (!_isTestnet) 'sol',
  ];

  @override
  void initState() {
    super.initState();
    if (!_isTestnet) {
      for (final chain in ['btc', 'ltc', 'kmd', 'bch', 'dcr']) {
        _wifControllers[chain] = TextEditingController();
        _serverControllers[chain] = TextEditingController();
        _serverLists[chain] = List<String>.from(_defaultServers[chain] ?? []);
      }
    }
    for (final chain in _visibleRpcSwapChainKeys) {
      _wifControllers[chain] = TextEditingController();
      _serverControllers[chain] = TextEditingController();
      _serverLists[chain] = [];
      if (_defaultRpcUrls.containsKey(chain))
        _rpcControllers[chain] = TextEditingController(
          text: _defaultRpcUrls[chain]!,
        );
      if (chain != 'sol') {
        _chainIdControllers[chain] = TextEditingController(
          text: _isTestnet ? '' : kChainIds[chain]!.toString(),
        );
        _htlcRegistryControllers[chain] = TextEditingController();
        _ptlcRegistryControllers[chain] = TextEditingController();
      }
    }
    if (!_isTestnet) {
      _wifControllers['xmr'] = TextEditingController();
      _rpcControllers['xmr_daemon'] = TextEditingController(text: '127.0.0.1');
      _rpcControllers['xmr_wallet'] = TextEditingController(text: '127.0.0.1');
    }
    _loadSavedConfig();
  }

  @override
  void dispose() {
    for (final c in _wifControllers.values) c.dispose();
    for (final c in _serverControllers.values) c.dispose();
    for (final c in _rpcControllers.values) c.dispose();
    for (final c in _chainIdControllers.values) c.dispose();
    for (final c in _htlcRegistryControllers.values) c.dispose();
    for (final c in _ptlcRegistryControllers.values) c.dispose();
    _solProgramIdController.dispose();
    _xmrViewKeyController.dispose();
    _xfgSecretController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedConfig() async {
    for (final chain in ['btc', 'ltc', 'kmd', 'bch', 'dcr']) {
      if (!_wifControllers.containsKey(chain)) continue;
      final wif = await _secureStorage.read(key: 'swap_wif_$chain');
      if (wif != null && wif.isNotEmpty) {
        _wifControllers[chain]!.text = wif;
      }
      final serversStr = await _secureStorage.read(key: 'swap_servers_$chain');
      if (serversStr != null && serversStr.isNotEmpty)
        _serverLists[chain] = serversStr
            .split(',')
            .where((s) => s.isNotEmpty)
            .toList();
    }
    for (final chain in _visibleRpcSwapChainKeys) {
      final wif = await _secureStorage.read(key: 'swap_wif_$chain');
      if (wif != null && wif.isNotEmpty) {
        _wifControllers[chain]!.text = wif;
      }
      final rpcUrl = await _secureStorage.read(key: 'swap_rpc_url_$chain');
      if (rpcUrl != null && rpcUrl.isNotEmpty)
        _rpcControllers[chain]!.text = rpcUrl;
      if (chain != 'sol') {
        final chainId = await _secureStorage.read(key: 'swap_chain_id_$chain');
        if (chainId != null && chainId.isNotEmpty) {
          _chainIdControllers[chain]!.text = chainId;
        }
        final htlcRegistry = await _secureStorage.read(
          key: 'swap_htlc_registry_$chain',
        );
        if (htlcRegistry != null) {
          _htlcRegistryControllers[chain]!.text = htlcRegistry;
        }
        final ptlcRegistry = await _secureStorage.read(
          key: 'swap_ptlc_registry_$chain',
        );
        if (ptlcRegistry != null) {
          _ptlcRegistryControllers[chain]!.text = ptlcRegistry;
        }
      } else {
        final programId = await _secureStorage.read(key: 'swap_sol_program_id');
        if (programId != null) _solProgramIdController.text = programId;
      }
    }
    if (!_isTestnet) {
      final xmrWif = await _secureStorage.read(key: 'swap_wif_xmr');
      if (xmrWif != null && xmrWif.isNotEmpty) {
        _wifControllers['xmr']!.text = xmrWif;
      }
      final xmrDaemon = await _secureStorage.read(key: 'swap_xmr_daemon_host');
      if (xmrDaemon != null) _rpcControllers['xmr_daemon']!.text = xmrDaemon;
      final xmrWallet = await _secureStorage.read(key: 'swap_xmr_wallet_host');
      if (xmrWallet != null) _rpcControllers['xmr_wallet']!.text = xmrWallet;
      final xmrViewKey = await _secureStorage.read(key: 'swap_xmr_view_key');
      if (xmrViewKey != null) _xmrViewKeyController.text = xmrViewKey;
    }
    final xfgKey = await _secureStorage.read(key: 'swap_xfg_secret_key');
    if (xfgKey != null) _xfgSecretController.text = xfgKey;
    _swapdRunning = _swapService.isRunning;
    if (mounted) setState(() {});
  }

  Future<String?> _saveConfig() async {
    final chains = <String, SwapChainConfig>{};

    if (!_isTestnet) {
      for (final chain in ['btc', 'ltc', 'kmd', 'bch', 'dcr']) {
        final wif = _wifControllers[chain]!.text.trim();
        if (wif.isEmpty) continue;
        final error = SwapConfigService.validateWif(wif, chain);
        if (error != null) {
          _showError('${chain.toUpperCase()} WIF error: $error');
          return null;
        }
        await _secureStorage.write(key: 'swap_wif_$chain', value: wif);
        await _secureStorage.write(
          key: 'swap_servers_$chain',
          value: _serverLists[chain]!.join(','),
        );
        chains[chain] = SwapChainConfig(
          wif: wif,
          servers: _serverLists[chain]!,
        );
      }
    }

    for (final chain in _evmSwapChainKeys) {
      final wif = _wifControllers[chain]!.text.trim();
      final rpcUrl = _rpcControllers[chain]?.text.trim() ?? '';
      final chainIdText = _chainIdControllers[chain]!.text.trim();
      final htlcRegistry = _htlcRegistryControllers[chain]!.text.trim();
      final ptlcRegistry = _ptlcRegistryControllers[chain]!.text.trim();
      if (wif.isEmpty &&
          rpcUrl.isEmpty &&
          chainIdText.isEmpty &&
          htlcRegistry.isEmpty &&
          ptlcRegistry.isEmpty) {
        continue;
      }
      if (wif.length != 64 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(wif)) {
        _showError('${chain.toUpperCase()} key must be 64-char hex');
        return null;
      }
      final uri = Uri.tryParse(rpcUrl);
      if (uri == null ||
          uri.host.isEmpty ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        _showError('${chain.toUpperCase()} RPC must be an HTTP(S) URL');
        return null;
      }
      final chainId = int.tryParse(chainIdText);
      if (chainId == null || chainId <= 0) {
        _showError('${chain.toUpperCase()} needs an explicit chain ID');
        return null;
      }
      if (!_isTestnet && chainId != kChainIds[chain]) {
        _showError('${chain.toUpperCase()} chain ID does not match mainnet');
        return null;
      }
      if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(htlcRegistry)) {
        _showError('${chain.toUpperCase()} needs a deployed HTLC registry');
        return null;
      }
      if (ptlcRegistry.isNotEmpty &&
          !RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(ptlcRegistry)) {
        _showError('${chain.toUpperCase()} PTLC registry is invalid');
        return null;
      }
      await _secureStorage.write(key: 'swap_wif_$chain', value: wif);
      await _secureStorage.write(key: 'swap_rpc_url_$chain', value: rpcUrl);
      await _secureStorage.write(
        key: 'swap_chain_id_$chain',
        value: '$chainId',
      );
      await _secureStorage.write(
        key: 'swap_htlc_registry_$chain',
        value: htlcRegistry,
      );
      await _secureStorage.write(
        key: 'swap_ptlc_registry_$chain',
        value: ptlcRegistry,
      );
      chains[chain] = SwapChainConfig(
        wif: wif,
        rpcUrl: rpcUrl,
        chainId: chainId,
        htlcRegistry: htlcRegistry,
        ptlcRegistry: ptlcRegistry.isEmpty ? null : ptlcRegistry,
      );
    }

    if (!_isTestnet) {
      final solWif = _wifControllers['sol']!.text.trim();
      final rpcUrl = _rpcControllers['sol']?.text.trim() ?? '';
      final programId = _solProgramIdController.text.trim();
      if (solWif.isNotEmpty || rpcUrl.isNotEmpty || programId.isNotEmpty) {
        if (solWif.length < 80 ||
            !RegExp(r'^[1-9A-HJ-NP-Za-km-z]+$').hasMatch(solWif)) {
          _showError('SOL keypair must be base58-encoded');
          return null;
        }
        final uri = Uri.tryParse(rpcUrl);
        if (uri == null ||
            uri.host.isEmpty ||
            uri.scheme != 'http' ||
            !SwapConfigService.isLocalSolanaRpcHost(uri.host)) {
          _showError('SOL requires a local HTTP RPC at 127.0.0.1');
          return null;
        }
        if (!RegExp(r'^[1-9A-HJ-NP-Za-km-z]{32,100}$').hasMatch(programId)) {
          _showError('SOL needs a deployed program ID');
          return null;
        }
        await _secureStorage.write(key: 'swap_wif_sol', value: solWif);
        await _secureStorage.write(key: 'swap_rpc_url_sol', value: rpcUrl);
        await _secureStorage.write(
          key: 'swap_sol_program_id',
          value: programId,
        );
        chains['sol'] = SwapChainConfig(
          wif: solWif,
          rpcUrl: rpcUrl,
          solProgramId: programId,
        );
      }
    }

    if (!_isTestnet) {
      final xmrSpendKey = _wifControllers['xmr']!.text.trim();
      final xmrViewKey = _xmrViewKeyController.text.trim();
      if (xmrSpendKey.isNotEmpty || xmrViewKey.isNotEmpty) {
        if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(xmrSpendKey) ||
            !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(xmrViewKey)) {
          _showError('XMR spend and view keys must each be 64 hex chars');
          return null;
        }
        final daemonHost = _rpcControllers['xmr_daemon']?.text.trim() ?? '';
        final walletHost = _rpcControllers['xmr_wallet']?.text.trim() ?? '';
        if (daemonHost.isEmpty || walletHost.isEmpty) {
          _showError('XMR needs daemon and wallet RPC hosts');
          return null;
        }
        await _secureStorage.write(key: 'swap_wif_xmr', value: xmrSpendKey);
        await _secureStorage.write(key: 'swap_xmr_view_key', value: xmrViewKey);
        await _secureStorage.write(
          key: 'swap_xmr_daemon_host',
          value: daemonHost,
        );
        await _secureStorage.write(
          key: 'swap_xmr_wallet_host',
          value: walletHost,
        );
        chains['xmr'] = SwapChainConfig(
          wif: xmrSpendKey,
          xmrViewKey: xmrViewKey,
          xmrDaemonHost: daemonHost,
          xmrWalletHost: walletHost,
        );
      }
    }

    final xfgKey = _xfgSecretController.text.trim();
    if (xfgKey.isNotEmpty && !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(xfgKey)) {
      _showError('XFG secret key must be 64 hex chars');
      return null;
    }
    if (xfgKey.isNotEmpty) {
      await _secureStorage.write(key: 'swap_xfg_secret_key', value: xfgKey);
    }

    if (chains.isEmpty) {
      _showError('No executable chain is configured');
      return null;
    }

    try {
      final configPath = await _swapService.generateConfig(
        chains: chains,
        network: _isTestnet ? 'testnet' : 'mainnet',
        xfgSecretKey: xfgKey.isNotEmpty ? xfgKey : null,
      );
      _showSuccess('Config saved to $configPath');
      return configPath;
    } on ArgumentError catch (error) {
      _showError(error.message?.toString() ?? error.toString());
      return null;
    } catch (error) {
      _showError('Could not save swap configuration: $error');
      return null;
    }
  }

  void _showError(String msg) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: AppTheme.errorColor),
      );
  }

  void _showSuccess(String msg) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: AppTheme.successColor),
      );
  }

  Future<void> _startSwapd() async {
    setState(() => _isStarting = true);
    final configPath = await _saveConfig();
    if (configPath == null) {
      if (mounted) setState(() => _isStarting = false);
      return;
    }
    final binary = _swapService.findSwapdBinary();
    if (binary == null) {
      _showError('xfg-swapd binary not found');
      setState(() => _isStarting = false);
      return;
    }
    final ok = await _swapService.startDaemon(testnet: _isTestnet);
    setState(() {
      _swapdRunning = ok;
      _isStarting = false;
    });
    _showSuccess(ok ? 'xfg-swapd started' : 'Failed to start xfg-swapd');
  }

  Future<void> _stopSwapd() async {
    await _swapService.stopDaemon();
    setState(() => _swapdRunning = false);
    _showSuccess('xfg-swapd stopped');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Cross-Chain Swap Settings'),
      elevation: 0,
      backgroundColor: Colors.transparent,
      actions: [
        if (_swapdRunning)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              icon: const Icon(Icons.stop_circle, color: AppTheme.errorColor),
              onPressed: _stopSwapd,
              tooltip: 'Stop xfg-swapd',
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              icon: _isStarting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_circle, color: AppTheme.successColor),
              onPressed: _isStarting ? null : _startSwapd,
              tooltip: 'Start xfg-swapd',
            ),
          ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildStatusBanner(),
        const SizedBox(height: 20),
        _buildInfoBox(),
        const SizedBox(height: 24),
        _buildSectionHeader('Fuego (XFG)'),
        _buildXfgKeyTile(),
        if (!_isTestnet) ...[
          const SizedBox(height: 24),
          _buildSectionHeader('SPV Chains (BTC, LTC, KMD, BCH, DCR)'),
          for (final chain in ['btc', 'ltc', 'kmd', 'bch', 'dcr'])
            _buildChainCard(chain),
        ],
        const SizedBox(height: 24),
        _buildSectionHeader(
          _isTestnet
              ? 'Configured EVM Testnet Deployments'
              : 'EVM / Solana (Light Client)',
        ),
        _buildEvmInfoBox(),
        const SizedBox(height: 8),
        for (final chain in _visibleRpcSwapChainKeys) _buildEvmChainCard(chain),
        if (!_isTestnet) ...[
          const SizedBox(height: 24),
          _buildSectionHeader('Monero (RPC)'),
          _buildMoneroCard(),
        ],
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () => _saveConfig(),
            icon: const Icon(Icons.save),
            label: const Text('Save Configuration'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        if (!_isTestnet) ...[
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _generateFreshConfig,
              icon: const Icon(Icons.vpn_key),
              label: const Text('Generate Fresh WIFs'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.warningColor,
                side: const BorderSide(color: AppTheme.warningColor),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
        const SizedBox(height: 32),
      ],
    ),
  );

  Widget _buildStatusBanner() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: (_swapdRunning ? AppTheme.successColor : AppTheme.errorColor)
          .withOpacity(0.15),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: (_swapdRunning ? AppTheme.successColor : AppTheme.errorColor)
            .withOpacity(0.4),
      ),
    ),
    child: Row(
      children: [
        Icon(
          _swapdRunning ? Icons.check_circle : Icons.error_outline,
          color: _swapdRunning ? AppTheme.successColor : AppTheme.errorColor,
          size: 20,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _swapdRunning
                    ? 'xfg-swapd is running'
                    : 'xfg-swapd is not running',
                style: TextStyle(
                  color: _swapdRunning
                      ? AppTheme.successColor
                      : AppTheme.errorColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _swapdRunning
                    ? 'Check the daemon runtime list before initiating a pair'
                    : 'Save a valid deployment configuration before starting',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _buildInfoBox() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppTheme.infoColor.withOpacity(0.1),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppTheme.infoColor.withOpacity(0.3)),
    ),
    child: Row(
      children: [
        const Icon(Icons.info_outline, color: AppTheme.infoColor, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            _isTestnet
                ? 'Testnet accepts only EVM entries with a real RPC endpoint, chain ID, and deployed HTLC registry. No deployment values are bundled.'
                : 'A configured key and RPC endpoint are not enough to make a pair executable. EVM and Solana also need the deployed contract or program identity checked by xfg-swapd.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
        ),
      ],
    ),
  );

  Widget _buildXfgKeyTile() => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppTheme.cardColor,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Secret Key',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _xfgSecretController,
          obscureText: true,
          decoration: InputDecoration(
            hintText: '64-char hex (from fuego_cli wallet_export)',
            hintStyle: TextStyle(
              color: AppTheme.textSecondary.withOpacity(0.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(
                color: AppTheme.textSecondary.withOpacity(0.3),
              ),
            ),
            focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: AppTheme.primaryColor),
            ),
            suffixIcon: IconButton(
              icon: const Icon(Icons.visibility, size: 18),
              onPressed: () => setState(() {}),
            ),
          ),
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontFamily: 'IBMPlexMono',
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Required for signing swap transactions on the Fuego chain.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
        ),
      ],
    ),
  );

  Widget _buildEvmInfoBox() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppTheme.infoColor.withOpacity(0.1),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppTheme.infoColor.withOpacity(0.3)),
    ),
    child: Row(
      children: [
        const Icon(Icons.info_outline, color: AppTheme.infoColor, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            _isTestnet
                ? 'Enter the exact testnet RPC URL, chain ID, and deployed HTLC registry. The runtime daemon rejects missing or mismatched deployment identity.'
                : 'Public RPC defaults are transport endpoints only. Each pair also requires the correct deployed HTLC registry; optional PTLC registry data enables that route when the daemon reports it ready.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
        ),
      ],
    ),
  );

  Widget _buildChainCard(String chain) {
    final info = _chainInfo[chain]!;
    final hasWif = _wifControllers[chain]!.text.isNotEmpty;
    final enabled = hasWif;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: enabled
              ? AppTheme.primaryColor.withOpacity(0.5)
              : AppTheme.textSecondary.withOpacity(0.2),
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: enabled
                  ? AppTheme.primaryColor.withOpacity(0.15)
                  : AppTheme.surfaceColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                info['icon']!,
                style: TextStyle(
                  color: enabled
                      ? AppTheme.primaryColor
                      : AppTheme.textSecondary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          title: Row(
            children: [
              Text(
                info['name']!,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              if (hasWif)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.successColor.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'KEY',
                    style: TextStyle(
                      color: AppTheme.successColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          subtitle: Text(
            '${info['desc']} \u00b7 ${_serverLists[chain]!.length} server(s)',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Private Key (WIF)',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _wifControllers[chain],
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: _wifHint(chain),
                    hintStyle: TextStyle(
                      color: AppTheme.textSecondary.withOpacity(0.5),
                      fontFamily: 'IBMPlexMono',
                      fontSize: 13,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: AppTheme.textSecondary.withOpacity(0.3),
                      ),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: AppTheme.primaryColor),
                    ),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.paste, size: 18),
                          onPressed: () async {
                            final data = await Clipboard.getData('text/plain');
                            if (data?.text != null)
                              setState(
                                () =>
                                    _wifControllers[chain]!.text = data!.text!,
                              );
                          },
                          tooltip: 'Paste',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 40,
                            minHeight: 40,
                            maxWidth: 40,
                            maxHeight: 40,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.content_paste_go, size: 18),
                          onPressed: () => _importFromClipboard(chain),
                          tooltip: 'Import & validate',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 40,
                            minHeight: 40,
                            maxWidth: 40,
                            maxHeight: 40,
                          ),
                        ),
                      ],
                    ),
                  ),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontFamily: 'IBMPlexMono',
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Electrum Servers',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                ..._serverLists[chain]!.asMap().entries.map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.value,
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontFamily: 'IBMPlexMono',
                              fontSize: 13,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          color: AppTheme.errorColor,
                          onPressed: () => setState(
                            () => _serverLists[chain]!.removeAt(entry.key),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _serverControllers[chain],
                        decoration: InputDecoration(
                          hintText: 'host:port',
                          hintStyle: TextStyle(
                            color: AppTheme.textSecondary.withOpacity(0.5),
                            fontFamily: 'IBMPlexMono',
                            fontSize: 13,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(
                              color: AppTheme.textSecondary.withOpacity(0.3),
                            ),
                          ),
                          focusedBorder: const OutlineInputBorder(
                            borderSide: BorderSide(
                              color: AppTheme.primaryColor,
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontFamily: 'IBMPlexMono',
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.add, size: 20),
                      color: AppTheme.successColor,
                      onPressed: () {
                        final server = _serverControllers[chain]!.text.trim();
                        if (server.isNotEmpty &&
                            !_serverLists[chain]!.contains(server))
                          setState(() {
                            _serverLists[chain]!.add(server);
                            _serverControllers[chain]!.clear();
                          });
                      },
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEvmChainCard(String chain) {
    final info = _chainInfo[chain]!;
    final hasWif = _wifControllers[chain]!.text.isNotEmpty;
    final enabled = hasWif;
    final isSol = chain == 'sol';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: enabled
              ? AppTheme.primaryColor.withOpacity(0.5)
              : AppTheme.textSecondary.withOpacity(0.2),
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: enabled
                  ? AppTheme.primaryColor.withOpacity(0.15)
                  : AppTheme.surfaceColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                info['icon']!,
                style: TextStyle(
                  color: enabled
                      ? AppTheme.primaryColor
                      : AppTheme.textSecondary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          title: Row(
            children: [
              Text(
                info['name']!,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              if (hasWif)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.successColor.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'KEY',
                    style: TextStyle(
                      color: AppTheme.successColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          subtitle: Text(
            '${info['desc']} \u00b7 ${_rpcControllers[chain]?.text.isNotEmpty == true ? 'RPC configured' : 'No RPC'}',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isSol ? 'Keypair (base58)' : 'Private Key (hex)',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _wifControllers[chain],
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: isSol
                        ? 'Base58-encoded 64-byte keypair'
                        : '64-char hex private key',
                    hintStyle: TextStyle(
                      color: AppTheme.textSecondary.withOpacity(0.5),
                      fontFamily: 'IBMPlexMono',
                      fontSize: 13,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: AppTheme.textSecondary.withOpacity(0.3),
                      ),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: AppTheme.primaryColor),
                    ),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.paste, size: 18),
                      onPressed: () async {
                        final data = await Clipboard.getData('text/plain');
                        if (data?.text != null)
                          setState(
                            () => _wifControllers[chain]!.text = data!.text!,
                          );
                      },
                      tooltip: 'Paste',
                    ),
                  ),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontFamily: 'IBMPlexMono',
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  isSol ? 'Solana RPC URL' : 'JSON-RPC Endpoint',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _rpcControllers[chain],
                  decoration: InputDecoration(
                    hintText: _defaultRpcUrls[chain] ?? 'https://...',
                    hintStyle: TextStyle(
                      color: AppTheme.textSecondary.withOpacity(0.5),
                      fontFamily: 'IBMPlexMono',
                      fontSize: 13,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: AppTheme.textSecondary.withOpacity(0.3),
                      ),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: AppTheme.primaryColor),
                    ),
                  ),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontFamily: 'IBMPlexMono',
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  isSol
                      ? 'SOL uses a local 127.0.0.1 RPC until authenticated remote transport is available.'
                      : 'RPC transport and deployment identity are both required before the daemon can expose this pair as ready.',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                ),
                const SizedBox(height: 12),
                if (isSol) ...[
                  _buildConfigInput(
                    controller: _solProgramIdController,
                    label: 'Deployed Program ID',
                    hint: 'Base58 program address',
                  ),
                ] else ...[
                  _buildConfigInput(
                    controller: _chainIdControllers[chain]!,
                    label: 'Chain ID',
                    hint: _isTestnet
                        ? 'Exact testnet chain ID'
                        : '${kChainIds[chain]}',
                    numeric: true,
                  ),
                  const SizedBox(height: 12),
                  _buildConfigInput(
                    controller: _htlcRegistryControllers[chain]!,
                    label: 'Deployed HTLC Registry',
                    hint: '0x…',
                  ),
                  const SizedBox(height: 12),
                  _buildConfigInput(
                    controller: _ptlcRegistryControllers[chain]!,
                    label: 'Deployed PTLC Registry (optional)',
                    hint: '0x…',
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfigInput({
    required TextEditingController controller,
    required String label,
    required String hint,
    bool numeric = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: controller,
        keyboardType: numeric ? TextInputType.number : TextInputType.text,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
            color: AppTheme.textSecondary.withOpacity(0.5),
            fontFamily: 'IBMPlexMono',
            fontSize: 13,
          ),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(
              color: AppTheme.textSecondary.withOpacity(0.3),
            ),
          ),
          focusedBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: AppTheme.primaryColor),
          ),
        ),
        style: const TextStyle(
          color: AppTheme.textPrimary,
          fontFamily: 'IBMPlexMono',
          fontSize: 13,
        ),
      ),
    ],
  );

  Widget _buildMoneroCard() {
    final hasKey = _wifControllers['xmr']!.text.isNotEmpty;
    final enabled = hasKey;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: enabled
              ? AppTheme.primaryColor.withOpacity(0.5)
              : AppTheme.textSecondary.withOpacity(0.2),
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: enabled
                  ? AppTheme.primaryColor.withOpacity(0.15)
                  : AppTheme.surfaceColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                'M',
                style: TextStyle(
                  color: enabled
                      ? AppTheme.primaryColor
                      : AppTheme.textSecondary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          title: Row(
            children: [
              const Text(
                'Monero',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              if (hasKey)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.successColor.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'KEY',
                    style: TextStyle(
                      color: AppTheme.successColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          subtitle: Text(
            'Daemon + Wallet RPC \u00b7 ${_rpcControllers['xmr_daemon']?.text ?? '127.0.0.1'}',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Spend Key (64 hex)',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _wifControllers['xmr'],
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: '64-char hex spend key',
                    hintStyle: TextStyle(
                      color: AppTheme.textSecondary.withOpacity(0.5),
                      fontFamily: 'IBMPlexMono',
                      fontSize: 13,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: AppTheme.textSecondary.withOpacity(0.3),
                      ),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: AppTheme.primaryColor),
                    ),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.paste, size: 18),
                      onPressed: () async {
                        final data = await Clipboard.getData('text/plain');
                        if (data?.text != null)
                          setState(
                            () => _wifControllers['xmr']!.text = data!.text!,
                          );
                      },
                      tooltip: 'Paste',
                    ),
                  ),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontFamily: 'IBMPlexMono',
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'View Key (64 hex)',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _xmrViewKeyController,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    hintText: '64-char hex view key',
                    hintStyle: TextStyle(
                      color: AppTheme.textSecondary.withOpacity(0.5),
                      fontFamily: 'IBMPlexMono',
                      fontSize: 13,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: AppTheme.textSecondary.withOpacity(0.3),
                      ),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: AppTheme.primaryColor),
                    ),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.paste, size: 18),
                      onPressed: () async {
                        final data = await Clipboard.getData('text/plain');
                        if (data?.text != null) {
                          setState(
                            () => _xmrViewKeyController.text = data!.text!,
                          );
                        }
                      },
                      tooltip: 'Paste',
                    ),
                  ),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontFamily: 'IBMPlexMono',
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Daemon Host',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _rpcControllers['xmr_daemon'],
                  decoration: InputDecoration(
                    hintText: '127.0.0.1',
                    hintStyle: TextStyle(
                      color: AppTheme.textSecondary.withOpacity(0.5),
                      fontFamily: 'IBMPlexMono',
                      fontSize: 13,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: AppTheme.textSecondary.withOpacity(0.3),
                      ),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: AppTheme.primaryColor),
                    ),
                  ),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontFamily: 'IBMPlexMono',
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Wallet RPC Host',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _rpcControllers['xmr_wallet'],
                  decoration: InputDecoration(
                    hintText: '127.0.0.1',
                    hintStyle: TextStyle(
                      color: AppTheme.textSecondary.withOpacity(0.5),
                      fontFamily: 'IBMPlexMono',
                      fontSize: 13,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: AppTheme.textSecondary.withOpacity(0.3),
                      ),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: AppTheme.primaryColor),
                    ),
                  ),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontFamily: 'IBMPlexMono',
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Requires monerod and monero-wallet-rpc running locally.',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _wifHint(String chain) {
    switch (chain) {
      case 'btc':
        return '5... / K... / L... (compressed)';
      case 'ltc':
        return '6... / T... (compressed)';
      case 'kmd':
        return '7... / U... (compressed)';
      case 'bch':
        return '5... / K... / L... (compressed)';
      default:
        return 'WIF private key';
    }
  }

  void _importFromClipboard(String chain) async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      _showError('Clipboard is empty');
      return;
    }
    final error = SwapConfigService.validateWif(text, chain);
    if (error != null) {
      _showError('Invalid WIF: $error');
      return;
    }
    setState(() => _wifControllers[chain]!.text = text);
    _showSuccess('${chain.toUpperCase()} WIF imported and validated');
  }

  Future<void> _generateFreshConfig() async {
    try {
      final result = await Process.run(
        _swapService.findSwapdBinary() ?? 'xfg-swapd',
        ['--generate-spv-config'],
      );
      if (result.exitCode == 0 && mounted) {
        final output = result.stdout.toString();
        final jsonStart = output.indexOf('{');
        final jsonEnd = output.lastIndexOf('}');
        if (jsonStart >= 0 && jsonEnd > jsonStart) {
          final jsonStr = output.substring(jsonStart, jsonEnd + 1);
          final config = const JsonDecoder().convert(jsonStr) as Map;
          for (final chain in ['btc', 'ltc', 'kmd', 'bch']) {
            final wifKey = '${chain}_wif';
            if (config.containsKey(wifKey))
              setState(() {
                _wifControllers[chain]!.text = config[wifKey] as String;
              });
            final serverKeys = <String>[];
            for (var i = 0; i < 16; i++) {
              final key = '${chain}_spv_server_$i';
              if (config.containsKey(key))
                serverKeys.add(config[key] as String);
            }
            if (serverKeys.isNotEmpty)
              setState(() => _serverLists[chain] = serverKeys);
          }
          if (config.containsKey('xfg_secret_key'))
            setState(
              () => _xfgSecretController.text =
                  config['xfg_secret_key'] as String,
            );
        }
        _showSuccess('Fresh WIFs generated \u2014 review and save');
      } else {
        _showError('Failed: ${result.stderr}');
      }
    } catch (e) {
      _showError('Error: $e');
    }
  }

  Widget _buildSectionHeader(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: AppTheme.primaryColor,
      ),
    ),
  );
}
