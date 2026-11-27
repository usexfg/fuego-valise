import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/screens/startup_route.dart';

void main() {
  test('a readable store with no PIN opens the wallet', () {
    expect(
      startupDestination(
        storageReadable: true,
        walletKnown: true,
        hasWallet: false,
        hasPin: false,
        lockedOut: false,
      ),
      StartupDestination.wallet,
    );
  });

  test('a stored PIN on an existing wallet asks to unlock', () {
    expect(
      startupDestination(
        storageReadable: true,
        walletKnown: true,
        hasWallet: true,
        hasPin: true,
        lockedOut: false,
      ),
      StartupDestination.pin,
    );
  });

  test('a wallet with no PIN is not asked for one', () {
    expect(
      startupDestination(
        storageReadable: true,
        walletKnown: true,
        hasWallet: true,
        hasPin: false,
        lockedOut: false,
      ),
      StartupDestination.wallet,
    );
  });

  test('an active lockout still asks for the PIN', () {
    expect(
      startupDestination(
        storageReadable: true,
        walletKnown: true,
        hasWallet: false,
        hasPin: false,
        lockedOut: true,
      ),
      StartupDestination.pin,
    );
  });

  test(
    'an unreadable keyring does not ask for a PIN that cannot be checked',
    () {
      expect(
        startupDestination(
          storageReadable: false,
          walletKnown: false,
          hasWallet: false,
          hasPin: false,
          lockedOut: false,
        ),
        StartupDestination.wallet,
      );
    },
  );

  test('an unknown wallet check still requires the PIN', () {
    expect(
      startupDestination(
        storageReadable: true,
        walletKnown: false,
        hasWallet: false,
        hasPin: false,
        lockedOut: false,
      ),
      StartupDestination.pin,
    );
  });
}
