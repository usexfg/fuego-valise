import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../bloc/wallet/wallet_cubit.dart';
import '../../../models/heat_amm.dart';
import '../../../utils/theme.dart';
import 'mint_heat_dialog.dart';

class HeatScreen extends StatefulWidget {
  const HeatScreen({super.key});

  @override
  State<HeatScreen> createState() => _HeatScreenState();
}

class _HeatScreenState extends State<HeatScreen> {
  HeatMetrics? _metrics;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMetrics();
  }

  Future<void> _loadMetrics() async {
    setState(() { _loading = true; _error = null; });
    try {
      // Was `context.read<FuegoDaemonClient>()` against
      // services/fuego_daemon_client.dart, but main.dart registers the
      // core/daemon_client.dart class of the same name — the lookup could
      // never resolve. Goes through the wallet proxy now.
      final metrics = await context.read<WalletCubit>().getHeatMetrics();
      if (!mounted) return;
      setState(() { _metrics = metrics; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('ΗΞΔŦ Stablecoin'),
        backgroundColor: AppTheme.surfaceColor,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadMetrics,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off, size: 48, color: AppTheme.textMuted),
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: AppTheme.textMuted)),
                      const SizedBox(height: 12),
                      ElevatedButton(onPressed: _loadMetrics, child: const Text('Retry')),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadMetrics,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildPiDashboard(),
                      const SizedBox(height: 16),
                      _buildSupplyCard(),
                      const SizedBox(height: 16),
                      _buildTreasuryCard(),
                      const SizedBox(height: 16),
                      _buildPoolCard(),
                      const SizedBox(height: 16),
                      _buildMintAction(),
                    ],
                  ),
                ),
    );
  }

  Widget _buildPiDashboard() {
    final m = _metrics!;
    return Card(
      color: AppTheme.cardColor,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Text('PI Controller', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _metricColumn('Target', m.piTarget, AppTheme.textMuted),
                _metricColumn('Price', m.redemptionPrice, AppTheme.primaryColor),
                _metricColumn('APY', m.cdYield, AppTheme.successColor),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSupplyCard() {
    return Card(
      color: AppTheme.cardColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Supply', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textMuted)),
            const SizedBox(height: 8),
            Text(_metrics!.supply, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: AppTheme.textPrimary, fontFamily: AppTheme.numberFontFamily)),
            const SizedBox(height: 4),
            Text('ΗΞΔŦ in circulation', style: const TextStyle(color: AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }

  Widget _buildTreasuryCard() {
    return Card(
      color: AppTheme.cardColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Treasury & Yield', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textMuted)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _metricColumn('Treasury', _metrics!.treasury, AppTheme.accentColor)),
                Expanded(child: _metricColumn('CD Yield', _metrics!.cdYield, AppTheme.successColor)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPoolCard() {
    return Card(
      color: AppTheme.cardColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Hearth Pool', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textMuted)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _metricColumn('XFG', _metrics!.poolXfg, AppTheme.primaryColor)),
                Expanded(child: _metricColumn('ΗΞΔŦ', _metrics!.poolHeat, AppTheme.accentColor)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMintAction() {
    return SizedBox(
      height: 52,
      child: ElevatedButton.icon(
        onPressed: () {
          // The dialog reads WalletCubit, which is already above this route
          // in the tree — no local provider needed (and the one that used to
          // be here re-provided a type nothing resolved).
          showDialog<void>(
            context: context,
            builder: (_) => BlocProvider.value(
              value: context.read<WalletCubit>(),
              child: const MintHeatDialog(),
            ),
          ).then((_) => _loadMetrics());
        },
        icon: const Icon(Icons.local_fire_department),
        label: const Text('Mint ΗΞΔŦ', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.primaryColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }

  Widget _metricColumn(String label, String value, Color color) {
    return Column(
      children: [
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: color, fontFamily: AppTheme.numberFontFamily)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
      ],
    );
  }
}
