import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../models/chain_registry.g.dart';
import '../../models/network_config.dart';
import '../../services/swap_config_service.dart';
import '../../utils/theme.dart';

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
  'btc': {'name': 'Bitcoin', 'icon': 'B', 'desc': 'P2WSH HTLC'},
  'ltc': {'name': 'Litecoin', 'icon': 'L', 'desc': 'P2WSH HTLC'},
  'bch': {'name': 'Bitcoin Cash', 'icon': 'B', 'desc': 'P2SH HTLC'},
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
  final Map<String, bool> _utxoFullNode = {};
  final Map<String, TextEditingController> _nodeUrlControllers = {};
  final Map<String, TextEditingController> _nodeUserControllers = {};
  final Map<String, TextEditingController> _nodePasswordControllers = {};
  final Map<String, TextEditingController> _quorumControllers = {};
  final Map<String, TextEditingController> _checkpointHeightControllers = {};
  final Map<String, TextEditingController> _checkpointHashControllers = {};
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
      for (final chain in SwapConfigService.utxoSwapChains) {
        _initUtxoChain(chain);
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

  void _initUtxoChain(String chain) {
    final defaults = SwapConfigService.utxoSpvDefaults[chain]!;
    _wifControllers[chain] = TextEditingController();
    _serverControllers[chain] = TextEditingController();
    _serverLists[chain] = List<String>.from(defaults.servers);
    _utxoFullNode[chain] = true;
    _nodeUrlControllers[chain] = TextEditingController(
      text: 'http://127.0.0.1:${defaults.defaultRpcPort}',
    );
    _nodeUserControllers[chain] = TextEditingController();
    _nodePasswordControllers[chain] = TextEditingController();
    _quorumControllers[chain] = TextEditingController(
      text: SwapConfigService.defaultSpvQuorum.toString(),
    );
    _checkpointHeightControllers[chain] = TextEditingController(
      text: defaults.checkpointHeight.toString(),
    );
    _checkpointHashControllers[chain] = TextEditingController(
      text: defaults.checkpointHash,
    );
  }

  @override
  void dispose() {
    for (final controllers in [
      _nodeUrlControllers,
      _nodeUserControllers,
      _nodePasswordControllers,
      _quorumControllers,
      _checkpointHeightControllers,
      _checkpointHashControllers,
    ]) {
      for (final c in controllers.values) {
        c.dispose();
      }
    }
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

  Future<void> _restoreText(
    Map<String, TextEditingController> controllers,
    String chain,
    String storageKey,
  ) async {
    final value = await _secureStorage.read(key: storageKey);
    if (value != null && value.isNotEmpty) controllers[chain]!.text = value;
  }

  Future<void> _loadSavedConfig() async {
    for (final chain in SwapConfigService.utxoSwapChains) {
      if (!_wifControllers.containsKey(chain)) continue;
      await _restoreText(_wifControllers, chain, 'swap_wif_$chain');
      final serversStr = await _secureStorage.read(key: 'swap_servers_$chain');
      if (serversStr != null && serversStr.isNotEmpty)
        _serverLists[chain] = serversStr
            .split(',')
            .where((s) => s.isNotEmpty)
            .toList();
      final mode = await _secureStorage.read(key: 'swap_utxo_mode_$chain');
      if (mode != null) _utxoFullNode[chain] = mode != 'spv';
      await _restoreText(_nodeUrlControllers, chain, 'swap_node_url_$chain');
      await _restoreText(_nodeUserControllers, chain, 'swap_node_user_$chain');
      await _restoreText(
        _nodePasswordControllers,
        chain,
        'swap_node_password_$chain',
      );
      await _restoreText(_quorumControllers, chain, 'swap_spv_quorum_$chain');
      await _restoreText(
        _checkpointHeightControllers,
        chain,
        'swap_spv_checkpoint_height_$chain',
      );
      await _restoreText(
        _checkpointHashControllers,
        chain,
        'swap_spv_checkpoint_hash_$chain',
      );
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

  Future<SwapChainConfig?> _saveUtxoChain(String chain) async {
    final wif = _wifControllers[chain]!.text.trim();
    if (wif.isEmpty) return null;
    final fullNode = _utxoFullNode[chain]!;
    final nodeUrl = _nodeUrlControllers[chain]!.text.trim();
    final nodeUser = _nodeUserControllers[chain]!.text.trim();
    final nodePassword = _nodePasswordControllers[chain]!.text;
    final quorum = _quorumControllers[chain]!.text.trim();
    final checkpointHeight = _checkpointHeightControllers[chain]!.text.trim();
    final checkpointHash = _checkpointHashControllers[chain]!.text.trim();
    final stored = <String, String>{
      'swap_wif_$chain': wif,
      'swap_servers_$chain': _serverLists[chain]!.join(','),
      'swap_utxo_mode_$chain': fullNode ? 'full_node' : 'spv',
      'swap_node_url_$chain': nodeUrl,
      'swap_node_user_$chain': nodeUser,
      'swap_node_password_$chain': nodePassword,
      'swap_spv_quorum_$chain': quorum,
      'swap_spv_checkpoint_height_$chain': checkpointHeight,
      'swap_spv_checkpoint_hash_$chain': checkpointHash,
    };
    for (final entry in stored.entries) {
      await _secureStorage.write(key: entry.key, value: entry.value);
    }
    if (fullNode) {
      return SwapChainConfig(
        wif: wif,
        rpcUrl: nodeUrl,
        rpcUser: nodeUser,
        rpcPassword: nodePassword,
      );
    }
    return SwapChainConfig(
      wif: wif,
      servers: _serverLists[chain]!,
      minServers: int.tryParse(quorum),
      checkpointHeight: int.tryParse(checkpointHeight),
      checkpointHash: checkpointHash,
    );
  }

  Future<String?> _saveConfig() async {
    final chains = <String, SwapChainConfig>{};

    if (!_isTestnet) {
      for (final chain in SwapConfigService.utxoSwapChains) {
        final utxoChain = await _saveUtxoChain(chain);
        if (utxoChain != null) chains[chain] = utxoChain;
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
    final ok = await _swapService.startDaemon(
      configPath: configPath,
      testnet: _isTestnet,
    );
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
          _buildSectionHeader('Bitcoin-family chains (BTC, LTC, BCH)'),
          _buildUtxoInfoBox(),
          const SizedBox(height: 8),
          for (final chain in SwapConfigService.utxoSwapChains)
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

  Widget _buildUtxoInfoBox() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppTheme.infoColor.withOpacity(0.1),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppTheme.infoColor.withOpacity(0.3)),
    ),
    child: Text(
      'Buying XFG with BTC, LTC or BCH locks coins, which needs a local full '
      'node with its wallet loaded. SPV only verifies and claims a lock when '
      'selling XFG, and needs three Electrum servers run by different '
      'operators plus a checkpoint block. KMD and DCR swaps are not offered: '
      'neither has an SPV header validator or a gated full-node path.',
      style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
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
            _utxoFullNode[chain]!
                ? '${info['desc']} \u00b7 full node'
                : '${info['desc']} \u00b7 SPV, ${_serverLists[chain]!.length} server(s)',
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
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Full node')),
                    ButtonSegment(value: false, label: Text('SPV (sell XFG)')),
                  ],
                  selected: {_utxoFullNode[chain]!},
                  onSelectionChanged: (selection) =>
                      setState(() => _utxoFullNode[chain] = selection.first),
                ),
                const SizedBox(height: 12),
                if (_utxoFullNode[chain]!)
                  ..._buildNodeFields(chain)
                else
                  ..._buildSpvFields(chain),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _labeledField(
    String label,
    TextEditingController controller, {
    String? hint,
    bool obscure = false,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboard,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
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
  );

  List<Widget> _buildNodeFields(String chain) => [
    _labeledField(
      'Node RPC URL (this machine only)',
      _nodeUrlControllers[chain]!,
      hint: 'http://127.0.0.1:port',
    ),
    _labeledField('RPC user', _nodeUserControllers[chain]!),
    _labeledField(
      'RPC password',
      _nodePasswordControllers[chain]!,
      obscure: true,
    ),
  ];

  List<Widget> _buildSpvFields(String chain) => [
    _labeledField(
      'Quorum (servers that must agree, at least 2)',
      _quorumControllers[chain]!,
      keyboard: TextInputType.number,
    ),
    _labeledField(
      'Checkpoint height',
      _checkpointHeightControllers[chain]!,
      keyboard: TextInputType.number,
    ),
    _labeledField('Checkpoint block hash', _checkpointHashControllers[chain]!),
    ..._buildServerList(chain),
  ];

  List<Widget> _buildServerList(String chain) => [
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
              onPressed: () =>
                  setState(() => _serverLists[chain]!.removeAt(entry.key)),
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
                borderSide: BorderSide(color: AppTheme.primaryColor),
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
            if (server.isNotEmpty && !_serverLists[chain]!.contains(server))
              setState(() {
                _serverLists[chain]!.add(server);
                _serverControllers[chain]!.clear();
              });
          },
        ),
      ],
    ),
  ];

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

  String _wifHint(String chain) =>
      chain == 'ltc' ? 'T... (compressed key)' : 'K... / L... (compressed key)';

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

  void _applyGeneratedChain(String chain, Map<String, dynamic> config) {
    final wif = config['${chain}_wif'];
    if (wif is! String) return;
    _wifControllers[chain]!.text = wif;
    _utxoFullNode[chain] = false;
    final servers = <String>[
      for (var i = 0; i < 16; i++)
        if (config['${chain}_spv_server_$i'] is String)
          config['${chain}_spv_server_$i'] as String,
    ];
    if (servers.isNotEmpty) _serverLists[chain] = servers;
    final quorum = config['${chain}_spv_min_servers'];
    if (quorum is int) _quorumControllers[chain]!.text = quorum.toString();
    final height = config['${chain}_spv_checkpoint_height'];
    if (height is int) {
      _checkpointHeightControllers[chain]!.text = height.toString();
    }
    final hash = config['${chain}_spv_checkpoint_hash'];
    if (hash is String) _checkpointHashControllers[chain]!.text = hash;
  }

  Future<void> _generateFreshConfig() async {
    try {
      final result = await Process.run(
        _swapService.findSwapdBinary() ?? 'xfg-swapd',
        ['--generate-spv-config'],
      );
      if (result.exitCode == 0 && mounted) {
        final config = SwapConfigService.parseGeneratedConfig(
          result.stdout.toString(),
        );
        setState(() {
          for (final chain in SwapConfigService.utxoSwapChains) {
            _applyGeneratedChain(chain, config);
          }
          final xfgKey = config['xfg_secret_key'];
          if (xfgKey is String &&
              RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(xfgKey)) {
            _xfgSecretController.text = xfgKey;
          }
        });
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
