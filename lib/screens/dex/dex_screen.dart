import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../bloc/dex/dex_cubit.dart';
import '../../models/candlestick.dart';
import '../../models/swap_models.dart';
import '../../models/chain_info.dart';
import '../../models/erc20_token.dart';
import 'peer_swap_screen.dart';
import '../../services/price_history_service.dart';
import '../../services/web3_multi_chain_service.dart';
import '../../utils/theme.dart';
import '../../widgets/fuego_chart.dart';
import '../tokens/token_overview_screen.dart';
import '../../utils/xfg_ticker.dart';

class DexScreen extends StatefulWidget {
  const DexScreen({super.key});
  @override
  State<DexScreen> createState() => _DexScreenState();
}

class _DexScreenState extends State<DexScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _amountController = TextEditingController();
  final _rateController = TextEditingController();
  final _takerKeyController = TextEditingController();
  final _xmrAddressController = TextEditingController();
  List<Candlestick>? _candles;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadPriceData();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<DexCubit>().init(),
    );
    _takerKeyController.addListener(_onTakerKeyChanged);
  }

  void _onTakerKeyChanged() {
    // Rebuild ERC20 balance tiles when key changes; throttle via setState
    if (mounted) setState(() {});
  }

  Future<void> _loadPriceData() async {
    final candles = await PriceHistoryService().loadAll();
    if (mounted) setState(() => _candles = candles);
  }

  @override
  void dispose() {
    _takerKeyController.removeListener(_onTakerKeyChanged);
    _tabController.dispose();
    _amountController.dispose();
    _rateController.dispose();
    _takerKeyController.dispose();
    _xmrAddressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    return BlocBuilder<DexCubit, DexState>(
      builder: (context, state) => Column(
        children: [
          // Top: chart
          if (_candles != null && _candles!.isNotEmpty)
            SizedBox(
              height: screenH * 0.35,
              child: FuegoChart(
                candles: _candles!,
                pair: 'XFG/${state.selectedPair.ticker}',
              ),
            ),
          if (_candles == null || _candles!.isEmpty)
            Container(
              height: screenH * 0.35,
              color: AppTheme.surfaceColor,
              child: const Center(
                child: Text(
                  'No chart data',
                  style: TextStyle(color: AppTheme.textMuted),
                ),
              ),
            ),
          _buildPairBar(state),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                state.error!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.errorColor,
                  fontSize: 11,
                ),
              ),
            ),
          if (state.lastResult != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                state.lastResult!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.successColor,
                  fontSize: 11,
                ),
              ),
            ),
          _buildTabBar(),
          // Bottom half: tabs area scrolls internally, takes remaining space
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildOrderbook(state),
                _buildTradeForm(state),
                const PeerSwapScreen(),
                _buildRecentTrades(state),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() => Container(
    color: AppTheme.surfaceColor,
    child: TabBar(
      controller: _tabController,
      labelColor: AppTheme.primaryColor,
      unselectedLabelColor: AppTheme.textMuted,
      indicatorColor: AppTheme.primaryColor,
      labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      tabs: const [
        Tab(text: 'Orderbook'),
        Tab(text: 'Accept'),
        Tab(text: 'Direct'),
        Tab(text: 'History'),
      ],
    ),
  );

  Widget _buildPairBar(DexState state) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    color: AppTheme.surfaceColor,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
      children: [
        // Fuego logo + XFG
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.asset(
            'assets/coin icons/xfg.png',
            width: 20,
            height: 20,
            errorBuilder: (_, __, ___) => Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Center(
                child: Text(
                  'FG',
                  style: TextStyle(
                    color: AppTheme.primaryColor,
                    fontSize: 8,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          'XFG',
          style: TextStyle(
            color: AppTheme.primaryColor,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 4),
        const Text(
          '/',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 15),
        ),
        const SizedBox(width: 4),
        // Chain selector button
        GestureDetector(
          onTap: () => _showChainSelector(state),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color:
                  (ChainInfo.colors[state.selectedPair.ticker] ??
                          AppTheme.primaryColor)
                      .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color:
                    (ChainInfo.colors[state.selectedPair.ticker] ??
                            AppTheme.primaryColor)
                        .withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.asset(
                    ChainInfo.icons[state.selectedPair.ticker] ?? '',
                    width: 20,
                    height: 20,
                    errorBuilder: (_, __, ___) => Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color:
                            (ChainInfo.colors[state.selectedPair.ticker] ??
                                    AppTheme.primaryColor)
                                .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Center(
                        child: Text(
                          state.selectedPair.ticker.substring(0, 2),
                          style: TextStyle(
                            color:
                                ChainInfo.colors[state.selectedPair.ticker] ??
                                AppTheme.primaryColor,
                            fontSize: 8,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  state.selectedPair.ticker,
                  style: TextStyle(
                    color:
                        ChainInfo.colors[state.selectedPair.ticker] ??
                        AppTheme.primaryColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color:
                      ChainInfo.colors[state.selectedPair.ticker] ??
                      AppTheme.primaryColor,
                  size: 18,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Chain type badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: AppTheme.primaryColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            ChainInfo.info[state.selectedPair.ticker]?['type'] ?? '',
            style: const TextStyle(
              color: AppTheme.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 4),
        // PTLC lockType badge
        Semantics(
          label: 'Lock type ${state.lastLockType}',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: (state.lastLockType == 'PTLC'
                      ? AppTheme.primaryColor
                      : state.lastLockType == 'BRIDGE'
                          ? AppTheme.primaryVariant
                          : AppTheme.textMuted)
                  .withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: state.lastLockType == 'PTLC'
                    ? AppTheme.primaryColor
                    : state.lastLockType == 'BRIDGE'
                        ? AppTheme.primaryVariant
                        : AppTheme.textMuted,
                width: 0.8,
              ),
            ),
            child: Text(
              state.lastLockType.isEmpty ? 'HTLC' : state.lastLockType,
              style: TextStyle(
                color: state.lastLockType == 'PTLC'
                    ? AppTheme.primaryColor
                    : state.lastLockType == 'BRIDGE'
                        ? AppTheme.primaryVariant
                        : AppTheme.textMuted,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(
            Icons.info_outline,
            size: 18,
            color: AppTheme.textMuted,
          ),
          onPressed: _showChainInfo,
          tooltip: 'Chain details',
        ),
        IconButton(
          icon: const Icon(
            Icons.verified_outlined,
            size: 18,
            color: AppTheme.primaryColor,
          ),
          onPressed: _showPtlcGuide,
          tooltip: 'PTLC guide',
        ),
        const SizedBox(width: 4),
        if (!state.isConnected)
          const Icon(Icons.cloud_off, color: AppTheme.errorColor, size: 16)
        else
          const Icon(Icons.cloud_done, color: AppTheme.successColor, size: 16),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(
            Icons.refresh,
            size: 18,
            color: AppTheme.primaryColor,
          ),
          onPressed: () => context.read<DexCubit>().refresh(),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
      ],
      ),
    ),
  );

  void _showChainSelector(DexState state) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.7,
        ),
        decoration: BoxDecoration(
          color: AppTheme.cardColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textMuted.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Title
            Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  Text(
                    'Select Chain',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Spacer(),
                  Text(
                    'XFG paired',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: AppTheme.surfaceColor),
            // Chain list
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: SwapPairSdk.values.length,
                itemBuilder: (_, i) {
                  final pair = SwapPairSdk.values[i];
                  final ticker = pair.ticker;
                  final name = ChainInfo.names[ticker] ?? ticker;
                  final desc = ChainInfo.desc[ticker] ?? '';
                  final color =
                      ChainInfo.colors[ticker] ?? AppTheme.primaryColor;
                  final info = ChainInfo.info[ticker];
                  final isSelected = pair == state.selectedPair;
                  return InkWell(
                    onTap: () {
                      Navigator.pop(ctx);
                      context.read<DexCubit>().selectPair(pair);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      color: isSelected ? color.withValues(alpha: 0.08) : null,
                      child: Row(
                        children: [
                          // Coin icon
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.asset(
                              ChainInfo.icons[ticker] ?? '',
                              width: 36,
                              height: 36,
                              errorBuilder: (_, __, ___) => Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Center(
                                  child: Text(
                                    ticker.substring(
                                      0,
                                      ticker.length.clamp(0, 2),
                                    ),
                                    style: TextStyle(
                                      color: color,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Name + description
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      name,
                                      style: TextStyle(
                                        color: isSelected
                                            ? color
                                            : AppTheme.textPrimary,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    if (info != null)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          color: color.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          info['type']!,
                                          style: TextStyle(
                                            color: color,
                                            fontSize: 9,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    const SizedBox(width: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: (ChainInfo.isPtlcSupported(ticker)
                                                ? AppTheme.primaryColor
                                                : AppTheme.primaryVariant)
                                            .withValues(alpha: 0.13),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        ChainInfo.isPtlcSupported(ticker) ? 'PTLC' : 'BRIDGE',
                                        style: TextStyle(
                                          color: ChainInfo.isPtlcSupported(ticker)
                                              ? AppTheme.primaryColor
                                              : AppTheme.primaryVariant,
                                          fontSize: 8,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  desc,
                                  style: const TextStyle(
                                    color: AppTheme.textMuted,
                                    fontSize: 11,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (ChainInfo.ptlc[ticker] != null) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    ChainInfo.ptlc[ticker]!,
                                    style: const TextStyle(
                                      color: AppTheme.textMuted,
                                      fontSize: 10,
                                      fontStyle: FontStyle.italic,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ],
                            ),
                          ),
                          // Selected indicator
                          if (isSelected)
                            Icon(
                              Icons.check_circle_rounded,
                              color: color,
                              size: 20,
                            )
                          else
                            Icon(
                              Icons.chevron_right_rounded,
                              color: AppTheme.textMuted.withValues(alpha: 0.4),
                              size: 20,
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            SizedBox(height: MediaQuery.of(ctx).viewInsets.bottom),
          ],
        ),
      ),
    );
  }

  Widget _buildPriceBar(DexState state) {
    final p = state.price;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: AppTheme.surfaceColor.withValues(alpha: 0.4),
      child: Row(
        children: [
          Text(
            'XFG/${state.selectedPair.ticker}',
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          const Spacer(),
          if (p != null) ...[
            Text(
              'Last: ${p.last}',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
            ),
            const SizedBox(width: 12),
            Text(
              '\$${p.last}',
              style: TextStyle(
                color: AppTheme.primaryColor,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                fontFamily: AppTheme.numberFontFamily,
              ),
            ),
          ] else
            const Text(
              '--',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
        ],
      ),
    );
  }

  // ── Orderbook ────────────────────────────────────────────────────

  Widget _buildOrderbook(DexState state) {
    if (!state.isConnected)
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off, color: AppTheme.textMuted, size: 48),
            const SizedBox(height: 16),
            Text(
              'fuego-native DEX',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              state.error ?? 'Connecting to fuegod...',
              style: const TextStyle(color: AppTheme.errorColor, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              'Swap offers sourced from fuego P2P network.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    if (state.isLoading && state.offers.isEmpty)
      return const Center(
        child: CircularProgressIndicator(color: AppTheme.primaryColor),
      );
    if (state.offers.isEmpty)
      return const Center(
        child: Text(
          'No active offers',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 14),
        ),
      );
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.surfaceColor)),
          ),
          child: Row(
            children: [
              Text(
                'OFFERS (${state.offers.length})',
                style: const TextStyle(
                  color: AppTheme.primaryColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                'XFG',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 9),
              ),
              const SizedBox(width: 4),
              const Text(
                'Rate',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 9),
              ),
              const SizedBox(width: 4),
              const Text(
                'Time',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 9),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: state.offers.length,
            itemBuilder: (context, i) => _offerRow(state.offers[i]),
          ),
        ),
      ],
    );
  }

  Widget _offerRow(SwapOfferSdk o) {
    final age = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(o.createdAt * 1000),
    );
    final ageStr = age.inHours > 0
        ? '${age.inHours}h'
        : age.inMinutes > 0
        ? '${age.inMinutes}m'
        : '${age.inSeconds}s';
    final mine =
        o.makerPubKey.isNotEmpty &&
        o.makerPubKey == context.read<DexCubit>().makerPublicKeyHex();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.surfaceColor)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              o.pairLabel,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: xfgAmount(
              '${(o.amount / 1e7).toStringAsFixed(2)}',
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 11),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              o.rateNum > 0 ? (o.rate).toStringAsFixed(4) : '--',
              style: const TextStyle(
                color: AppTheme.primaryColor,
                fontSize: 11,
              ),
            ),
          ),
          Text(
            ageStr,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 9),
          ),
          const SizedBox(width: 8),
          if (mine)
            GestureDetector(
              onTap: () => _cancelOffer(o),
              child: const Text(
                'CANCEL',
                style: TextStyle(
                  color: AppTheme.errorColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            GestureDetector(
              onTap: () => _fillOffer(o),
              child: const Text(
                'FILL',
                style: TextStyle(
                  color: AppTheme.successColor,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _cancelOffer(SwapOfferSdk offer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        title: const Text(
          'Cancel offer?',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: Text(
          'Remove your offer for ${(offer.amount / 1e7).toStringAsFixed(2)} '
          'XFG @ ${offer.rate.toStringAsFixed(4)}?',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Cancel Offer',
              style: TextStyle(color: AppTheme.errorColor),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final cubit = context.read<DexCubit>();
    await cubit.cancelOffer(offerId: offer.offerId);
    if (!mounted) return;
    final st = cubit.state;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(st.error ?? (st.lastResult ?? 'Offer cancelled')),
        backgroundColor: st.error != null
            ? AppTheme.errorColor
            : AppTheme.successColor,
      ),
    );
  }

  void _fillOffer(SwapOfferSdk offer) {
    _amountController.text = (offer.amount / 1e7).toStringAsFixed(4);
    _rateController.text = offer.rateNum > 0
        ? offer.rate.toStringAsFixed(4)
        : '';
    // Record the tapped offer so REQUEST SWAP targets exactly this offer.
    context.read<DexCubit>().selectOffer(offer);
    _tabController.animateTo(1);
  }

  Future<void> _showOfferDetails(SwapOfferSdk offer) async {
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        title: Row(
          children: [
            ClipOval(
              child: Image.asset(
                ChainInfo.icons[offer.sellXfg ? 'XFG' : offer.pair.ticker] ??
                    '',
                width: 28,
                height: 28,
                errorBuilder: (_, __, ___) => Container(
                  width: 28,
                  height: 28,
                  color:
                      ChainInfo.colors[offer.pair.ticker] ??
                      AppTheme.primaryColor,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                offer.sellXfg
                    ? 'Sell XFG → ${offer.pair.ticker}'
                    : 'Buy XFG ← ${offer.pair.ticker}',
                style: const TextStyle(color: AppTheme.textPrimary),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            children: [
              _offerDetailRow('Pair', offer.pairLabel),
              _offerDetailRow(
                'Remaining',
                '${(offer.amount / 1e7).toStringAsFixed(4)} XFG',
              ),
              _offerDetailRow(
                'Rate',
                '${offer.rate.toStringAsFixed(6)} ${offer.pair.ticker}/XFG',
              ),
              _offerDetailRow(
                'XFG per ${offer.pair.ticker}',
                offer.xfgPerCounterparty.toStringAsFixed(8),
              ),
              if (offer.makerPubKey.isNotEmpty)
                _offerDetailRow('Maker', offer.makerPubKey, selectable: true),
              _offerDetailRow('Offer ID', offer.offerId, selectable: true),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: offer.offerId));
              Navigator.pop(dialogContext, 'copy');
            },
            child: const Text('Copy ID'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, 'accept'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.successColor,
              foregroundColor: Colors.white,
            ),
            child: const Text('Accept offer'),
          ),
        ],
      ),
    );
    if (!mounted || action != 'accept') return;
    _fillOffer(offer);
  }

  Widget _offerDetailRow(
    String label,
    String value, {
    bool selectable = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              label,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 11,
                fontFamily: selectable ? 'IBMPlexMono' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Trade Form ───────────────────────────────────────────────────

  Widget _buildTradeForm(DexState state) => SingleChildScrollView(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Trade XFG/${state.selectedPair.ticker}',
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'XFG Amount',
              labelStyle: const TextStyle(color: AppTheme.textSecondary),
              hintText: '100.00',
              hintStyle: TextStyle(
                color: AppTheme.textSecondary.withValues(alpha: 0.5),
              ),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(
                  color: AppTheme.textSecondary.withValues(alpha: 0.3),
                ),
              ),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: AppTheme.primaryColor),
              ),
            ),
            style: const TextStyle(color: AppTheme.textPrimary),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _rateController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Rate (${state.selectedPair.ticker} per XFG)',
              labelStyle: const TextStyle(color: AppTheme.textSecondary),
              hintText: state.price?.ask ?? '0.00',
              hintStyle: TextStyle(
                color: AppTheme.textSecondary.withValues(alpha: 0.5),
              ),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(
                  color: AppTheme.textSecondary.withValues(alpha: 0.3),
                ),
              ),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: AppTheme.primaryColor),
              ),
            ),
            style: const TextStyle(color: AppTheme.textPrimary),
          ),
          const SizedBox(height: 12),
          // Taker key: the funded chain address's private key, used to build the
          // reserve proof (proof-of-funds) when taking an offer. Never persisted.
          // Monero is the exception: no private key ever leaves the user's node —
          // the wallet bridges the proof through monero-wallet-rpc, so only the
          // user's XMR address is needed here.
          if (state.selectedChain != ChainTypeSdk.monero)
            TextField(
              controller: _takerKeyController,
              obscureText: true,
              decoration: InputDecoration(
                labelText:
                    'Your ${state.selectedChain.symbol} private key (for reserve proof)',
                labelStyle: const TextStyle(color: AppTheme.textSecondary),
                hintText: state.selectedChain.isEvm
                    ? '64-hex ETH key'
                    : state.selectedChain == ChainTypeSdk.solana
                    ? 'SOL keypair hex'
                    : 'WIF private key',
                hintStyle: TextStyle(
                  color: AppTheme.textSecondary.withValues(alpha: 0.5),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(
                    color: AppTheme.textSecondary.withValues(alpha: 0.3),
                  ),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: AppTheme.primaryColor),
                ),
              ),
              style: const TextStyle(color: AppTheme.textPrimary),
            ),
          if (state.selectedChain == ChainTypeSdk.monero)
            TextField(
              controller: _xmrAddressController,
              decoration: InputDecoration(
                labelText:
                    'Your XMR address (never leaves your wallet — only a proof is sent)',
                labelStyle: const TextStyle(color: AppTheme.textSecondary),
                hintText: '4… (primary address)',
                hintStyle: TextStyle(
                  color: AppTheme.textSecondary.withValues(alpha: 0.5),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(
                    color: AppTheme.textSecondary.withValues(alpha: 0.3),
                  ),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: AppTheme.primaryColor),
                ),
              ),
              style: const TextStyle(color: AppTheme.textPrimary),
            ),
          const SizedBox(height: 12),
          if (state.selectedChain.isEvm) _buildErc20Balances(state),
          const SizedBox(height: 12),
          // PTLC toggle
          Semantics(
            label: 'Require PTLC toggle',
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.surfaceColor.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.surfaceColor),
              ),
              child: SwitchListTile(
                title: const Text(
                  'Require PTLC (no HTLC fallback)',
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 12, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  ChainInfo.isPtlcSupported(state.selectedPair.ticker)
                      ? 'Enforces per-hop decorrelation + scriptless'
                      : 'This chain is HTLC-only — will abort if on',
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
                ),
                value: state.requirePtlc,
                activeThumbColor: AppTheme.primaryColor,
                onChanged: (v) => context.read<DexCubit>().toggleRequirePtlc(v),
              ),
            ),
          ),
          if (state.requirePtlc && !ChainInfo.isPtlcSupported(state.selectedPair.ticker) && state.selectedPair.ticker != 'XMR' && state.selectedPair.ticker != 'ZANO')
            const Padding(
              padding: EdgeInsets.only(top: 6, left: 4),
              child: Text(
                'This chain will abort when Require PTLC is on — turn it off for BRIDGE mode.',
                style: TextStyle(color: AppTheme.errorColor, fontSize: 10),
              ),
            ),
          if (state.lastPtlcPoint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4, right: 4),
              child: Row(
                children: [
                  const Icon(Icons.key, size: 12, color: AppTheme.textMuted),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'T: ${state.lastPtlcPoint}  •  ${state.lastLockType}',
                      style: const TextStyle(color: AppTheme.textMuted, fontSize: 9, fontFamily: 'IBMPlexMono'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: state.isLoading ? null : () => _submitOffer(state),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: state.isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'POST OFFER',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: state.isLoading ? null : () => _requestSwap(state),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.successColor,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: state.isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'REQUEST SWAP',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (state.price != null) ...[
            Text(
              'Price Info',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            _infoRow('Bid', state.price!.bid),
            _infoRow('Ask', state.price!.ask),
            _infoRow('Last', '\$${state.price!.last}'),
            _infoRow('24h Volume', state.price!.volume24h),
            _infoRow('24h Change', state.price!.change24h),
          ],
        ],
      ),
    ),
  );

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Text(
          label,
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 13,
            fontFamily: AppTheme.numberFontFamily,
          ),
        ),
      ],
    ),
  );

  // ── Recent Trades ────────────────────────────────────────────────

  Widget _buildRecentTrades(DexState state) {
    if (state.recentTrades.isEmpty)
      return const Center(
        child: Text(
          'No recent trades',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 14),
        ),
      );
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.surfaceColor)),
          ),
          child: Row(
            children: [
              const Text(
                'RECENT TRADES',
                style: TextStyle(
                  color: AppTheme.primaryColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                'XFG',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 9),
              ),
              const SizedBox(width: 4),
              const Text(
                'Rate',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 9),
              ),
              const SizedBox(width: 4),
              const Text(
                'Block',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 9),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: state.recentTrades.length,
            itemBuilder: (context, i) => _tradeRow(state.recentTrades[i]),
          ),
        ),
      ],
    );
  }

  Widget _tradeRow(SwapTradeSdk t) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: AppTheme.surfaceColor)),
    ),
    child: Row(
      children: [
        Expanded(
          flex: 2,
          child: xfgAmount(
            '${(t.amount / 1e7).toStringAsFixed(2)}',
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 11),
          ),
        ),
        Expanded(
          flex: 2,
          child: Text(
            t.price > 0 ? (t.amount / t.price).toStringAsFixed(4) : '--',
            style: const TextStyle(color: AppTheme.primaryColor, fontSize: 11),
          ),
        ),
        Expanded(
          flex: 2,
          child: Text(
            '#${t.timestamp}',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
          ),
        ),
      ],
    ),
  );

  void _submitOffer(DexState state) async {
    final amountStr = _amountController.text.trim();
    final rateStr = _rateController.text.trim();
    if (amountStr.isEmpty || rateStr.isEmpty) return;
    final amountXfg = double.tryParse(amountStr);
    final rate = double.tryParse(rateStr);
    if (amountXfg == null || rate == null || amountXfg <= 0 || rate <= 0)
      return;

    final xfgAtomic = (amountXfg * 1e7).round();
    // Form rate = counterparty token per XFG; wire rateNum = XFG per token
    // (matches the orderbook convention used by /getswapprice and the
    // composite price oracle), both scaled by 1e7.
    final rateNum = (1e7 / rate).round();

    final cubit = context.read<DexCubit>();
    await cubit.submitOffer(xfgAmount: xfgAtomic, rateNum: rateNum);
    if (!mounted) return;
    final st = cubit.state;
    final msg = st.error != null
        ? 'Offer failed: ${st.error}'
        : (st.lastResult ?? 'Offer submitted');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: st.error != null
            ? AppTheme.errorColor
            : AppTheme.successColor,
      ),
    );
    if (st.error == null) {
      _amountController.clear();
      _rateController.clear();
    }
  }

  void _requestSwap(DexState state) async {
    final offer =
        state.selectedOffer ??
        (state.offers.isNotEmpty ? state.offers.first : null);
    if (offer == null) return;
    final amountStr = _amountController.text.trim();
    if (amountStr.isEmpty) return;
    final amountXfg = double.tryParse(amountStr);
    if (amountXfg == null || amountXfg <= 0) return;
    final isMonero = state.selectedChain == ChainTypeSdk.monero;
    final takerKey = isMonero
        ? _xmrAddressController.text.trim()
        : _takerKeyController.text.trim();
    context.read<DexCubit>().requestSwap(
      offerId: offer.offerId,
      amount: (amountXfg * 1e7).toInt(),
      takerPubKey: '',
      proofOfFunds: '',
      takerChainKey: takerKey,
    );
    // Don't let the counterparty chain key linger in the widget for the
    // rest of the session.
    if (!isMonero) _takerKeyController.clear();
  }

  // ── ERC20 balances inline (EVM chains) ──────────────────────────────
  Widget _buildErc20Balances(DexState state) {
    final chainKey = _evmChainKey(state.selectedChain);
    if (chainKey == null) return const SizedBox.shrink();
    final tokens = Erc20Registry.forChain(chainKey);
    if (tokens.isEmpty) return const SizedBox.shrink();
    final derived = _deriveEvmAddress(_takerKeyController.text.trim());
    final hasAddr = derived != null && derived.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.surfaceColor),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_balance_wallet, size: 14, color: AppTheme.textMuted),
              const SizedBox(width: 6),
              Text('Stablecoins on ${chainKey.toUpperCase()}', style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
              const Spacer(),
              GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TokenOverviewScreen())),
                child: const Text('Manage →', style: TextStyle(color: AppTheme.primaryColor, fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!hasAddr)
            const Text('Enter your EVM private key above to preview USDT/USDC balances (key stays local).', style: TextStyle(color: AppTheme.textMuted, fontSize: 10)),
          if (hasAddr)
            ...tokens.map((t) => _Erc20BalanceTile(chainKey: chainKey, token: t, holder: derived)),
        ],
      ),
    );
  }

  String? _evmChainKey(ChainTypeSdk c) {
    switch (c) {
      case ChainTypeSdk.ethereum: return 'eth';
      case ChainTypeSdk.arbitrum: return 'arb';
      case ChainTypeSdk.base: return 'base';
      case ChainTypeSdk.bnb: return 'bsc';
      case ChainTypeSdk.polygon: return 'poly';
      default: return null;
    }
  }

  String? _deriveEvmAddress(String pk) {
    final clean = pk.startsWith('0x') ? pk.substring(2) : pk;
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(clean)) return null;
    try {
      // Minimal import-free derivation via web3dart EthPrivateKey is available
      // through the service layer; for UI preview we do a lightweight parse
      // and fall back to null on failure.
      return Web3MultiChainService.deriveAddressFromPrivateKey(pk);
    } catch (_) {
      return null;
    }
  }

  // ── Chain Info Dialog ────────────────────────────────────────────

  void _showChainInfo() {
    final selected = context.read<DexCubit>().state.selectedPair.ticker;
    final entries = ChainInfo.info.entries.toList()
      ..sort((a, b) {
        if (a.key == selected) return -1;
        if (b.key == selected) return 1;
        final aComingSoon = a.value['wired'] == 'false' ? 1 : 0;
        final bComingSoon = b.value['wired'] == 'false' ? 1 : 0;
        if (aComingSoon != bComingSoon) return aComingSoon - bComingSoon;
        return 0;
      });

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.hub_outlined, color: AppTheme.primaryColor, size: 20),
            SizedBox(width: 8),
            Text(
              'Swap Chains',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'All swaps are XFG-paired atomic swaps handled by xfg-swapd.\n',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                ),
                ...entries.map((e) {
                  final info = e.value;
                  final isSelected = e.key == selected;
                  final comingSoon = info['wired'] == 'false';
                  final color =
                      ChainInfo.colors[e.key] ?? AppTheme.primaryColor;
                  final desc = ChainInfo.desc[e.key] ?? '';
                  final row = Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? color.withValues(alpha: 0.08)
                          : AppTheme.surfaceColor.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected
                            ? color.withValues(alpha: 0.3)
                            : AppTheme.surfaceColor,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.asset(
                                ChainInfo.icons[e.key] ?? '',
                                width: 28,
                                height: 28,
                                errorBuilder: (_, __, ___) => Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: color,
                                  ),
                                  child: Center(
                                    child: Text(
                                      e.key.substring(0, 2),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '${e.key} — ${ChainInfo.names[e.key]}',
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 1,
                                          style: TextStyle(
                                            color: isSelected
                                                ? color
                                                : AppTheme.textPrimary,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          color: color.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          info['type'] ?? '',
                                          style: TextStyle(
                                            color: color,
                                            fontSize: 9,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (desc.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      desc,
                                      style: const TextStyle(
                                        color: AppTheme.textMuted,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (isSelected)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppTheme.primaryColor.withValues(
                                    alpha: 0.15,
                                  ),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'ACTIVE',
                                  style: TextStyle(
                                    color: AppTheme.primaryColor,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        if (!comingSoon) ...[
                          const SizedBox(height: 8),
                          _infoRow('Connect', info['connect'] ?? ''),
                          _infoRow('HTLC', info['htlc'] ?? ''),
                          _infoRow('Setup', info['user'] ?? ''),
                        ],
                      ],
                    ),
                  );

                  if (!comingSoon) return row;
                  return Stack(
                    children: [
                      Opacity(opacity: 0.55, child: row),
                      Positioned.fill(
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.cardColor.withValues(alpha: 0.95),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: AppTheme.textMuted.withValues(
                                  alpha: 0.4,
                                ),
                              ),
                            ),
                            child: const Text(
                              'COMING SOON',
                              style: TextStyle(
                                color: AppTheme.textMuted,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Close',
              style: TextStyle(color: AppTheme.primaryColor),
            ),
          ),
        ],
      ),
    );
  }

  void _showPtlcGuide() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.verified_outlined, color: Color(0xFF2E7D32), size: 20),
            SizedBox(width: 8),
            Text('PTLC — Point Locks', style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _ptlcBullet('PTLC', 'Point T=t·G, sig s\'=k+e·sk+t, extract t=s\'-s. Per-hop T_i decorrelated.', AppTheme.primaryColor),
              _ptlcBullet('BRIDGE', 'XFG PTLC + CTR HTLC H(t) + DLEQ Q=t·escrowPub. Current default.', AppTheme.primaryVariant),
              _ptlcBullet('HTLC', 'Legacy hash only. Linkable.', AppTheme.textMuted),
              const SizedBox(height: 12),
              const Text('Require PTLC ON aborts if chain cannot do PTLC. Leave OFF for BRIDGE (works everywhere).', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => launchUrl(Uri.parse('https://github.com/usexfg/fuego-suite/blob/master/docs/PTLC_USER_WALKTHROUGH.md')),
                child: const Text('Open full walkthrough →', style: TextStyle(color: AppTheme.primaryColor, fontSize: 12, fontWeight: FontWeight.w600, decoration: TextDecoration.underline)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: AppTheme.primaryColor)),
          ),
        ],
      ),
    );
  }

  Widget _ptlcBullet(String label, String text, Color color) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4), border: Border.all(color: color, width: 0.7)),
              child: Text(label, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11))),
          ],
        ),
      );
}

