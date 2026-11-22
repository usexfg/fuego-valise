import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/screens/startup_route.dart';

void main() {
  test('no stored PIN opens the wallet, not the unlock screen', () {
    expect(
      startupDestination(hasWallet: false, hasPin: false, lockedOut: false),
      StartupDestination.wallet,
    );
  });

  test('a stored PIN on an existing wallet asks to unlock', () {
    expect(
      startupDestination(hasWallet: true, hasPin: true, lockedOut: false),
      StartupDestination.pin,
    );
  });

  test('a wallet with no PIN is not asked for one', () {
    expect(
      startupDestination(hasWallet: true, hasPin: false, lockedOut: false),
      StartupDestination.wallet,
    );
  });

  test('an active lockout still asks for the PIN', () {
    expect(
      startupDestination(hasWallet: false, hasPin: false, lockedOut: true),
      StartupDestination.pin,
    );
  });
}
