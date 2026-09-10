import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../bloc/hearth/hearth_cubit.dart';
import '../../../models/candlestick.dart';
import '../../../models/heat_amm.dart';
import '../../../services/price_history_service.dart';
import '../../../utils/hearth_theme.dart';
import '../../../widgets/fuego_chart.dart';
import 'liquidity_dialogs.dart';
import '../../../utils/xfg_ticker.dart';

class HearthScreen extends StatefulWidget {
  const HearthScreen({super.key});

  @override
  State<HearthScreen> createState() => _HearthScreenState();
}

class _HearthScreenState extends State<HearthScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;
  final _amountController = TextEditingController();
  final _priceController = TextEditingController();
  bool _sellXfg = true;
  List<Candlestick>? _candles;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;
  bool _priceUp = true;
  double _lastXfgUsd = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1400),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.35, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    context.read<HearthCubit>().loadPool();
    _amountController.addListener(_updateUsd);
    _loadPriceData();
  }

  Future<void> _loadPriceData() async {
    final candles = await PriceHistoryService().loadAll();
    if (mounted) setState(() => _candles = candles);
  }

  String _amountUsd = '';
  void _updateUsd() {
    final text = _amountController.text.trim();
    final val = double.tryParse(text);
    if (val == null || val == 0) {
      if (_amountUsd.isNotEmpty) setState(() => _amountUsd = '');
      return;
    }
    const heatPegUsd = 1.58;
    if (_sellXfg) {
      final spot =
          double.tryParse(
            context.read<HearthCubit>().state.pool?.price ?? '',
          ) ??
          0;
      setState(
        () => _amountUsd = '\$${(val * spot * heatPegUsd).toStringAsFixed(2)}',
      );
    } else {
      setState(() => _amountUsd = '\$${(val * heatPegUsd).toStringAsFixed(2)}');
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _pulseController.dispose();
    _amountController.removeListener(_updateUsd);
    _amountController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    return BlocBuilder<HearthCubit, HearthState>(
      builder: (context, state) {
        return Scaffold(
          backgroundColor: HearthTheme.bgPure,
          body: state.isLoading
              ? const Center(
                  child: CircularProgressIndicator(
                    color: HearthTheme.askPrimary,
                  ),
                )
              : Column(
                  children: [
                    _buildHeader(state),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
children: [
                    if (_candles != null && _candles!.isNotEmpty)
                      SizedBox(
                        height: screenH * 0.30,
                        child: FuegoChart(
                          candles: _candles!,
                          pair: 'XFG/ΗΞΔŦ',
                          lineColor: HearthTheme.chartLine,
                          bgColor: HearthTheme.bgPure,
                        ),
                      ),
                    if (_candles == null || _candles!.isEmpty)
                      Container(
                        height: screenH * 0.30,
                        color: HearthTheme.bgPure,
                        child: const Center(
                          child: Text(
                            'No chart data',
                            style: TextStyle(
                              color: HearthTheme.textMuted,
                            ),
                          ),
                        ),
                      ),
                    if (state.pool != null)
                      _buildPoolStats(state.pool!),
                            if (state.pool != null) _buildHeatPriceBar(state),
                            const SizedBox(height: 16),
                            _buildTabSection(state),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildHeader(HearthState state) {
    const heatPegUsd = 1.58;
    const xfgHeatRatio = 0.1;
    final heatUsd = heatPegUsd;
    final spot = state.pool?.price;
    final spotNum =
        (spot != null &&
            double.tryParse(spot) != null &&
            double.parse(spot) > 0)
        ? double.parse(spot)
        : xfgHeatRatio;
    final xfgUsd = spotNum * heatUsd;

    if (xfgUsd > _lastXfgUsd && _lastXfgUsd > 0) _priceUp = true;
    if (xfgUsd < _lastXfgUsd && _lastXfgUsd > 0) _priceUp = false;
    _lastXfgUsd = xfgUsd;

    // Candle law: rising = Champagne Gold, falling = Midnight Blue.
    return Container(
      color: HearthTheme.bgDeep,
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top,
        left: 12,
        right: 12,
        bottom: 10,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // XFG-denominated (left) — flexible to prevent overflow
          Flexible(
            flex: 2,
            child: AnimatedBuilder(
              animation: _pulseAnim,
              builder: (context, _) {
                return FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'XFG = \$${xfgUsd.toStringAsFixed(2)}',
                    style: HearthTheme.mono(
                      size: 13,
                      weight: FontWeight.w700,
                      color: HearthTheme.xfgEmber.withValues(
                          alpha: 0.4 + _pulseAnim.value * 0.6),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 6),
          Flexible(child: _metricChip('24h ${_priceUp ? '+' : ''}0.00%', _priceUp ? HearthTheme.askPrimary : HearthTheme.bidPrimary)),
          const SizedBox(width: 6),
          // Center: XFG priced in ΗΞΔŦ — expanded but ellipsized
          Expanded(
            flex: 3,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '1 XFG ≈ ${spotNum.toStringAsFixed(1)} HΞ∆T',
                style: HearthTheme.mono(
                  size: 13,
                  weight: FontWeight.w700,
                  color: HearthTheme.askPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(child: _metricChip(_formatVol(state.pool?.epochSwapFees.toString()), HearthTheme.textSecondary)),
          const SizedBox(width: 6),
          Flexible(
            flex: 2,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                'HΞ∆T ≋ \$${heatUsd.toStringAsFixed(2)}',
                style: HearthTheme.mono(
                  size: 13,
                  weight: FontWeight.w700,
                  color: HearthTheme.heatFlame,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: HearthTheme.mono(
          size: 11,
          weight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  String _formatVol(String? vol) {
    final v = double.tryParse(vol ?? '') ?? 0;
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}K HΞ∆T';
    return '${v.toStringAsFixed(0)} HΞ∆T';
  }

  Widget _buildPoolStats(PoolInfo pool) {
    return Container(
      color: HearthTheme.bgDeep,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          _poolStat('XFG Res', pool.xfgBalance),
          _poolDivider(),
          _poolStat('HΞ∆T Res', pool.heatBalance),
          _poolDivider(),
          _poolStat('LP Shares', pool.heatTotalSupply),
        ],
      ),
    );
  }

  Widget _poolStat(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: HearthTheme.mono(
              size: 11,
              weight: FontWeight.w600,
              color: HearthTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: HearthTheme.label(size: 9)),
        ],
      ),
    );
  }

  Widget _buildHeatPriceBar(HearthState state) {
    const xfgHeatRatio = 0.1;
    final spot = state.pool?.price;
    final spotNum =
        (spot != null &&
            double.tryParse(spot) != null &&
            double.parse(spot) > 0)
        ? double.parse(spot)
        : xfgHeatRatio;

    const heatPegUsd = 1.58;

    final mintRate = (spotNum > 0) ? 1 / spotNum : 10.0;
    final leftLabel = mintRate >= 1
        ? '␉${mintRate.toStringAsFixed(2)}'
        : '${mintRate.toStringAsFixed(2)}𐅪';
    final xfgUsd = spotNum * heatPegUsd;
    final rightLabel = xfgUsd >= 1
        ? '␉${xfgUsd.toStringAsFixed(2)}'
        : '${xfgUsd.toStringAsFixed(2)}𐅪';

    return Container(
      color: HearthTheme.bgDeep,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Current Mint Rate',
                  style: HearthTheme.label(
                    size: 10,
                    color: HearthTheme.textMuted,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$leftLabel HΞ∆T / 1 XFG',
                  style: HearthTheme.mono(
                    size: 15,
                    weight: FontWeight.w700,
                    color: HearthTheme.textWhite,
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 1,
            height: 36,
            color: HearthTheme.divider,
            margin: const EdgeInsets.symmetric(horizontal: 12),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '1 XFG Value',
                  style: HearthTheme.label(
                    size: 10,
                    color: HearthTheme.textMuted,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$rightLabel ≋',
                  style: HearthTheme.mono(
                    size: 15,
                    weight: FontWeight.w700,
                    color: HearthTheme.askPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _poolDivider() {
    return Container(
      width: 1,
      height: 28,
      color: HearthTheme.divider,
      margin: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  Widget _buildTabSection(HearthState state) {
    return Container(
      color: HearthTheme.bgDeep,
      child: Column(
        children: [
          Container(
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: HearthTheme.divider, width: 0.5),
              ),
            ),
            child: TabBar(
              controller: _tabController,
              labelColor: HearthTheme.askPrimary,
              unselectedLabelColor: HearthTheme.textMuted,
              indicatorColor: HearthTheme.askPrimary,
              indicatorSize: TabBarIndicatorSize.label,
              labelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              unselectedLabelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              dividerColor: Colors.transparent,
              tabs: const [
                Tab(text: 'Order Book'),
                Tab(text: 'Trade'),
                Tab(text: 'Liquidity'),
              ],
            ),
          ),
          SizedBox(
            height: 420,
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildOrderBookTab(state),
                _buildTradeTab(state),
                _buildLiquidityTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────── ORDER BOOK ─────────────────────

  Widget _buildOrderBookTab(HearthState state) {
    if (state.orderBookState == null) {
      return const Center(
        child: Text(
          'No order book data',
          style: TextStyle(color: HearthTheme.textMuted, fontSize: 13),
        ),
      );
    }
    final book = state.orderBookState!;
    final maxTotal = book.asks.isNotEmpty
        ? book.asks.map((e) => double.tryParse(e.amount) ?? 0).reduce((a, b) => a > b ? a : b)
        : 1.0;
    final maxBidTotal = book.bids.isNotEmpty
        ? book.bids.map((e) => double.tryParse(e.amount) ?? 0).reduce((a, b) => a > b ? a : b)
        : 1.0;
    final globalMax = maxTotal > maxBidTotal ? maxTotal : maxBidTotal;

    return Column(
      children: [
        _orderBookHeader(),
        Expanded(
          flex: 4,
          child: ListView.builder(
            itemCount: book.asks.length,
            reverse: true,
            itemBuilder: (context, i) =>
                _depthRow(book.asks[i], false, globalMax),
          ),
        ),
        _spreadBar(book, state),
        Expanded(
          flex: 4,
          child: ListView.builder(
            itemCount: book.bids.length,
            itemBuilder: (context, i) =>
                _depthRow(book.bids[i], true, globalMax),
          ),
        ),
      ],
    );
  }

  Widget _orderBookHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Price (HΞ∆T)',
              style: HearthTheme.label(size: 10, color: HearthTheme.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              'Amount (XFG)',
              style: HearthTheme.label(size: 10, color: HearthTheme.textMuted),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            child: Text(
              'Total',
              style: HearthTheme.label(size: 10, color: HearthTheme.textMuted),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _depthRow(OrderBookLevel level, bool isBid, double globalMax) {
    final amount = double.tryParse(level.amount) ?? 0.0;
    final pct = globalMax > 0 ? (amount / globalMax).clamp(0.0, 1.0) : 0.0;
    final color = isBid ? HearthTheme.bidPrimary : HearthTheme.askPrimary;
    final depthColor = isBid ? HearthTheme.bidDepth : HearthTheme.askDepth;
    return Stack(
      children: [
        Positioned.fill(
          child: Align(
            alignment: Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: pct,
              child: Container(color: depthColor),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3.5),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  level.price,
                  style: HearthTheme.mono(
                    size: 12,
                    weight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  level.amount,
                  style: HearthTheme.mono(
                    size: 11,
                    color: HearthTheme.textSecondary,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
              Expanded(
                child: Text(
                  '${level.orderCount}',
                  style: HearthTheme.mono(
                    size: 11,
                    color: HearthTheme.textMuted,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _spreadBar(OrderBookState book, HearthState state) {
    final spot = book.bestAsk?.price ?? book.spread;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        color: HearthTheme.bgCard,
        border: Border(
          top: BorderSide(color: HearthTheme.divider, width: 0.5),
          bottom: BorderSide(color: HearthTheme.divider, width: 0.5),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            spot,
            style: HearthTheme.mono(
              size: 14,
              weight: FontWeight.w700,
              color: HearthTheme.textWhite,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  // ───────────────────── TRADE FORM ─────────────────────

  Widget _buildTradeTab(HearthState state) {
    final isLimit = state.orderType == OrderType.limit;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buySellToggle(state),
          const SizedBox(height: 12),
          _orderTypeRow(state),
          const SizedBox(height: 12),
          _amountInput(state),
          if (isLimit) ...[const SizedBox(height: 10), _limitPriceInput(state)],
          const SizedBox(height: 12),
          _submitButton(state, isLimit),
          if (!isLimit && state.quote != null) ...[
            const SizedBox(height: 10),
            _quoteDisplay(state.quote!, state),
            const SizedBox(height: 8),
            _confirmSwapButton(state),
          ],
        ],
      ),
    );
  }

  Widget _buySellToggle(HearthState state) {
    return Container(
      decoration: BoxDecoration(
        color: HearthTheme.bgInput,
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() {
                _sellXfg = true;
                _amountController.clear();
                _updateUsd();
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: _sellXfg ? HearthTheme.askPrimary : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Sell XFG',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _sellXfg
                        ? HearthTheme.textWhite
                        : HearthTheme.textMuted,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() {
                _sellXfg = false;
                _amountController.clear();
                _updateUsd();
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: !_sellXfg
                      ? HearthTheme.bidPrimary
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Buy XFG',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: !_sellXfg
                        ? HearthTheme.textWhite
                        : HearthTheme.textMuted,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _orderTypeRow(HearthState state) {
    return Row(
      children: [
        _typeChip('Market', state.orderType == OrderType.market, () {
          context.read<HearthCubit>().setOrderType(OrderType.market);
          _priceController.clear();
        }),
        const SizedBox(width: 8),
        _typeChip('Limit', state.orderType == OrderType.limit, () {
          context.read<HearthCubit>().setOrderType(OrderType.limit);
        }),
      ],
    );
  }

  Widget _typeChip(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: active ? HearthTheme.bgElevated : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: active ? HearthTheme.textMuted : HearthTheme.border,
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: active ? HearthTheme.textWhite : HearthTheme.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _amountInput(HearthState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _sellXfg ? 'Sell Amount (XFG)' : 'Sell Amount (HΞ∆T)',
          style: HearthTheme.label(size: 10),
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: HearthTheme.bgInput,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: HearthTheme.border, width: 0.5),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: HearthTheme.mono(
                    size: 15,
                    weight: FontWeight.w600,
                    color: HearthTheme.textWhite,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: '0.00',
                    hintStyle: HearthTheme.mono(
                      size: 15,
                      color: HearthTheme.textDim,
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              if (_amountUsd.isNotEmpty)
                Text(
                  _amountUsd,
                  style: HearthTheme.mono(
                    size: 11,
                    color: HearthTheme.textSecondary,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        _percentShortcuts(),
      ],
    );
  }

  Widget _percentShortcuts() {
    return Row(
      children: [25, 50, 75, 100].map((pct) {
        return Expanded(
          child: GestureDetector(
            onTap: () {
              // percentage of available balance — placeholder for now
            },
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: HearthTheme.bgSurface,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                '$pct%',
                textAlign: TextAlign.center,
                style: HearthTheme.label(
                  size: 10,
                  color: HearthTheme.textSecondary,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _limitPriceInput(HearthState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Limit Price (HΞ∆T per XFG)', style: HearthTheme.label(size: 10)),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: HearthTheme.bgInput,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: HearthTheme.border, width: 0.5),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: TextField(
            controller: _priceController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: HearthTheme.mono(
              size: 15,
              weight: FontWeight.w600,
              color: HearthTheme.textWhite,
            ),
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: state.pool?.price ?? '0.00',
              hintStyle: HearthTheme.mono(size: 15, color: HearthTheme.textDim),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ],
    );
  }

  Widget _submitButton(HearthState state, bool isLimit) {
    final isSell = _sellXfg;
    final color = isSell ? HearthTheme.askPrimary : HearthTheme.bidPrimary;
    return SizedBox(
      height: 44,
      child: ElevatedButton(
        onPressed: () {
          final amount = _amountController.text.trim();
          if (amount.isEmpty) return;
          if (isLimit) {
            final price = _priceController.text.trim();
            if (price.isEmpty) return;
            context.read<HearthCubit>().placeLimitOrder(
              sellXfg: _sellXfg,
              amount: amount,
              price: price,
            );
          } else {
            context.read<HearthCubit>().getQuote(
              sellXfg: _sellXfg,
              amount: amount,
            );
          }
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: HearthTheme.textWhite,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          elevation: 0,
        ),
        child: Text(
          isLimit
              ? (isSell ? 'Place Sell Order' : 'Place Buy Order')
              : (isSell ? 'Swap XFG → HΞ∆T' : 'Swap HΞ∆T → XFG'),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _confirmSwapButton(HearthState state) {
    return SizedBox(
      height: 42,
      child: ElevatedButton(
        onPressed: () {
          final cubit = context.read<HearthCubit>();
          final q = cubit.state.quote!;
          final input = _amountController.text.trim();
          if (input.isEmpty) return;
          cubit.executeSwap(
            sellXfg: _sellXfg,
            inputAmount: input,
            minOutput: q.outputAmount,
          );
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: HearthTheme.bidPrimary,
          foregroundColor: HearthTheme.textWhite,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          elevation: 0,
        ),
        child: const Text(
          'Confirm Swap',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _quoteDisplay(AmmQuote quote, HearthState state) {
    final heatAmount = _sellXfg ? quote.outputAmount : _amountController.text.trim();
    final heatVal = double.tryParse(heatAmount) ?? 0;
    const heatPegUsd = 1.58;
    final usd = heatVal * heatPegUsd;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: HearthTheme.bgCard,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('You receive', style: HearthTheme.label(size: 10)),
              Flexible(
                child: Text(
                  quote.outputAmount,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: HearthTheme.mono(
                    size: 14,
                    weight: FontWeight.w700,
                    color: HearthTheme.textWhite,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '≈ \$${usd.toStringAsFixed(2)}',
                style: HearthTheme.mono(
                  size: 11,
                  color: HearthTheme.textSecondary,
                ),
              ),
              Text(
                'Fee: ${quote.fee}',
                style: HearthTheme.mono(size: 10, color: HearthTheme.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Price Impact', style: HearthTheme.label(size: 9)),
              Text(
                '${(int.tryParse(quote.priceImpactBps) ?? 0) / 100}%',
                style: HearthTheme.mono(
                  size: 10,
                  color: HearthTheme.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ───────────────────── LIQUIDITY ─────────────────────

  Widget _buildLiquidityTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: HearthTheme.bgCard,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'PROVIDE LIQUIDITY',
                      style: HearthTheme.label(
                        size: 10,
                        color: HearthTheme.askPrimary,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: HearthTheme.bidPrimary.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'AUTO-COMPOUND',
                        style: HearthTheme.label(
                          size: 8,
                          color: HearthTheme.bidPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Fees auto-compound into pool reserves. Your LP shares appreciate as the pool earns.',
                  style: HearthTheme.mono(
                    size: 11,
                    color: HearthTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: () => _showAddLiquidity(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: HearthTheme.bidPrimary,
                      side: const BorderSide(
                        color: HearthTheme.bidPrimary,
                        width: 1,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: const Text(
                      'Add Liquidity',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: () => _showRemoveLiquidity(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: HearthTheme.askPrimary,
                      side: const BorderSide(
                        color: HearthTheme.askPrimary,
                        width: 1,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: const Text(
                      'Withdraw Earnings',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  void _showAddLiquidity(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => BlocProvider.value(
        value: context.read<HearthCubit>(),
        child: const AddLiquidityDialog(),
      ),
    );
  }

  void _showRemoveLiquidity(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => BlocProvider.value(
        value: context.read<HearthCubit>(),
        child: const RemoveLiquidityDialog(),
      ),
    );
  }
}
