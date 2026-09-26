import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../bloc/cd/cd_cubit.dart';
import '../../../models/cd.dart';
import '../../../utils/theme.dart';
import 'create_cd_dialog.dart';
import '../../../utils/xfg_ticker.dart';

class CdOverviewScreen extends StatelessWidget {
  const CdOverviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CdCubit, CdState>(
      builder: (context, state) {
        return Scaffold(
          backgroundColor: AppTheme.backgroundColor,
          appBar: AppBar(
            title: const Text('Certificates of Deposit'),
            backgroundColor: AppTheme.surfaceColor,
            actions: [
              if (state.apy != null)
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(right: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.successColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${state.apy!.currentApy.toStringAsFixed(1)}% APY',
                      style: TextStyle(
                        color: AppTheme.successColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        fontFamily: AppTheme.numberFontFamily,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          body: _buildBody(context, state),
          floatingActionButton: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FloatingActionButton.extended(
                heroTag: 'ladder',
                onPressed: () => _showLadderSheet(context),
                backgroundColor: AppTheme.surfaceColor,
                foregroundColor: AppTheme.primaryColor,
                icon: const Icon(Icons.account_tree_outlined),
                label: const Text('Ladder'),
              ),
              const SizedBox(height: 12),
              FloatingActionButton.extended(
                heroTag: 'newCd',
                onPressed: () => _showCreateCdSheet(context),
                backgroundColor: AppTheme.primaryColor,
                icon: const Icon(Icons.add),
                label: const Text('New CD'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, CdState state) {
    if (state.status == CdLoadStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.status == CdLoadStatus.error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: AppTheme.textMuted),
            const SizedBox(height: 12),
            Text(state.error ?? 'Failed to load', style: const TextStyle(color: AppTheme.textMuted)),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => context.read<CdCubit>().loadAll(),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final activeCds = state.myCds.where((cd) => !cd.matured && !cd.forSale).toList()
      ..sort((a, b) => a.blocksToMaturity.compareTo(b.blocksToMaturity));
    final completeCds = state.myCds.where((cd) => cd.matured && !cd.forSale).toList()
      ..sort((a, b) => b.depositHeight.compareTo(a.depositHeight));
    final withdrawnCds = state.myCds.where((cd) => cd.forSale).toList()
      ..sort((a, b) => b.depositHeight.compareTo(a.depositHeight));

    return RefreshIndicator(
      onRefresh: () => context.read<CdCubit>().loadAll(),
      child: CustomScrollView(
        slivers: [
          // ── Marketplace Section ──
          SliverToBoxAdapter(
            child: _MarketplaceSection(listings: state.marketListings),
          ),

          // ── My CDs Section ──
          if (activeCds.isNotEmpty || completeCds.isNotEmpty || withdrawnCds.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                child: Text('MY CDs', style: TextStyle(
                  color: AppTheme.textMuted, fontSize: 12,
                  fontWeight: FontWeight.w600, letterSpacing: 1)),
              ),
            ),

          // Active CDs
          if (activeCds.isNotEmpty)
            SliverToBoxAdapter(
              child: _StatusGroup(
                label: 'Active',
                icon: Icons.schedule,
                color: AppTheme.primaryColor,
                cds: activeCds,
              ),
            ),

          // Complete CDs
          if (completeCds.isNotEmpty)
            SliverToBoxAdapter(
              child: _StatusGroup(
                label: 'Matured',
                icon: Icons.check_circle,
                color: AppTheme.successColor,
                cds: completeCds,
              ),
            ),

          // For Sale CDs
          if (withdrawnCds.isNotEmpty)
            SliverToBoxAdapter(
              child: _StatusGroup(
                label: 'For Sale',
                icon: Icons.store,
                color: AppTheme.accentColor,
                cds: withdrawnCds,
              ),
            ),

          // Empty state
          if (state.myCds.isEmpty && state.marketListings.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.savings, size: 64, color: AppTheme.textMuted),
                    SizedBox(height: 12),
                    Text('No CDs yet', style: TextStyle(fontSize: 18, color: AppTheme.textMuted)),
                    SizedBox(height: 4),
                    Text('Create one or browse the market', style: TextStyle(color: AppTheme.textMuted)),
                  ],
                ),
              ),
            ),

          // Bottom padding for FAB
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
    );
  }

  void _showCreateCdSheet(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => BlocProvider.value(
        value: context.read<CdCubit>(),
        child: const CreateCdDialog(),
      ),
    );
  }

  void _showLadderSheet(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => BlocProvider.value(
        value: context.read<CdCubit>(),
        child: const _LadderBuilderDialog(),
      ),
    );
  }
}

// ── Marketplace Section ──

class _MarketplaceSection extends StatelessWidget {
  final List<CdMarketListing> listings;

  const _MarketplaceSection({required this.listings});

  @override
  Widget build(BuildContext context) {
    // Group by amount bucket
    final buckets = <String, List<CdMarketListing>>{};
    for (final l in listings) {
      final bucket = _amountBucket(l.amount);
      buckets.putIfAbsent(bucket, () => []).add(l);
    }

    // Sort each bucket by blocksRemaining (least to most)
    for (final b in buckets.values) {
      b.sort((a, b) => a.blocksRemaining.compareTo(b.blocksRemaining));
    }

    // Sort buckets by amount
    final sortedBuckets = buckets.entries.toList()
      ..sort((a, b) => _parseBucketAmount(a.key).compareTo(_parseBucketAmount(b.key)));

    return Container(
      color: AppTheme.surfaceColor,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.store, size: 16, color: AppTheme.accentColor),
              const SizedBox(width: 6),
              Text('MARKETPLACE', style: TextStyle(
                color: AppTheme.textMuted, fontSize: 12,
                fontWeight: FontWeight.w600, letterSpacing: 1)),
              const Spacer(),
              if (listings.isNotEmpty)
                Text('${listings.length} listings', style: const TextStyle(
                  color: AppTheme.textMuted, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 12),

          if (listings.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.backgroundColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.storefront, size: 20, color: AppTheme.textMuted),
                  const SizedBox(width: 8),
                  Text('No CDs listed for sale', style: TextStyle(color: AppTheme.textMuted, fontSize: 13)),
                ],
              ),
            )
          else
            ...sortedBuckets.map((entry) => _MarketBucket(
              amount: entry.key,
              listings: entry.value,
            )),
        ],
      ),
    );
  }

  String _amountBucket(String amount) {
    final parsed = double.tryParse(amount.replaceAll(',', '')) ?? 0;
    if (parsed <= 8) return '8 HEAT';
    if (parsed <= 1000) return '1,000 HEAT';
    if (parsed <= 10000) return '10,000 HEAT';
    if (parsed <= 100000) return '100,000 HEAT';
    return '1M HEAT';
  }

  int _parseBucketAmount(String bucket) {
    return int.tryParse(bucket.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  }
}

