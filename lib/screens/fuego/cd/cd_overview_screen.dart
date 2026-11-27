import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../bloc/cd/cd_cubit.dart';
import '../../../utils/theme.dart';
import 'cd_v12_cover.dart';

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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
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
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _PoolSummary(state),
              const SizedBox(height: 8),
              const CdV12Cover(),
            ],
          ),
        );
      },
    );
  }
}


