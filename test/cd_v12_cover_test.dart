import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/bloc/cd/cd_cubit.dart';
import 'package:fuego/screens/fuego/cd/cd_overview_screen.dart';
import 'package:fuego/screens/fuego/cd/cd_v12_cover.dart';
import 'package:fuego/services/fuego_rpc_service.dart';

Widget _overview(CdCubit cubit) => MaterialApp(
  home: BlocProvider<CdCubit>.value(
    value: cubit,
    child: const CdOverviewScreen(),
  ),
);

void main() {
  testWidgets('cover states the terms, fee, yield sources and vault', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: CdV12Cover())),
    );

    expect(find.text('CDs open at v12'), findsOneWidget);
    for (final epochs in [6, 18, 36, 72]) {
      expect(find.text('$epochs epochs'), findsOneWidget);
    }
    expect(find.textContaining('0.25%'), findsOneWidget);
    expect(find.textContaining('paid in XFG'), findsOneWidget);
    expect(find.textContaining('80% of the swap fee'), findsOneWidget);
    expect(find.textContaining('Never from burns'), findsOneWidget);
    expect(find.textContaining('Bonus Vault'), findsWidgets);
    expect(find.textContaining('flat in'), findsOneWidget);
  });

  testWidgets('overview keeps the POOL card and offers no CD actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final cubit = CdCubit(
      FuegoRPCService(),
      backendReady: Completer<void>().future,
    );
    addTearDown(cubit.close);

    await tester.pumpWidget(_overview(cubit));

    expect(find.text('POOL'), findsOneWidget);
    expect(find.text('CDs open at v12'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.text('New CD'), findsNothing);
    expect(find.text('Withdraw'), findsNothing);
  });
}
