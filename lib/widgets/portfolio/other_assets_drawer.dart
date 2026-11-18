import 'package:flutter/material.dart';

import '../../bloc/portfolio/portfolio_cubit.dart';
import '../../models/portfolio.dart';
import 'portfolio_plate.dart';

/// Collapsible drawer under the XFG and ΗΞΔŦ strata holding every other chain
/// the wallet can sign on.
///
/// Rows are read on demand: opening the drawer is what starts the 33-chain
/// sweep, so the home page paints instantly and public RPCs see one pass, not
/// one per rebuild.
class OtherAssetsDrawer extends StatefulWidget {
  const OtherAssetsDrawer({
    super.key,
    required this.state,
    required this.masked,
    required this.onExpand,
    required this.onRefresh,
    required this.onManage,
  });

  final PortfolioState state;
  final bool masked;

  /// First open — kicks off the chain sweep.
  final VoidCallback onExpand;
  final VoidCallback onRefresh;

  /// Opens the EVM wallet manager.
  final VoidCallback onManage;

  @override
  State<OtherAssetsDrawer> createState() => _OtherAssetsDrawerState();
}

class _OtherAssetsDrawerState extends State<OtherAssetsDrawer> {
  bool _open = false;
  bool _showEmpty = false;

  void _toggle() {
    final opening = !_open;
    setState(() => _open = opening);
    if (opening && !widget.state.chainsLoaded) widget.onExpand();
  }

