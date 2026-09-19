import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../bloc/cd/cd_cubit.dart';
import '../../../models/cd.dart';
import '../../../utils/theme.dart';
import 'create_cd_dialog.dart';
import 'ladder_builder_dialog.dart';

/// HEAT certificates of deposit.
///
/// There is no marketplace here: the only CD endpoint fuegod exposes is
/// /estimate_cd_yield. CD transfer exists as a chain primitive
/// (TransactionInputCommitmentTransfer) but has no RPC surface, so a listing
/// or buy button would call nothing.
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
          ),
          body: _buildBody(context, state),
          floatingActionButton: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FloatingActionButton.extended(
                heroTag: 'ladder',
                onPressed: () => _showDialog(context, const LadderBuilderDialog()),
                backgroundColor: AppTheme.surfaceColor,
                foregroundColor: AppTheme.primaryColor,
                icon: const Icon(Icons.account_tree_outlined),
                label: const Text('Ladder'),
              ),
              const SizedBox(height: 12),
              FloatingActionButton.extended(
                heroTag: 'newCd',
                onPressed: () => _showDialog(context, const CreateCdDialog()),
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

  void _showDialog(BuildContext context, Widget child) {
    showDialog<void>(
      context: context,
      builder: (_) => BlocProvider.value(
        value: context.read<CdCubit>(),
        child: child,
      ),
    );
  }

  Widget _buildBody(BuildContext context, CdState state) {
    if (state.status == CdLoadStatus.loading ||
        state.status == CdLoadStatus.initial) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.status == CdLoadStatus.error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48, color: AppTheme.textMuted),
              const SizedBox(height: 12),
              Text(
                state.error ?? 'Failed to load',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.textMuted),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () => context.read<CdCubit>().loadAll(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final active = state.activeCds;
    final matured = state.maturedCds;

    return RefreshIndicator(
      onRefresh: () => context.read<CdCubit>().loadAll(),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          _YieldPoolCard(pool: state.yieldPool, config: state.config),
          if (matured.isNotEmpty)
            _StatusGroup(
              label: 'Matured',
              icon: Icons.check_circle,
              color: AppTheme.successColor,
              cds: matured,
              state: state,
            ),
          if (active.isNotEmpty)
            _StatusGroup(
              label: 'Active',
              icon: Icons.schedule,
              color: AppTheme.primaryColor,
              cds: active,
              state: state,
            ),
          if (state.myCds.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 64, horizontal: 24),
              child: Column(
                children: [
                  Icon(Icons.savings, size: 64, color: AppTheme.textMuted),
                  SizedBox(height: 12),
                  Text('No CDs yet',
                      style: TextStyle(fontSize: 18, color: AppTheme.textMuted)),
                  SizedBox(height: 4),
                  Text(
                    'Lock ΗΞΔŦ for a fixed term to earn a share of swap-fee revenue.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.textMuted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// CD yield pool backing.
///
/// Shows balances, not a rate. Yield is realized swap-fee revenue
/// distributed per epoch, and a claim is capped by these balances at claim
/// time — so the backing is the only honest headline figure.
class _YieldPoolCard extends StatelessWidget {
  final CdYieldPool? pool;
  final CdConfig config;

  const _YieldPoolCard({required this.pool, required this.config});

  @override
  Widget build(BuildContext context) {
    final p = pool;
    return Container(
      color: AppTheme.surfaceColor,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.savings_outlined,
                  size: 16, color: AppTheme.successColor),
              const SizedBox(width: 6),
              const Text('CD YIELD POOL',
                  style: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1)),
            ],
          ),
          const SizedBox(height: 12),
          if (p == null || !p.poolInfoPresent)
            const Text(
              'Pool backing unavailable from this node.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
            )
          else
            Row(
              children: [
                Expanded(
                  child: _poolFigure('Fee pool', '${p.feePoolBalance} ΗΞΔŦ'),
                ),
                Expanded(
                  child: _poolFigure('APY vault', '${p.cdApyVaultBalance} ΗΞΔŦ'),
                ),
              ],
            ),
          const SizedBox(height: 10),
          Text(
            p?.note.isNotEmpty == true ? p!.note : config.yieldSource,
            style: const TextStyle(
                color: AppTheme.textMuted, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _poolFigure(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                fontFamily: AppTheme.numberFontFamily)),
      ],
    );
  }
}

class _StatusGroup extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final List<CdInfo> cds;
  final CdState state;

  const _StatusGroup({
    required this.label,
    required this.icon,
    required this.color,
    required this.cds,
    required this.state,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Text(label.toUpperCase(),
                  style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5)),
              const Spacer(),
              Text('${cds.length}',
                  style: TextStyle(color: color, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 6),
          ...cds.map((cd) => _CdCard(cd: cd, state: state)),
        ],
      ),
    );
  }
}

class _CdCard extends StatelessWidget {
  final CdInfo cd;
  final CdState state;

  const _CdCard({required this.cd, required this.state});

  bool get _autoRenew => state.autoRenewIds.contains(cd.cdId);
  bool get _renewing => state.renewingIds.contains(cd.cdId);
  String? get _renewError => state.renewErrors[cd.cdId];

