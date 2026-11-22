/// Where the app goes after splash.
enum StartupDestination { wallet, pin }

/// A PIN prompt is only for a PIN that was actually stored.
///
/// Secure storage that cannot be read has nothing to unlock: [hasPin] and
/// [lockedOut] stay false, and the first-run wallet is shown. Asking for a
/// PIN in that case traps a launch where one was never created, because the
/// prompt cannot succeed either.
StartupDestination startupDestination({
  required bool hasWallet,
  required bool hasPin,
  required bool lockedOut,
}) {
  if (lockedOut || (hasWallet && hasPin)) {
    return StartupDestination.pin;
  }
  return StartupDestination.wallet;
}