  String _amount(double value) {
    if (widget.masked) return '••••';
    if (value == 0) return '0';
    if (value >= 1000) return groupThousands(value.toStringAsFixed(2));
    if (value >= 1) return groupThousands(value.toStringAsFixed(4));
    return value.toStringAsFixed(6);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final held = state.heldHoldings;
    return PortfolioPlate(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: _toggle,
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Text(
                  'OTHER ASSETS',
                  style: PortfolioStyle.label(
                    size: 9.5,
                    spacing: 3,
                    color: PortfolioStyle.champagne.withValues(alpha: 0.7),
                  ),
                ),
                const Spacer(),
                if (state.chainsLoading)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        PortfolioStyle.champagne.withValues(alpha: 0.55),
                      ),
                    ),
                  )
                else
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 220),
                    child: Icon(
                      Icons.expand_more,
                      size: 16,
                      color: PortfolioStyle.champagne.withValues(alpha: 0.55),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Only the visible side is built: the collapsed drawer must not lay
          // out 33 rows, and the open drawer must not keep the badge strip.
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _open ? _body(state, held) : _summary(held, state),
          ),
        ],
      ),
    );
  }

  // ── Collapsed: chain badges + one line of context ────────────────────

  Widget _summary(List<PortfolioHolding> held, PortfolioState state) {
    final badges = held.isNotEmpty
        ? held.take(5).toList(growable: false)
        : state.allHoldings.take(5).toList(growable: false);
    return Row(
      children: [
        if (badges.isNotEmpty) ...[
          SizedBox(
            width: 18.0 + (badges.length - 1) * 13,
            height: 20,
            child: Stack(
              children: [
                for (var i = 0; i < badges.length; i++)
                  Positioned(
                    left: i * 13.0,
                    child: _ChainDisc(holding: badges[i], size: 20),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Text(
            !state.chainsLoaded
                ? '${state.chainsTotal} chains · tap to read balances'
                : !state.hasAccount
                ? '${state.chainsTotal} chains · no EVM wallet'
                : held.isEmpty
                ? '${state.chainsTotal} chains · nothing held'
                : '${held.length} of ${state.chainsTotal} chains holding',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: PortfolioStyle.label(
              size: 8.5,
              spacing: 1.2,
              color: Colors.white.withValues(alpha: 0.32),
            ),
          ),
        ),
        GestureDetector(
          onTap: widget.onManage,
          behavior: HitTestBehavior.opaque,
          child: Text(
            'MANAGE',
            style: PortfolioStyle.label(
              size: 8,
              spacing: 1.8,
              color: PortfolioStyle.champagne.withValues(alpha: 0.55),
            ),
          ),
        ),
      ],
    );
  }

  // ── Expanded: rows, empty-state toggle, SOL note ─────────────────────

  Widget _body(PortfolioState state, List<PortfolioHolding> held) {
    final rows = _showEmpty ? state.allHoldings : held;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        const PortfolioHairline(opacity: 0.22),
        const SizedBox(height: 4),
        if (!state.hasAccount)
          _notice(
            'No EVM wallet on this device. Create one key and it addresses all '
            '33 chains.',
            action: 'CREATE WALLET',
            onTap: widget.onManage,
          )
        else if (state.chainsError != null)
          _notice(state.chainsError!, action: 'RETRY', onTap: widget.onRefresh)
        else if (state.chainsLoading && held.isEmpty)
          _reading(state)
        else if (rows.isEmpty)
          _notice(
            'Nothing held across ${state.chainsTotal} chains.',
            action: state.chainsLoaded ? 'SHOW ALL' : null,
            onTap: state.chainsLoaded
                ? () => setState(() => _showEmpty = true)
                : null,
          )
        else
          ...rows.map(_row),
        const SizedBox(height: 6),
        if (state.chainsLoaded && held.isNotEmpty)
          GestureDetector(
            onTap: () => setState(() => _showEmpty = !_showEmpty),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                _showEmpty
                    ? 'HIDE EMPTY CHAINS'
                    : 'SHOW ALL ${state.chainsTotal} CHAINS',
                style: PortfolioStyle.label(
                  size: 8,
                  spacing: 1.8,
                  color: PortfolioStyle.champagne.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        if (state.unreadableChainCount > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              '${state.unreadableChainCount} chain'
              '${state.unreadableChainCount == 1 ? '' : 's'} unreadable — balance unknown',
              style: PortfolioStyle.label(
                size: 8,
                spacing: 1,
                color: Colors.white.withValues(alpha: 0.28),
              ),
            ),
          ),
        const SizedBox(height: 2),
        Row(
          children: [
            Icon(
              Icons.info_outline,
              size: 11,
              color: Colors.white.withValues(alpha: 0.22),
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                'SOL · no Solana key in this wallet yet',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: PortfolioStyle.label(
                  size: 8,
                  spacing: 0.8,
                  color: Colors.white.withValues(alpha: 0.26),
                ),
              ),
            ),
            GestureDetector(
              onTap: widget.onManage,
              behavior: HitTestBehavior.opaque,
              child: Text(
                'MANAGE WALLETS',
                style: PortfolioStyle.label(
                  size: 8,
                  spacing: 1.4,
                  color: PortfolioStyle.champagne.withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _reading(PortfolioState state) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                minHeight: 1.5,
                value: state.chainsTotal == 0
                    ? null
                    : state.chainsDone / state.chainsTotal,
                backgroundColor: Colors.white.withValues(alpha: 0.06),
                valueColor: AlwaysStoppedAnimation<Color>(
                  PortfolioStyle.champagne.withValues(alpha: 0.7),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'READING ${state.chainsDone}/${state.chainsTotal}',
            style: PortfolioStyle.label(
              size: 8,
              spacing: 1.2,
              color: Colors.white.withValues(alpha: 0.3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _notice(String message, {String? action, VoidCallback? onTap}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: PortfolioStyle.label(
              size: 9,
              spacing: 0.6,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
          if (action != null && onTap != null) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: onTap,
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: PortfolioStyle.champagne.withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  action,
                  style: PortfolioStyle.label(
                    size: 8,
                    spacing: 2,
                    color: PortfolioStyle.champagne.withValues(alpha: 0.85),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(PortfolioHolding holding) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          _ChainDisc(holding: holding, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  holding.ticker,
                  style: TextStyle(
                    color: PortfolioStyle.platinum.withValues(
                      alpha: holding.isHeld ? 0.92 : 0.55,
                    ),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                    height: 1.1,
                  ),
                ),
                Text(
                  holding.note ?? holding.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PortfolioStyle.label(
                    size: 8.5,
                    spacing: 0.7,
                    color: Colors.white.withValues(alpha: 0.3),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            holding.reachable ? _amount(holding.amount) : '—',
            style: PortfolioStyle.figure(
              size: 11.5,
              color: holding.isHeld
                  ? PortfolioStyle.platinum.withValues(alpha: 0.9)
                  : Colors.white.withValues(alpha: 0.3),
            ),
          ),
        ],
      ),
    );
  }
}

/// Chain mark: the real logo when bundled, otherwise a tinted letter.
class _ChainDisc extends StatelessWidget {
  const _ChainDisc({required this.holding, required this.size});

  final PortfolioHolding holding;
  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = size / 2;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: holding.color.withValues(alpha: 0.16),
        border: Border.all(
          color: holding.color.withValues(alpha: 0.34),
          width: 0.7,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: holding.icon.isEmpty
          ? Center(
              child: Text(
                holding.ticker.substring(0, 1),
                style: TextStyle(
                  color: holding.color,
                  fontSize: radius * 0.8,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
            )
          : Image.asset(
              holding.icon,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stack) => Center(
                child: Text(
                  holding.ticker.substring(0, 1),
                  style: TextStyle(
                    color: holding.color,
                    fontSize: radius * 0.8,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ),
            ),
    );
  }
}