  @override
  Widget build(BuildContext context) {
    final color =
        cd.matured ? AppTheme.successColor : AppTheme.primaryColor;

    return Card(
      color: AppTheme.cardColor,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    cd.matured ? 'MATURED' : '${cd.daysToMaturity}d left',
                    style: TextStyle(
                        color: color,
                        fontSize: 10,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                Text('${cd.termEpochs} epochs',
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 11)),
                const Spacer(),
                Flexible(
                  child: Text('${cd.amount} ΗΞΔŦ',
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                          fontFamily: AppTheme.numberFontFamily)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                // Accrued to date, not a rate. Accrual stops at maturity.
                Text('Earned ${cd.accruedInterest} ΗΞΔŦ (${cd.accruedPct}%)',
                    style: const TextStyle(
                        color: AppTheme.successColor, fontSize: 11)),
                const Spacer(),
                Text('${cd.effectiveEpochs} epochs accrued',
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 11)),
              ],
            ),
            if (cd.interestIsCapped) ...[
              const SizedBox(height: 4),
              Text(
                'Capped by the yield pool — the formula would give '
                '${cd.uncappedInterest} ΗΞΔŦ.',
                style: const TextStyle(
                    color: AppTheme.warningColor, fontSize: 10),
              ),
            ],
            if (!cd.matured) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: cd.progress,
                  backgroundColor: AppTheme.surfaceColor,
                  color: color,
                  minHeight: 3,
                ),
              ),
            ],
            const SizedBox(height: 8),
            _autoRenewRow(context),
            if (_renewError != null) ...[
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text('Renewal failed: $_renewError',
                        style: const TextStyle(
                            color: AppTheme.errorColor, fontSize: 10)),
                  ),
                  TextButton(
                    onPressed: () =>
                        context.read<CdCubit>().clearRenewError(cd.cdId),
                    child: const Text('Retry', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ],
            if (cd.matured) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                          _renewing ? null : () => _confirmClaim(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.successColor,
                        side: BorderSide(
                            color:
                                AppTheme.successColor.withValues(alpha: 0.6)),
                      ),
                      child: const Text('Claim', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed:
                          _renewing ? null : () => _confirmRollover(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryColor,
                        foregroundColor: Colors.white,
                      ),
                      child: _renewing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('Roll over',
                              style: TextStyle(fontSize: 12)),
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

  Widget _autoRenewRow(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          height: 24,
          width: 40,
          child: Switch(
            value: _autoRenew,
            onChanged: (v) =>
                context.read<CdCubit>().setAutoRenew(cd.cdId, v),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'Auto-renew at maturity (while the wallet is open)',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmClaim(BuildContext context) async {
    final cubit = context.read<CdCubit>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        title: const Text('Claim CD',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          'Claim ${cd.amount} ΗΞΔŦ principal plus ${cd.accruedInterest} ΗΞΔŦ '
          'interest back to your wallet.\n\n'
          'A network fee is deducted from the payout. This CD stops earning '
          'once claimed.',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: AppTheme.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style:
                ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor),
            child: const Text('Claim'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final result = await cubit.claimCd(cd.cdId);
      messenger.showSnackBar(SnackBar(
        content: Text('Claimed ${result.total} ΗΞΔŦ '
            '(${result.interest} ΗΞΔŦ interest)'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: AppTheme.errorColor,
        content: Text('Claim failed: $e'),
      ));
    }
  }

  Future<void> _confirmRollover(BuildContext context) async {
    final cubit = context.read<CdCubit>();
    final messenger = ScaffoldMessenger.of(context);
    final tiers = cubit.state.config.termTiers;
    final epochBlocks = cubit.state.config.epochBlocks;
    var selected =
        tiers.contains(cd.termEpochs) ? cd.termEpochs : tiers.first;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: AppTheme.cardColor,
          title: const Text('Roll over CD',
              style: TextStyle(color: AppTheme.textPrimary)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Reinvest ${cd.amount} ΗΞΔŦ plus ${cd.accruedInterest} ΗΞΔŦ '
                'interest, less the network fee, into a new term.',
                style: const TextStyle(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 16),
              const Text('New term',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: tiers
                    .map((t) => ChoiceChip(
                          label: Text('$t epochs'),
                          selected: selected == t,
                          selectedColor: AppTheme.primaryColor,
                          labelStyle: TextStyle(
                              color: selected == t
                                  ? Colors.white
                                  : AppTheme.textPrimary),
                          backgroundColor: AppTheme.surfaceColor,
                          onSelected: (_) => setState(() => selected = t),
                        ))
                    .toList(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel',
                  style: TextStyle(color: AppTheme.textSecondary)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor),
              child: const Text('Roll over'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      await cubit.rolloverCd(
        cdId: cd.cdId,
        newTermBlocks: selected * epochBlocks,
      );
      messenger.showSnackBar(
        SnackBar(content: Text('Rolled over into $selected epochs')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: AppTheme.errorColor,
        content: Text('Rollover failed: $e'),
      ));
    }
  }
}