class _MarketBucket extends StatelessWidget {
  final String amount;
  final List<CdMarketListing> listings;

  const _MarketBucket({required this.amount, required this.listings});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.backgroundColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          // Header row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withOpacity(0.08),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              children: [
                Text(amount, style: TextStyle(
                  color: AppTheme.textPrimary, fontWeight: FontWeight.w600, fontSize: 16, fontFamily: AppTheme.numberFontFamily)),
                const Spacer(),
                Text('${listings.length} ${listings.length == 1 ? 'CD' : 'CDs'}',
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
              ],
            ),
          ),
          // Column headers
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: const [
                Expanded(flex: 2, child: Text('TERM', style: _headerStyle)),
                Expanded(flex: 2, child: Text('AMOUNT', style: _headerStyle)),
                Expanded(flex: 2, child: Text('PRICE', style: _headerStyle)),
                SizedBox(width: 48),
              ],
            ),
          ),
          // Listings
          ...listings.map((l) => _MarketRow(listing: l)),
        ],
      ),
    );
  }
}

const _headerStyle = TextStyle(
  color: AppTheme.textMuted, fontSize: 10,
  fontWeight: FontWeight.w600, letterSpacing: 0.5);

class _MarketRow extends StatelessWidget {
  final CdMarketListing listing;

  const _MarketRow({required this.listing});