class _Erc20BalanceTile extends StatefulWidget {
  final String chainKey;
  final Erc20Token token;
  final String holder;
  const _Erc20BalanceTile({required this.chainKey, required this.token, required this.holder});

  @override
  State<_Erc20BalanceTile> createState() => _Erc20BalanceTileState();
}

class _Erc20BalanceTileState extends State<_Erc20BalanceTile> {
  late Future<String> _future;
  Web3MultiChainService? _w3;

  @override
  void initState() {
    super.initState();
    _w3 = Web3MultiChainService();
    _future = _load();
  }

  Future<String> _load() async {
    try {
      final raw = await _w3!.getErc20Balance(holderAddress: widget.holder, tokenAddress: widget.token.address, chain: widget.chainKey);
      int dec = widget.token.decimals;
      try {
        dec = await _w3!.getErc20Decimals(tokenAddress: widget.token.address, chain: widget.chainKey);
      } catch (_) {}
      final disp = Erc20Amount.fromBaseUnits(raw, dec);
      return disp;
    } catch (e) {
      return '—';
    }
  }

  @override
  void didUpdateWidget(covariant _Erc20BalanceTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.holder != widget.holder || oldWidget.token != widget.token || oldWidget.chainKey != widget.chainKey) {
      _future = _load();
    }
  }

  @override
  void dispose() {
    _w3?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _future,
      builder: (context, snap) {
        final bal = snap.data ?? '...';
        final isLoading = snap.connectionState == ConnectionState.waiting;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Container(
                width: 6, height: 6,
                decoration: BoxDecoration(color: AppTheme.primaryColor.withValues(alpha: 0.7), shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text('${widget.token.symbol}', style: const TextStyle(color: AppTheme.textPrimary, fontSize: 11, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Expanded(
                child: SelectableText(widget.token.address, style: const TextStyle(color: AppTheme.textMuted, fontSize: 9, fontFamily: 'IBMPlexMono')),
              ),
              const SizedBox(width: 8),
              if (isLoading)
                const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: AppTheme.textMuted))
              else
                Text(bal, style: TextStyle(color: AppTheme.textPrimary, fontSize: 12, fontFamily: AppTheme.numberFontFamily, fontWeight: FontWeight.w600)),
            ],
          ),
        );
      },
    );
  }
}
