import 'package:flutter/material.dart';

import '../../bloc/portfolio/portfolio_cubit.dart';
import '../../models/candlestick.dart';
import '../../models/chain_info.dart';
import '../../models/portfolio.dart';
import 'trading_chart.dart';
import 'trading_series.dart';
import 'trading_style.dart';

/// Trailing slide-out. Trading density on purpose: this is the surface that
/// is allowed to look like a broker, and it closes back onto the maison dial.
class PortfolioSheet extends StatefulWidget {
  const PortfolioSheet({
    super.key,
    required this.portfolio,
    required this.valuation,
    required this.xfgAmount,
    required this.heatTotal,
    required this.heatUnlocked,
    required this.heatLocked,
    required this.heatKnown,
    required this.masked,
    required this.candles,
    required this.historyLoading,
    required this.onClose,
    required this.onToggleMask,
    required this.onRefresh,
    required this.onManage,
    required this.onSend,
    required this.onReceive,
    required this.onMint,
  });

  final PortfolioState portfolio;
  final PortfolioValuation valuation;
  final double xfgAmount;
  final double heatTotal;
  final double heatUnlocked;
  final double heatLocked;
  final bool heatKnown;
  final bool masked;
  final List<Candlestick> candles;
  final bool historyLoading;
  final VoidCallback onClose;
  final VoidCallback onToggleMask;
  final VoidCallback onRefresh;
  final VoidCallback onManage;
  final VoidCallback onSend;
  final VoidCallback onReceive;
  final VoidCallback onMint;

  @override
  State<PortfolioSheet> createState() => _PortfolioSheetState();
}

class _PortfolioSheetState extends State<PortfolioSheet> {
  bool _showEmpty = false;
  late bool _masked = widget.masked;

  void _toggleMask() {
    setState(() => _masked = !_masked);
    widget.onToggleMask();
  }

  String _amount(double value, {int digits = 4}) {
    if (_masked) return '••••';
    if (value == 0) return '0';
    return groupThousands(value.toStringAsFixed(digits));
  }

  String _usd(double? value) {
    if (_masked) return '••••';
    if (value == null) return '—';
    return '\$${groupThousands(value.toStringAsFixed(2))}';
  }

