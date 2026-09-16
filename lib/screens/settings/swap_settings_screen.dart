import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../services/swap_config_service.dart';
import '../../utils/theme.dart';

const Map<String, List<String>> _defaultServers = {
  'btc': ['electrum.blockstream.info:50002'],
  'ltc': ['ltc.merkle.io:50002'],
  'kmd': ['electrum.komodo.earth:11002'],
  'bch': ['electroncash.org:50002'],
  'dcr': ['localhost:19100'],
};

const Map<String, String> _defaultRpcUrls = {
  'eth': 'https://eth.llamarpc.com', 'arb': 'https://arb1.arbitrum.io/rpc',
  'base': 'https://mainnet.base.org', 'bsc': 'https://bsc-dataseed.binance.org',
  'poly': 'https://polygon-rpc.com', 'sol': 'https://api.mainnet-beta.solana.com',
};

const Map<String, Map<String, String>> _chainInfo = {
  'btc': {'name': 'Bitcoin', 'icon': 'B', 'desc': 'P2WSH SegWit HTLC', 'type': 'spv'},
  'ltc': {'name': 'Litecoin', 'icon': 'L', 'desc': 'P2WSH SegWit HTLC', 'type': 'spv'},
  'kmd': {'name': 'Komodo', 'icon': 'K', 'desc': 'P2SH HTLC', 'type': 'spv'},
  'bch': {'name': 'Bitcoin Cash', 'icon': 'B', 'desc': 'P2SH HTLC', 'type': 'spv'},
  'dcr': {'name': 'Decred', 'icon': 'D', 'desc': 'SPV + RPC HTLC', 'type': 'spv'},
  'eth': {'name': 'Ethereum', 'icon': 'E', 'desc': 'EVM HTLC (web3)', 'type': 'evm'},
  'arb': {'name': 'Arbitrum', 'icon': 'A', 'desc': 'L2 HTLC (web3)', 'type': 'evm'},
  'base': {'name': 'Base', 'icon': 'B', 'desc': 'L2 HTLC (web3)', 'type': 'evm'},
  'bsc': {'name': 'BNB Chain', 'icon': 'B', 'desc': 'EVM HTLC (web3)', 'type': 'evm'},
  'poly': {'name': 'Polygon', 'icon': 'P', 'desc': 'EVM HTLC (web3)', 'type': 'evm'},
  'sol': {'name': 'Solana', 'icon': 'S', 'desc': 'SPL HTLC (web3)', 'type': 'sol'},
  'xmr': {'name': 'Monero', 'icon': 'M', 'desc': 'Daemon + Wallet RPC', 'type': 'rpc'},
};

class SwapSettingsScreen extends StatefulWidget {
  const SwapSettingsScreen({super.key});
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
  bool _swapdRunning = false;
  bool _isStarting = false;
  final _xfgSecretController = TextEditingController();

  @override
  void initState() {
    super.initState();
    for (final chain in ['btc', 'ltc', 'kmd', 'bch', 'dcr']) {
      _wifControllers[chain] = TextEditingController();
      _serverControllers[chain] = TextEditingController();
      _serverLists[chain] = List<String>.from(_defaultServers[chain] ?? []);
    }
    for (final chain in ['eth', 'arb', 'base', 'bsc', 'poly', 'sol']) {
      _wifControllers[chain] = TextEditingController();
      _serverControllers[chain] = TextEditingController();
      _serverLists[chain] = [];
      if (_defaultRpcUrls.containsKey(chain)) _rpcControllers[chain] = TextEditingController(text: _defaultRpcUrls[chain]!);
    }
    _wifControllers['xmr'] = TextEditingController();
    _rpcControllers['xmr_daemon'] = TextEditingController(text: '127.0.0.1');
    _rpcControllers['xmr_wallet'] = TextEditingController(text: '127.0.0.1');
    _loadSavedConfig();
  }

