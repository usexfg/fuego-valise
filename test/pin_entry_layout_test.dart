import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/screens/auth/pin_entry_screen.dart';
import 'package:fuego/widgets/fuego_logo.dart';

void main() {
  testWidgets('pin screen fits a short window without overflowing', (
    tester,
  ) async {
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details);
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);

    tester.view.physicalSize = const Size(390, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: PinEntryScreen()));
    await tester.pump();

    expect(find.text('Welcome Back'), findsOneWidget);
    expect(find.byType(FuegoLogo), findsOneWidget);
    expect(find.byIcon(Icons.local_fire_department), findsNothing);
    expect(errors.where((e) => e.toString().contains('overflowed')), isEmpty);
  });
}
