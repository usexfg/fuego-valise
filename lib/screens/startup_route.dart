/// Where the app goes after splash.
enum StartupDestination { wallet, pin }

/// A PIN prompt is only for a PIN that was actually stored, or for a check
/// that could not prove the wallet is unprotected.
///
/// [storageReadable] false means the keyring never opened. A PIN prompt
/// cannot succeed in that state (verification reads the same store), so a
/// first launch is not asked for a password that was never created.
///
/// When the store did open, an unknown wallet check or an active lockout
/// still requires the PIN. A confirmed empty store does not.
StartupDestination startupDestination({
  required bool storageReadable,
  required bool walletKnown,
  required bool hasWallet,
  required bool hasPin,
  required bool lockedOut,
}) {
  if (!storageReadable) return StartupDestination.wallet;
  if (!walletKnown || lockedOut || (hasWallet && hasPin)) {
    return StartupDestination.pin;
  }
  return StartupDestination.wallet;
}