  @override
  void dispose() {
    for (final c in _wifControllers.values) c.dispose();
    for (final c in _serverControllers.values) c.dispose();
    for (final c in _rpcControllers.values) c.dispose();
    _xfgSecretController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedConfig() async {
    for (final chain in ['btc', 'ltc', 'kmd', 'bch', 'dcr']) {
      final wif = await _secureStorage.read(key: 'swap_wif_$chain');
      if (wif != null && wif.isNotEmpty) { _wifControllers[chain]!.text = wif; }
      final serversStr = await _secureStorage.read(key: 'swap_servers_$chain');
      if (serversStr != null && serversStr.isNotEmpty) _serverLists[chain] = serversStr.split(',').where((s) => s.isNotEmpty).toList();
    }
    for (final chain in ['eth', 'arb', 'base', 'bsc', 'poly', 'sol']) {
      final wif = await _secureStorage.read(key: 'swap_wif_$chain');
      if (wif != null && wif.isNotEmpty) { _wifControllers[chain]!.text = wif; }
      final rpcUrl = await _secureStorage.read(key: 'swap_rpc_url_$chain');
      if (rpcUrl != null && rpcUrl.isNotEmpty) _rpcControllers[chain]!.text = rpcUrl;
    }
    final xmrWif = await _secureStorage.read(key: 'swap_wif_xmr');
    if (xmrWif != null && xmrWif.isNotEmpty) { _wifControllers['xmr']!.text = xmrWif; }
    final xmrDaemon = await _secureStorage.read(key: 'swap_xmr_daemon_host');
    if (xmrDaemon != null) _rpcControllers['xmr_daemon']!.text = xmrDaemon;
    final xmrWallet = await _secureStorage.read(key: 'swap_xmr_wallet_host');
    if (xmrWallet != null) _rpcControllers['xmr_wallet']!.text = xmrWallet;
    final xfgKey = await _secureStorage.read(key: 'swap_xfg_secret_key');
    if (xfgKey != null) _xfgSecretController.text = xfgKey;
    _swapdRunning = _swapService.isRunning;
    if (mounted) setState(() {});
  }

  Future<void> _saveConfig() async {
    final chains = <String, SwapChainConfig>{};

    for (final chain in ['btc', 'ltc', 'kmd', 'bch', 'dcr']) {
      final wif = _wifControllers[chain]!.text.trim(); if (wif.isEmpty) continue;
      final error = SwapConfigService.validateWif(wif, chain);
      if (error != null) { _showError('${chain.toUpperCase()} WIF error: $error'); return; }
      await _secureStorage.write(key: 'swap_wif_$chain', value: wif);
      await _secureStorage.write(key: 'swap_servers_$chain', value: _serverLists[chain]!.join(','));
      chains[chain] = SwapChainConfig(wif: wif, servers: _serverLists[chain]!);
    }

    for (final chain in ['eth', 'arb', 'base', 'bsc', 'poly']) {
      final wif = _wifControllers[chain]!.text.trim(); if (wif.isEmpty) continue;
      final rpcUrl = _rpcControllers[chain]?.text.trim() ?? '';
      if (wif.length != 64 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(wif)) { _showError('${chain.toUpperCase()} key must be 64-char hex'); return; }
      await _secureStorage.write(key: 'swap_wif_$chain', value: wif);
      if (rpcUrl.isNotEmpty) await _secureStorage.write(key: 'swap_rpc_url_$chain', value: rpcUrl);
      chains[chain] = SwapChainConfig(wif: wif, rpcUrl: rpcUrl.isNotEmpty ? rpcUrl : null);
    }

    // Solana (base58 keypair)
    final solWif = _wifControllers['sol']!.text.trim();
    if (solWif.isNotEmpty) {
      final rpcUrl = _rpcControllers['sol']?.text.trim() ?? '';
      if (solWif.length < 80) { _showError('SOL keypair must be base58-encoded'); return; }
      await _secureStorage.write(key: 'swap_wif_sol', value: solWif);
      if (rpcUrl.isNotEmpty) await _secureStorage.write(key: 'swap_rpc_url_sol', value: rpcUrl);
      chains['sol'] = SwapChainConfig(wif: solWif, rpcUrl: rpcUrl.isNotEmpty ? rpcUrl : null);
    }

    // Monero
    final xmrSpendKey = _wifControllers['xmr']!.text.trim();
    if (xmrSpendKey.isNotEmpty) {
      if (xmrSpendKey.length != 64 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(xmrSpendKey)) { _showError('XMR spend key must be 64 hex chars'); return; }
      await _secureStorage.write(key: 'swap_wif_xmr', value: xmrSpendKey);
      final daemonHost = _rpcControllers['xmr_daemon']?.text.trim() ?? '127.0.0.1';
      final walletHost = _rpcControllers['xmr_wallet']?.text.trim() ?? '127.0.0.1';
      await _secureStorage.write(key: 'swap_xmr_daemon_host', value: daemonHost);
      await _secureStorage.write(key: 'swap_xmr_wallet_host', value: walletHost);
    }

    final xfgKey = _xfgSecretController.text.trim();
    if (xfgKey.isNotEmpty) await _secureStorage.write(key: 'swap_xfg_secret_key', value: xfgKey);

    if (chains.isEmpty && xmrSpendKey.isEmpty) { _showError('No chains configured — add a key for at least one chain'); return; }

    final configPath = await _swapService.generateConfig(chains: chains, xfgSecretKey: xfgKey.isNotEmpty ? xfgKey : null);
    _showSuccess('Config saved to $configPath');
  }

  void _showError(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppTheme.errorColor));
  }
  void _showSuccess(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppTheme.successColor));
  }

  Future<void> _startSwapd() async {
    setState(() => _isStarting = true);
    await _saveConfig();
    final binary = _swapService.findSwapdBinary();
    if (binary == null) { _showError('xfg-swapd binary not found'); setState(() => _isStarting = false); return; }
    final ok = await _swapService.startDaemon();
    setState(() { _swapdRunning = ok; _isStarting = false; });
    _showSuccess(ok ? 'xfg-swapd started' : 'Failed to start xfg-swapd');
  }

  Future<void> _stopSwapd() async {
    await _swapService.stopDaemon();
    setState(() => _swapdRunning = false);
    _showSuccess('xfg-swapd stopped');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Cross-Chain Swap Settings'), elevation: 0, backgroundColor: Colors.transparent, actions: [
      if (_swapdRunning) Padding(padding: const EdgeInsets.only(right: 8), child: IconButton(icon: const Icon(Icons.stop_circle, color: AppTheme.errorColor), onPressed: _stopSwapd, tooltip: 'Stop xfg-swapd'))
      else Padding(padding: const EdgeInsets.only(right: 8), child: IconButton(
        icon: _isStarting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_circle, color: AppTheme.successColor),
        onPressed: _isStarting ? null : _startSwapd, tooltip: 'Start xfg-swapd')),
    ]),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      _buildStatusBanner(), const SizedBox(height: 20),
      _buildInfoBox(), const SizedBox(height: 24),
      _buildSectionHeader('Fuego (XFG)'), _buildXfgKeyTile(), const SizedBox(height: 24),
      _buildSectionHeader('SPV Chains (BTC, LTC, KMD, BCH, DCR)'),
      for (final chain in ['btc', 'ltc', 'kmd', 'bch', 'dcr']) _buildChainCard(chain), const SizedBox(height: 24),
      _buildSectionHeader('EVM / Solana / Polygon (Light Client)'),
      _buildEvmInfoBox(), const SizedBox(height: 8),
      for (final chain in ['eth', 'arb', 'base', 'bsc', 'poly', 'sol']) _buildEvmChainCard(chain), const SizedBox(height: 24),
      _buildSectionHeader('Monero (RPC)'), _buildMoneroCard(), const SizedBox(height: 24),
      SizedBox(width: double.infinity, child: ElevatedButton.icon(onPressed: _saveConfig, icon: const Icon(Icons.save), label: const Text('Save Configuration'), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, padding: const EdgeInsets.symmetric(vertical: 14)))),
      const SizedBox(height: 16),
      SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: _generateFreshConfig, icon: const Icon(Icons.vpn_key), label: const Text('Generate Fresh WIFs'), style: OutlinedButton.styleFrom(foregroundColor: AppTheme.warningColor, side: const BorderSide(color: AppTheme.warningColor), padding: const EdgeInsets.symmetric(vertical: 14)))),
      const SizedBox(height: 32),
    ]),
  );

  Widget _buildStatusBanner() => Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), decoration: BoxDecoration(color: (_swapdRunning ? AppTheme.successColor : AppTheme.errorColor).withOpacity(0.15), borderRadius: BorderRadius.circular(12), border: Border.all(color: (_swapdRunning ? AppTheme.successColor : AppTheme.errorColor).withOpacity(0.4))), child: Row(children: [
    Icon(_swapdRunning ? Icons.check_circle : Icons.error_outline, color: _swapdRunning ? AppTheme.successColor : AppTheme.errorColor, size: 20), const SizedBox(width: 12),
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_swapdRunning ? 'xfg-swapd is running' : 'xfg-swapd is not running', style: TextStyle(color: _swapdRunning ? AppTheme.successColor : AppTheme.errorColor, fontWeight: FontWeight.w600)),
      const SizedBox(height: 2),
      Text(_swapdRunning ? 'SPV swaps are available' : 'Start the daemon for SPV cross-chain swaps', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
    ])),
  ]));

  Widget _buildInfoBox() => Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: AppTheme.infoColor.withOpacity(0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.infoColor.withOpacity(0.3))), child: Row(children: [
    const Icon(Icons.info_outline, color: AppTheme.infoColor, size: 20), const SizedBox(width: 12),
    Expanded(child: Text('Import private keys for each chain you want to swap on. SPV chains use Electrum servers. EVM/Solana use public RPC endpoints. Keys stay on-device in secure storage.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
  ]));

  Widget _buildXfgKeyTile() => Container(margin: const EdgeInsets.only(bottom: 16), padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: AppTheme.cardColor, borderRadius: BorderRadius.circular(12)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('Secret Key', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
    TextField(controller: _xfgSecretController, obscureText: true, decoration: InputDecoration(hintText: '64-char hex (from fuego_cli wallet_export)', hintStyle: TextStyle(color: AppTheme.textSecondary.withOpacity(0.5)), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppTheme.textSecondary.withOpacity(0.3))), focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.primaryColor)), suffixIcon: IconButton(icon: const Icon(Icons.visibility, size: 18), onPressed: () => setState(() {}))),
      style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'IBMPlexMono', fontSize: 14)),
    const SizedBox(height: 8),
    Text('Required for signing swap transactions on the Fuego chain.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
  ]));

  Widget _buildEvmInfoBox() => Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: AppTheme.infoColor.withOpacity(0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.infoColor.withOpacity(0.3))), child: Row(children: [
    const Icon(Icons.info_outline, color: AppTheme.infoColor, size: 20), const SizedBox(width: 12),
    Expanded(child: Text('EVM and Solana chains connect to public RPC endpoints (no full node required). Default endpoints use free infrastructure. Point to your own node for higher throughput.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
  ]));

  Widget _buildChainCard(String chain) {
    final info = _chainInfo[chain]!; final hasWif = _wifControllers[chain]!.text.isNotEmpty; final enabled = hasWif;
    return Container(margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: AppTheme.cardColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: enabled ? AppTheme.primaryColor.withOpacity(0.5) : AppTheme.textSecondary.withOpacity(0.2))), child: Theme(data: Theme.of(context).copyWith(dividerColor: Colors.transparent), child: ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16), childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      leading: Container(width: 40, height: 40, decoration: BoxDecoration(color: enabled ? AppTheme.primaryColor.withOpacity(0.15) : AppTheme.surfaceColor, borderRadius: BorderRadius.circular(8)),
        child: Center(child: Text(info['icon']!, style: TextStyle(color: enabled ? AppTheme.primaryColor : AppTheme.textSecondary, fontSize: 18, fontWeight: FontWeight.bold)))),
      title: Row(children: [
        Text(info['name']!, style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)), const SizedBox(width: 8),
        if (hasWif) Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: AppTheme.successColor.withOpacity(0.2), borderRadius: BorderRadius.circular(4)), child: const Text('KEY', style: TextStyle(color: AppTheme.successColor, fontSize: 10, fontWeight: FontWeight.bold))),
      ]),
      subtitle: Text('${info['desc']} \u00b7 ${_serverLists[chain]!.length} server(s)', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      children: [Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Private Key (WIF)', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
        TextField(controller: _wifControllers[chain], obscureText: true, decoration: InputDecoration(hintText: _wifHint(chain), hintStyle: TextStyle(color: AppTheme.textSecondary.withOpacity(0.5), fontFamily: 'IBMPlexMono', fontSize: 13), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppTheme.textSecondary.withOpacity(0.3))), focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.primaryColor)), suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(icon: const Icon(Icons.paste, size: 18), onPressed: () async { final data = await Clipboard.getData('text/plain'); if (data?.text != null) setState(() => _wifControllers[chain]!.text = data!.text!); }, tooltip: 'Paste', padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 40, minHeight: 40, maxWidth: 40, maxHeight: 40)),
          IconButton(icon: const Icon(Icons.content_paste_go, size: 18), onPressed: () => _importFromClipboard(chain), tooltip: 'Import & validate', padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 40, minHeight: 40, maxWidth: 40, maxHeight: 40)),
        ])), style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'IBMPlexMono', fontSize: 13)),
        const SizedBox(height: 8),
        Text('Electrum Servers', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
        ..._serverLists[chain]!.asMap().entries.map((entry) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
          Expanded(child: Text(entry.value, style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'IBMPlexMono', fontSize: 13))),
          IconButton(icon: const Icon(Icons.close, size: 16), color: AppTheme.errorColor, onPressed: () => setState(() => _serverLists[chain]!.removeAt(entry.key))),
        ]))),
        Row(children: [
          Expanded(child: TextField(controller: _serverControllers[chain], decoration: InputDecoration(hintText: 'host:port', hintStyle: TextStyle(color: AppTheme.textSecondary.withOpacity(0.5), fontFamily: 'IBMPlexMono', fontSize: 13), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppTheme.textSecondary.withOpacity(0.3))), focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.primaryColor)), contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)), style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'IBMPlexMono', fontSize: 13))),
          const SizedBox(width: 8),
          IconButton(icon: const Icon(Icons.add, size: 20), color: AppTheme.successColor, onPressed: () { final server = _serverControllers[chain]!.text.trim(); if (server.isNotEmpty && !_serverLists[chain]!.contains(server)) setState(() { _serverLists[chain]!.add(server); _serverControllers[chain]!.clear(); }); }),
        ]),
      ])],
    )));
  }

  Widget _buildEvmChainCard(String chain) {
    final info = _chainInfo[chain]!; final hasWif = _wifControllers[chain]!.text.isNotEmpty; final enabled = hasWif; final isSol = chain == 'sol';
    return Container(margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: AppTheme.cardColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: enabled ? AppTheme.primaryColor.withOpacity(0.5) : AppTheme.textSecondary.withOpacity(0.2))), child: Theme(data: Theme.of(context).copyWith(dividerColor: Colors.transparent), child: ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16), childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      leading: Container(width: 40, height: 40, decoration: BoxDecoration(color: enabled ? AppTheme.primaryColor.withOpacity(0.15) : AppTheme.surfaceColor, borderRadius: BorderRadius.circular(8)),
        child: Center(child: Text(info['icon']!, style: TextStyle(color: enabled ? AppTheme.primaryColor : AppTheme.textSecondary, fontSize: 18, fontWeight: FontWeight.bold)))),
      title: Row(children: [
        Text(info['name']!, style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)), const SizedBox(width: 8),
        if (hasWif) Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: AppTheme.successColor.withOpacity(0.2), borderRadius: BorderRadius.circular(4)), child: const Text('KEY', style: TextStyle(color: AppTheme.successColor, fontSize: 10, fontWeight: FontWeight.bold))),
      ]),
      subtitle: Text('${info['desc']} \u00b7 ${_rpcControllers[chain]?.text.isNotEmpty == true ? 'RPC configured' : 'No RPC'}', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      children: [Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(isSol ? 'Keypair (base58)' : 'Private Key (hex)', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
        TextField(controller: _wifControllers[chain], obscureText: true, decoration: InputDecoration(hintText: isSol ? 'Base58-encoded 64-byte keypair' : '64-char hex private key', hintStyle: TextStyle(color: AppTheme.textSecondary.withOpacity(0.5), fontFamily: 'IBMPlexMono', fontSize: 13), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppTheme.textSecondary.withOpacity(0.3))), focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.primaryColor)), suffixIcon: IconButton(icon: const Icon(Icons.paste, size: 18), onPressed: () async { final data = await Clipboard.getData('text/plain'); if (data?.text != null) setState(() => _wifControllers[chain]!.text = data!.text!); }, tooltip: 'Paste')), style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'IBMPlexMono', fontSize: 13)),
        const SizedBox(height: 12),
        Text(isSol ? 'Solana RPC URL' : 'JSON-RPC Endpoint', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
        TextField(controller: _rpcControllers[chain], decoration: InputDecoration(hintText: _defaultRpcUrls[chain] ?? 'https://...', hintStyle: TextStyle(color: AppTheme.textSecondary.withOpacity(0.5), fontFamily: 'IBMPlexMono', fontSize: 13), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppTheme.textSecondary.withOpacity(0.3))), focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.primaryColor))), style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'IBMPlexMono', fontSize: 13)),
        const SizedBox(height: 8),
        Text('Leave as default to use free public infrastructure.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
      ])],
    )));
  }

  Widget _buildMoneroCard() {
    final hasKey = _wifControllers['xmr']!.text.isNotEmpty; final enabled = hasKey;
    return Container(margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: AppTheme.cardColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: enabled ? AppTheme.primaryColor.withOpacity(0.5) : AppTheme.textSecondary.withOpacity(0.2))), child: Theme(data: Theme.of(context).copyWith(dividerColor: Colors.transparent), child: ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16), childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      leading: Container(width: 40, height: 40, decoration: BoxDecoration(color: enabled ? AppTheme.primaryColor.withOpacity(0.15) : AppTheme.surfaceColor, borderRadius: BorderRadius.circular(8)),
        child: Center(child: Text('M', style: TextStyle(color: enabled ? AppTheme.primaryColor : AppTheme.textSecondary, fontSize: 18, fontWeight: FontWeight.bold)))),
      title: Row(children: [
        const Text('Monero', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)), const SizedBox(width: 8),
        if (hasKey) Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: AppTheme.successColor.withOpacity(0.2), borderRadius: BorderRadius.circular(4)), child: const Text('KEY', style: TextStyle(color: AppTheme.successColor, fontSize: 10, fontWeight: FontWeight.bold))),
      ]),
      subtitle: Text('Daemon + Wallet RPC \u00b7 ${_rpcControllers['xmr_daemon']?.text ?? '127.0.0.1'}', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      children: [Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Spend Key (64 hex)', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
        TextField(controller: _wifControllers['xmr'], obscureText: true, decoration: InputDecoration(hintText: '64-char hex spend key', hintStyle: TextStyle(color: AppTheme.textSecondary.withOpacity(0.5), fontFamily: 'IBMPlexMono', fontSize: 13), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppTheme.textSecondary.withOpacity(0.3))), focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.primaryColor)), suffixIcon: IconButton(icon: const Icon(Icons.paste, size: 18), onPressed: () async { final data = await Clipboard.getData('text/plain'); if (data?.text != null) setState(() => _wifControllers['xmr']!.text = data!.text!); }, tooltip: 'Paste')), style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'IBMPlexMono', fontSize: 13)),
        const SizedBox(height: 12),
        Text('Daemon Host', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
        TextField(controller: _rpcControllers['xmr_daemon'], decoration: InputDecoration(hintText: '127.0.0.1', hintStyle: TextStyle(color: AppTheme.textSecondary.withOpacity(0.5), fontFamily: 'IBMPlexMono', fontSize: 13), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppTheme.textSecondary.withOpacity(0.3))), focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.primaryColor))), style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'IBMPlexMono', fontSize: 13)),
        const SizedBox(height: 12),
        Text('Wallet RPC Host', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)), const SizedBox(height: 8),
        TextField(controller: _rpcControllers['xmr_wallet'], decoration: InputDecoration(hintText: '127.0.0.1', hintStyle: TextStyle(color: AppTheme.textSecondary.withOpacity(0.5), fontFamily: 'IBMPlexMono', fontSize: 13), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppTheme.textSecondary.withOpacity(0.3))), focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppTheme.primaryColor))), style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'IBMPlexMono', fontSize: 13)),
        const SizedBox(height: 8),
        Text('Requires monerod and monero-wallet-rpc running locally.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
      ])],
    )));
  }

  String _wifHint(String chain) {
    switch (chain) {
      case 'btc': return '5... / K... / L... (compressed)';
      case 'ltc': return '6... / T... (compressed)';
      case 'kmd': return '7... / U... (compressed)';
      case 'bch': return '5... / K... / L... (compressed)';
      default: return 'WIF private key';
    }
  }

  void _importFromClipboard(String chain) async {
    final data = await Clipboard.getData('text/plain'); final text = data?.text?.trim();
    if (text == null || text.isEmpty) { _showError('Clipboard is empty'); return; }
    final error = SwapConfigService.validateWif(text, chain);
    if (error != null) { _showError('Invalid WIF: $error'); return; }
    setState(() => _wifControllers[chain]!.text = text);
    _showSuccess('${chain.toUpperCase()} WIF imported and validated');
  }

  Future<void> _generateFreshConfig() async {
    try {
      final result = await Process.run(_swapService.findSwapdBinary() ?? 'xfg-swapd', ['--generate-spv-config']);
      if (result.exitCode == 0 && mounted) {
        final output = result.stdout.toString();
        final jsonStart = output.indexOf('{'); final jsonEnd = output.lastIndexOf('}');
        if (jsonStart >= 0 && jsonEnd > jsonStart) {
          final jsonStr = output.substring(jsonStart, jsonEnd + 1);
          final config = const JsonDecoder().convert(jsonStr) as Map;
          for (final chain in ['btc', 'ltc', 'kmd', 'bch']) {
            final wifKey = '${chain}_wif';
            if (config.containsKey(wifKey)) setState(() { _wifControllers[chain]!.text = config[wifKey] as String; });
            final serverKeys = <String>[];
            for (var i = 0; i < 16; i++) { final key = '${chain}_spv_server_$i'; if (config.containsKey(key)) serverKeys.add(config[key] as String); }
            if (serverKeys.isNotEmpty) setState(() => _serverLists[chain] = serverKeys);
          }
          if (config.containsKey('xfg_secret_key')) setState(() => _xfgSecretController.text = config['xfg_secret_key'] as String);
        }
        _showSuccess('Fresh WIFs generated \u2014 review and save');
      } else { _showError('Failed: ${result.stderr}'); }
    } catch (e) { _showError('Error: $e'); }
  }

  Widget _buildSectionHeader(String title) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)));
}