  @override
  Widget build(BuildContext context) {
    final portfolio = widget.portfolio;
    final held = portfolio.heldHoldings;
    final chainRows = _showEmpty ? portfolio.allHoldings : held;
    final spot = portfolio.price?.xfgSpotUsd;
    final peg = portfolio.price?.heatPegUsd;

    return Material(
      color: TradingStyle.background,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: TradingStyle.hairline)),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _header(spot, peg),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  children: [
                    TradingChart(
                      candles: widget.candles,
                      loading: widget.historyLoading,
                      color: ChainInfo.colors['XFG'],
                    ),
                    // Grab strip: the plot owns its touches, so the sheet
                    // scrolls from here down.
                    const SizedBox(height: 36),
                    _sectionLabel(
                      'POSITIONS',
                      trailing: portfolio.chainsLoaded
                          ? '${held.length} chains'
                          : null,
                    ),
                    _position(
                      ticker: 'XFG',
                      name: 'Fuego',
                      amount: _amount(widget.xfgAmount, digits: 4),
                      value: widget.valuation.isPriced
                          ? _usd(widget.valuation.xfgUsd)
                          : '—',
                      mark: const Color(0xFFE8622C),
                    ),
                    _position(
                      ticker: 'HEAT',
                      name: widget.heatKnown
                          ? 'Reserve'
                          : 'Balance not reported',
                      amount: widget.heatKnown
                          ? _amount(widget.heatTotal)
                          : '—',
                      value: widget.valuation.isPriced && widget.heatKnown
                          ? _usd(widget.valuation.heatUsd)
                          : '—',
                      mark: const Color(0xFF9FD4DE),
                    ),
                    if (widget.heatKnown && widget.heatLocked > 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 34, bottom: 4),
                        child: Text(
                          'Unlocked ${_amount(widget.heatUnlocked)} · on deposit ${_amount(widget.heatLocked)}',
                          style: TradingStyle.caption(size: 10),
                        ),
                      ),
                    const SizedBox(height: 6),
                    _sectionLabel('OTHER CHAINS'),
                    if (!portfolio.hasAccount && portfolio.chainsLoaded)
                      _notice(
                        'No EVM wallet on this device. One key addresses every chain.',
                        action: 'CREATE WALLET',
                        onTap: widget.onManage,
                      )
                    else if (portfolio.chainsError != null)
                      _notice(
                        portfolio.chainsError!,
                        action: 'RETRY',
                        onTap: widget.onRefresh,
                      )
                    else if (!portfolio.chainsLoaded)
                      _reading(portfolio)
                    else if (chainRows.isEmpty)
                      _notice(
                        'Nothing held across ${portfolio.chainsTotal} chains.',
                        action: 'SHOW ALL',
                        onTap: () => setState(() => _showEmpty = true),
                      )
                    else
                      ...chainRows.map(_chainRow),
                    if (portfolio.chainsLoaded && held.isNotEmpty)
                      GestureDetector(
                        onTap: () => setState(() => _showEmpty = !_showEmpty),
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            _showEmpty
                                ? 'HIDE EMPTY'
                                : 'SHOW ALL ${portfolio.chainsTotal}',
                            style: TradingStyle.caption(
                              color: TradingStyle.accent,
                            ),
                          ),
                        ),
                      ),
                    if (portfolio.unreadableChainCount > 0)
                      Text(
                        '${portfolio.unreadableChainCount} unreadable — shown as —',
                        style: TradingStyle.caption(size: 10),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      'SOL · no Solana key on this device',
                      style: TradingStyle.caption(size: 10),
                    ),
                  ],
                ),
              ),
              _actions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(double? spot, double? peg) {
    final valuation = widget.valuation;
    final figure = _masked
        ? '••••••'
        : valuation.isPriced
        ? '\$${groupThousands(valuation.totalUsd.toStringAsFixed(2))}'
        : '—';
    final caption = !valuation.isPriced
        ? (widget.portfolio.priceError ?? 'Waiting for the live price')
        : !valuation.heatKnown
        ? 'XFG priced · HEAT unreadable · chains not in the total'
        : 'XFG + HEAT only · other chains unpriced';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('PORTFOLIO', style: TradingStyle.caption(size: 11)),
              const SizedBox(width: 8),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: valuation.isPriced
                      ? TradingStyle.gain
                      : TradingStyle.muted,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                valuation.isPriced ? 'LIVE' : 'UNPRICED',
                style: TradingStyle.caption(size: 9),
              ),
              const Spacer(),
              _iconTap(
                _toggleMask,
                Icon(
                  _masked
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 16,
                  color: TradingStyle.muted,
                ),
              ),
              _iconTap(
                widget.onRefresh,
                const Icon(Icons.refresh, size: 16, color: TradingStyle.muted),
              ),
              GestureDetector(
                onTap: widget.onClose,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: Text(
                    'FUEGO',
                    style: TradingStyle.caption(
                      size: 11,
                      color: TradingStyle.accent,
                    ),
                  ),
                ),
              ),
            ],
          ),
          Text(figure, style: TradingStyle.figure(size: 26)),
          const SizedBox(height: 2),
          Text(caption, style: TradingStyle.caption()),
          if (spot != null && spot > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'XFG \$${TradingSeries.price(spot)}'
                '${peg != null && peg > 0 ? ' · HEAT \$${TradingSeries.price(peg)}' : ''}',
                style: TradingStyle.caption(size: 10),
              ),
            ),
        ],
      ),
    );
  }

  Widget _iconTap(VoidCallback onTap, Widget icon) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(padding: const EdgeInsets.all(8), child: icon),
    );
  }

  Widget _sectionLabel(String text, {String? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Row(
        children: [
          Text(text, style: TradingStyle.caption(size: 10)),
          const Spacer(),
          if (trailing != null)
            Text(trailing, style: TradingStyle.caption(size: 10)),
        ],
      ),
    );
  }

  Widget _position({
    required String ticker,
    required String name,
    required String amount,
    required String value,
    required Color mark,
  }) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          _mark(mark, ticker),
          const SizedBox(width: 10),
          SizedBox(
            width: 52,
            child: Text(ticker, style: TradingStyle.ticker()),
          ),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TradingStyle.caption(),
            ),
          ),
          const SizedBox(width: 8),
          Text(amount, style: TradingStyle.figure(size: 12)),
          const SizedBox(width: 8),
          Text(
            value,
            style: TradingStyle.figure(
              size: 12,
              color: value == '—' ? TradingStyle.muted : TradingStyle.text,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chainRow(PortfolioHolding holding) {
    final value = '—';
    return _position(
      ticker: holding.ticker,
      name: holding.note ?? holding.name,
      amount: holding.reachable ? _amount(holding.amount, digits: 4) : '—',
      value: value,
      mark: holding.color,
    );
  }

  Widget _mark(Color color, String ticker) {
    final letter = ticker.isEmpty ? '?' : ticker.substring(0, 1);
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.16),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        letter,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }

  Widget _reading(PortfolioState state) {
    final total = state.chainsTotal;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                minHeight: 2,
                value: total == 0 ? null : state.chainsDone / total,
                backgroundColor: TradingStyle.hairline,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  TradingStyle.accent,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Reading ${state.chainsDone}/$total',
            style: TradingStyle.caption(size: 10),
          ),
        ],
      ),
    );
  }

  Widget _notice(String message, {String? action, VoidCallback? onTap}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: TradingStyle.caption()),
          if (action != null && onTap != null)
            TextButton(
              onPressed: onTap,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                action,
                style: TradingStyle.caption(color: TradingStyle.accent),
              ),
            ),
        ],
      ),
    );
  }

  Widget _actions() {
    return Container(
      height: 48,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: TradingStyle.hairline)),
      ),
      child: Row(
        children: [
          _action('SEND', widget.onSend),
          _action('RECEIVE', widget.onReceive),
          _action('MINT', widget.onMint),
        ],
      ),
    );
  }

  Widget _action(String label, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Center(child: Text(label, style: TradingStyle.ticker(size: 12))),
      ),
    );
  }
}