  @override
  Widget build(BuildContext context) {
    final daysRemaining = (listing.blocksRemaining / 1440).floor();

    return InkWell(
      onTap: () => context.read<CdCubit>().buyCd(listing.listingId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: AppTheme.surfaceColor, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            Expanded(flex: 2, child: _termWidget(daysRemaining)),
            Expanded(flex: 2, child: Text(listing.amount,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13))),
            Expanded(flex: 2, child: xfgAmount('${listing.price}',
              style: const TextStyle(color: AppTheme.accentColor, fontSize: 13, fontWeight: FontWeight.w600))),
            SizedBox(
              width: 48,
              child: Icon(Icons.chevron_right, color: AppTheme.textMuted, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _termWidget(int days) {
    String label;
    Color color;
    if (days <= 7) {
      label = '${days}d';
      color = AppTheme.successColor;
    } else if (days <= 30) {
      label = '${days}d';
      color = AppTheme.primaryColor;
    } else if (days <= 90) {
      label = '${(days / 30).floor()}mo';
      color = AppTheme.warningColor;
    } else {
      label = '${(days / 30).floor()}mo';
      color = AppTheme.textMuted;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

// ── User's CDs ──

class _StatusGroup extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final List<CdInfo> cds;

  const _StatusGroup({
    required this.label,
    required this.icon,
    required this.color,
    required this.cds,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Text(label.toUpperCase(), style: TextStyle(
                color: color, fontSize: 11,
                fontWeight: FontWeight.w600, letterSpacing: 0.5)),
              const Spacer(),
              Text('${cds.length}', style: TextStyle(color: color, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 6),
          ...cds.map((cd) => _UserCdCard(cd: cd)),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _UserCdCard extends StatelessWidget {
  final CdInfo cd;

  const _UserCdCard({required this.cd});

  /// 8 HEAT CDs run epoch-to-epoch from their start: at the end of the first
  /// epoch they unlock but auto-roll over until the user withdraws them.
  bool get _isAutoRoll {
    final amount = double.tryParse(cd.amount.replaceAll(',', '')) ?? 0;
    return amount == 8 && cd.coin == 'HEAT';
  }

  @override
  Widget build(BuildContext context) {
    final matured = cd.matured;
    final color = matured ? AppTheme.successColor : AppTheme.primaryColor;
    final blocksLeft = cd.blocksToMaturity;
    final totalBlocks = cd.maturityHeight - cd.depositHeight;
    final progress = totalBlocks > 0 ? 1.0 - (blocksLeft / totalBlocks) : 0.0;
    final daysLeft = (blocksLeft / 1440).floor();

    return Card(
      color: AppTheme.cardColor,
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    matured ? 'MATURED' : '${daysLeft}d left',
                    style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                Text(cd.coin, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                if (_isAutoRoll) ...[
                  const SizedBox(width: 6),
                  const Text('AUTO-ROLL',
                    style: TextStyle(color: AppTheme.accentColor, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                ],
                const Spacer(),
                Flexible(
                  child: Text(cd.amount,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600, color: AppTheme.textPrimary, fontFamily: AppTheme.numberFontFamily)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text('${cd.interestRate} APY', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
                const Spacer(),
                Flexible(
                  child: Text('Earned: ${cd.accruedInterest}',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: const TextStyle(color: AppTheme.successColor, fontSize: 11)),
                ),
              ],
            ),
            if (!matured) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  backgroundColor: AppTheme.surfaceColor,
                  color: color,
                  minHeight: 3,
                ),
              ),
            ],
            if (matured) ...[
              const SizedBox(height: 8),
              if (_isAutoRoll)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => context.read<CdCubit>().claimCd(cd.cdId),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    child: const Text('Withdraw', style: TextStyle(fontSize: 12)),
                  ),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => context.read<CdCubit>().claimCd(cd.cdId),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.successColor,
                          side: BorderSide(color: AppTheme.successColor.withOpacity(0.6)),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                        child: const Text('Claim', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => _rollover(context),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                        child: const Text('Rollover', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// Manual rollover for fixed-term CDs: reinvest principal + interest into a
  /// new CD with a selectable term product (6/18/36/72). 8 HEAT CDs auto-roll
  /// and only offer withdraw.
  void _rollover(BuildContext context) {
    final origEpochs = (cd.maturityHeight - cd.depositHeight) ~/ 900;
    showDialog(
      context: context,
      builder: (ctx) {
        int selectedTerm = [6, 18, 36, 72].contains(origEpochs) ? origEpochs : 6;
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            backgroundColor: AppTheme.cardColor,
            title: const Text('Rollover CD', style: TextStyle(color: AppTheme.textPrimary)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Reinvest ${cd.amount} HEAT (plus ${cd.accruedInterest} interest) into a new term.',
                  style: const TextStyle(color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 16),
                const Text('New term', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [6, 18, 36, 72].map((t) => ChoiceChip(
                    label: Text('$t epochs'),
                    selected: selectedTerm == t,
                    selectedColor: AppTheme.primaryColor,
                    labelStyle: TextStyle(color: selectedTerm == t ? Colors.white : AppTheme.textPrimary),
                    backgroundColor: AppTheme.surfaceColor,
                    onSelected: (_) => setState(() => selectedTerm = t),
                  )).toList(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary)),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  final blocks = selectedTerm * 900;
                  context.read<CdCubit>().rolloverCd(cdId: cd.cdId, newTerm: blocks);
                },
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor),
                child: const Text('Rollover'),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Ladder Builder ──

class _LadderRung {
  double amount;
  int termEpochs;
  _LadderRung({required this.amount, required this.termEpochs});
}

class _LadderBuilderDialog extends StatefulWidget {
  const _LadderBuilderDialog();

  @override
  State<_LadderBuilderDialog> createState() => _LadderBuilderDialogState();
}

class _LadderBuilderDialogState extends State<_LadderBuilderDialog> {
  static const _amountTiers = [8.0, 1000.0, 10000.0, 100000.0, 1000000.0];
  static const _amountLabels = ['8', '1,000', '10,000', '100,000', '1M'];
  static const _termOptions = [6, 18, 36, 72];

  final List<_LadderRung> _rungs = [
    _LadderRung(amount: 10000, termEpochs: 6),
    _LadderRung(amount: 10000, termEpochs: 18),
    _LadderRung(amount: 10000, termEpochs: 36),
    _LadderRung(amount: 10000, termEpochs: 72),
  ];
  bool _submitting = false;
  String? _error;

  double get _total => _rungs.fold(0, (s, r) => s + r.amount);

  Future<void> _createLadder() async {
    setState(() { _submitting = true; _error = null; });
    try {
      final cubit = context.read<CdCubit>();
      for (final r in _rungs) {
        final blocks = r.amount == 8.0 ? 900 : r.termEpochs * 900;
        await cubit.createCd(
          coin: 'HEAT',
          amount: r.amount.toStringAsFixed(0),
          durationBlocks: blocks,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() { _submitting = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.cardColor,
      title: const Text('Build CD Ladder', style: TextStyle(color: AppTheme.textPrimary)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Stagger maturities across terms for steady liquidity. Each rung is a separate CD. AI agents can POST the same rung array to cd::create_ladder.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
            const SizedBox(height: 12),
            ..._rungs.asMap().entries.map((entry) {
              final idx = entry.key;
              final rung = entry.value;
              final isAuto = rung.amount == 8.0;
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('Rung ${idx + 1}', style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close, size: 16, color: AppTheme.textMuted),
                          onPressed: _rungs.length > 1 ? () => setState(() => _rungs.removeAt(idx)) : null,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: List.generate(_amountTiers.length, (i) => ChoiceChip(
                        label: Text(_amountLabels[i], style: const TextStyle(fontSize: 11)),
                        selected: rung.amount == _amountTiers[i],
                        selectedColor: AppTheme.primaryColor,
                        labelStyle: TextStyle(color: rung.amount == _amountTiers[i] ? Colors.white : AppTheme.textPrimary),
                        backgroundColor: AppTheme.backgroundColor,
                        onSelected: (_) => setState(() => rung.amount = _amountTiers[i]),
                      )),
                    ),
                    const SizedBox(height: 6),
                    if (isAuto)
                      const Text('Epoch-to-epoch · AUTO-ROLL', style: TextStyle(color: AppTheme.primaryColor, fontSize: 10, fontWeight: FontWeight.w600))
                    else
                      Wrap(
                        spacing: 6,
                        children: _termOptions.map((t) => ChoiceChip(
                          label: Text('$t', style: const TextStyle(fontSize: 11)),
                          selected: rung.termEpochs == t,
                          selectedColor: AppTheme.primaryColor,
                          labelStyle: TextStyle(color: rung.termEpochs == t ? Colors.white : AppTheme.textPrimary),
                          backgroundColor: AppTheme.backgroundColor,
                          onSelected: (_) => setState(() => rung.termEpochs = t),
                        )).toList(),
                      ),
                  ],
                ),
              );
            }),
            TextButton.icon(
              onPressed: () => setState(() => _rungs.add(_LadderRung(amount: 10000, termEpochs: 6))),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add rung', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(height: 8),
            Text('Total: ${_total.toStringAsFixed(0)} HEAT across ${_rungs.length} rungs',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: AppTheme.errorColor, fontSize: 11)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary)),
        ),
        ElevatedButton(
          onPressed: _submitting ? null : _createLadder,
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor),
          child: _submitting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text('Create ${_rungs.length} CDs'),
        ),
      ],
    );
  }
}
