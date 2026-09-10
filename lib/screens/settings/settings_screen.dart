import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../bloc/wallet/wallet_cubit.dart';
import '../../main.dart' as app;
import '../../providers/wallet_provider.dart';
import '../../services/fuego_rpc_service.dart';
import '../../services/fuego_vault_service.dart';
import '../../services/security_service.dart';
import '../../utils/theme.dart';
import '../main/main_screen.dart';
import 'swap_settings_screen.dart';
import 'alias_registration_screen.dart';
import 'network_selection_screen.dart';
import 'wallets_screen.dart';
import '../../utils/xfg_ticker.dart';

/// Bundled word-font families selectable in Settings > App Font.
/// Numbers always render in Noto Sans ([AppTheme.numberFontFamily]).
const List<({String family, String label, String? note})> fontOptions = [
  (family: 'IBMPlexSans', label: 'IBM Plex Sans', note: 'Sans-serif · default'),
  (family: 'NotoSans', label: 'Noto Sans', note: 'Sans-serif · numbers font'),
  (family: 'IBMPlexMono', label: 'IBM Plex Mono', note: 'Monospace'),
  (family: 'Trirong', label: 'Trirong', note: 'Serif · formal'),
  (family: 'Arimo', label: 'Arimo', note: 'Sans-serif · Arial-metric'),
  (family: 'Bitter', label: 'Bitter', note: 'Slab serif'),
  (family: 'Brygada1918', label: 'Brygada 1918', note: 'Serif · editorial'),
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SecurityService _securityService = SecurityService();
  bool _biometricEnabled = false;
  bool _isLoading = false;
  String _fuegodHost = '207.244.247.64';
  int _fuegodPort = 18180;
  bool _fuegodConfigured = true;
  String _fontFamily = 'IBMPlexSans';

  /// Desktop default = local, mobile default = remote (from [NodeConnection]).
  bool _useLocalNode = app.useLocalNode;

  WalletProvider get walletProvider =>
      Provider.of<WalletProvider>(context, listen: false);

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final biometricEnabled = await _securityService.isBiometricEnabled();
    final ep = app.nodeConnection.lastEndpoints;
    final prefs = await SharedPreferences.getInstance();
    await XfgTicker.load();
    final saved = prefs.getString('app_font_family');
    // Migrate legacy Saira/Electrolize boolean to the Plex default.
    final family = saved ?? 'IBMPlexSans';
    final validFamily = fontOptions.any((f) => f.family == family)
        ? family
        : 'IBMPlexSans';
    AppTheme.fontFamily = validFamily;
    setState(() {
      _biometricEnabled = biometricEnabled;
      _useLocalNode = app.nodeConnection.useLocalNode;
      _fuegodHost = ep?.chainHost ?? app.nodeConnection.remoteHost;
      _fuegodPort = ep?.chainPort ?? app.nodeConnection.remotePort;
      _fuegodConfigured = ep?.proxyRunning == true || ep?.error == null;
      _fontFamily = validFamily;
    });
  }

  Future<void> _toggleBiometric(bool enabled) async {
    if (enabled) {
      final canUseBiometric = await _securityService.isBiometricAvailable();
      if (!canUseBiometric) {
        _showError('Biometric authentication not available on this device');
        return;
      }

      final authenticated = await _securityService.authenticateWithBiometrics(
        reason: 'Enable biometric authentication for Fuego Valise',
      );

      if (!authenticated) {
        return; // User cancelled or authentication failed
      }
    }

    await _securityService.setBiometricEnabled(enabled);
    if (enabled) {
      try {
        await context.read<FuegoVaultService>().ensureBiometricEnvelope();
      } catch (_) {}
    }
    setState(() {
      _biometricEnabled = enabled;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          enabled
              ? 'Biometric authentication enabled'
              : 'Biometric authentication disabled',
        ),
        backgroundColor: AppTheme.successColor,
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppTheme.errorColor),
    );
  }

  Future<void> _setFontFamily(String family) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_font_family', family);
    AppTheme.fontFamily = family;
    setState(() {
      _fontFamily = family;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Font will update on next app launch'),
        ),
      );
    }
  }

  Future<void> _setTickerFont(String family) async {
    await XfgTicker.set(family);
    setState(() {});
  }

  void _showTickerPickerDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            backgroundColor: AppTheme.cardColor,
            title: const Text(
              'XFG Symbol',
              style: TextStyle(color: AppTheme.textPrimary),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final option in XfgTicker.options)
                    RadioListTile<String>(
                      value: option.family,
                      groupValue: XfgTicker.font,
                      onChanged: (value) async {
                        if (value != null) {
                          await _setTickerFont(value);
                          setDialogState(() {});
                        }
                      },
                      title: Text(
                        option.label,
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontFamily:
                              option.family.isEmpty ? null : option.family,
                          fontSize: option.family.isEmpty ? null : 18,
                        ),
                      ),
                      subtitle: option.note != null
                          ? Text(
                              option.note!,
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 13,
                              ),
                            )
                          : null,
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showFontPickerDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: AppTheme.cardColor,
          title: const Text(
            'App Font',
            style: TextStyle(color: AppTheme.textPrimary),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in fontOptions)
                  RadioListTile<String>(
                  value: option.family,
                  groupValue: _fontFamily,
                  onChanged: (value) {
                    if (value != null) {
                      _setFontFamily(value);
                      Navigator.of(context).pop();
                    }
                  },
                  title: Text(
                    option.label,
                    style: const TextStyle(color: AppTheme.textPrimary),
                  ),
                  subtitle: option.note != null
                      ? Text(
                          option.note!,
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 13,
                          ),
                        )
                      : null,
                  activeColor: AppTheme.primaryColor,
                ),
            ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showChangePINDialog() async {
    // Self-heal: many installs predate PIN setup entirely. When no PIN has
    // ever been set, don't demand a current PIN — just set one.
    final hasPin = await _securityService.hasPIN();
    if (!mounted) return;

    final oldPinController = TextEditingController();
    final newPinController = TextEditingController();
    final confirmPinController = TextEditingController();
    String? oldPinError;
    String? newPinError;
    bool isLoading = false;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: AppTheme.cardColor,
              title: Text(
                hasPin ? 'Change PIN' : 'Set PIN',
                style: const TextStyle(color: AppTheme.textPrimary),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasPin) ...[
                      TextField(
                        controller: oldPinController,
                        obscureText: true,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Current PIN',
                          errorText: oldPinError,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      controller: newPinController,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'New PIN',
                        errorText: newPinError,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: confirmPinController,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Confirm new PIN',
                        border: OutlineInputBorder(),
                ),
              ),
            ],
            ),
          ),
          actions: [
                TextButton(
                  onPressed: isLoading
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: isLoading
                      ? null
                      : () async {
                          setDialogState(() {
                            oldPinError = null;
                            newPinError = null;
                          });

                          final oldPin = oldPinController.text.trim();
                          final newPin = newPinController.text.trim();
                          final confirmPin = confirmPinController.text.trim();

                          if (hasPin &&
                              (oldPin.isEmpty || oldPin.length < 4)) {
                            setDialogState(() {
                              oldPinError = 'PIN must be at least 4 digits';
                            });
                            return;
                          }
                          if (newPin.length < 4) {
                            setDialogState(() {
                              newPinError = 'New PIN must be at least 4 digits';
                            });
                            return;
                          }
                          if (newPin != confirmPin) {
                            setDialogState(() {
                              newPinError = 'PINs do not match';
                            });
                            return;
                          }

                          setDialogState(() => isLoading = true);

                          if (hasPin) {
                            final verified =
                                await _securityService.verifyPIN(oldPin);
                            if (!verified) {
                              setDialogState(() {
                                isLoading = false;
                                oldPinError = 'Incorrect current PIN';
                              });
                              return;
                            }
                          }

                          // The app PIN never touches wallet material —
                          // wallet files keep their own passwords, so a PIN
                          // change needs no re-encryption.
                          await _securityService.setPIN(newPin);
                          if (context.mounted) {
                            Navigator.of(context).pop();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  hasPin
                                      ? 'PIN updated successfully'
                                      : 'PIN set successfully',
                                ),
                                backgroundColor: AppTheme.successColor,
                              ),
                            );
                          }
                        },
                  child: isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Update PIN'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showResetWalletDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: AppTheme.cardColor,
          title: const Text(
            'Reset Wallet',
            style: TextStyle(color: AppTheme.textPrimary),
          ),
          content: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This will permanently remove your wallet from this device. Make sure you have your backup phrase saved!',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.errorColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppTheme.errorColor.withOpacity(0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning,
                      color: AppTheme.errorColor,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This action cannot be undone!',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'Cancel',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await _resetWallet();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.errorColor,
              ),
              child: const Text('Reset Wallet'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _resetWallet() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final vault = context.read<FuegoVaultService>();
      await vault.wipe();

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const MainScreen()),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        _showError('Failed to reset wallet: $e');
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _showNodeSelectionDialog() {
    final TextEditingController customNodeController = TextEditingController();
    String selectedNode = FuegoRPCService.defaultRemoteNodes.first;
    bool useLocal = _useLocalNode;

    // The dialog's StatefulBuilder shadows `setState` inside its builder;
    // after the dialog is popped the builder state is defunct and calling
    // its setState throws. Capture the screen-level setState for updates
    // that happen after the dialog closes (post-await continuation).
    final screenSetState = setState;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: AppTheme.cardColor,
              title: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: AppTheme.primaryGradient,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.cloud,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Node Connection',
                    style: TextStyle(color: AppTheme.textPrimary),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Local/Remote toggle
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceColor.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => useLocal = true),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: useLocal
                                    ? AppTheme.primaryColor
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.computer,
                                    size: 16,
                                    color: useLocal
                                        ? Colors.white
                                        : AppTheme.textMuted,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Local Node',
                                    style: TextStyle(
                                      color: useLocal
                                          ? Colors.white
                                          : AppTheme.textMuted,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => useLocal = false),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: !useLocal
                                    ? AppTheme.primaryColor
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.cloud,
                                    size: 16,
                                    color: !useLocal
                                        ? Colors.white
                                        : AppTheme.textMuted,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Remote Node',
                                    style: TextStyle(
                                      color: !useLocal
                                          ? Colors.white
                                          : AppTheme.textMuted,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Content based on selection
                  if (useLocal) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.successColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: AppTheme.successColor.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.check_circle,
                                color: AppTheme.successColor,
                                size: 16,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Built-in Node',
                                style: TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Desktop default. Runs fuego_walletd with --local '
                            '(embedded fuegod). Wallet RPC on 127.0.0.1:18189.',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Requires bundled binaries. Syncs the chain on this machine.',
                            style: TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    const Text(
                      'Connect to a remote Fuego node:',
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                    const SizedBox(height: 12),
                    ...FuegoRPCService.defaultRemoteNodes.map(
                      (node) => RadioListTile<String>(
                        title: Text(
                          node,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 13,
                          ),
                        ),
                        value: node,
                        groupValue: selectedNode,
                        onChanged: (value) {
                          setState(() {
                            selectedNode = value!;
                            customNodeController.clear();
                          });
                        },
                        activeColor: AppTheme.primaryColor,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Or enter custom node:',
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: customNodeController,
                      decoration: InputDecoration(
                        hintText: 'node.example.com:18180',
                        hintStyle: TextStyle(
                          color: AppTheme.textSecondary.withValues(alpha: 0.5),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(
                            color: AppTheme.textSecondary.withValues(
                              alpha: 0.3,
                            ),
                          ),
                        ),
                        focusedBorder: const OutlineInputBorder(
                          borderSide: BorderSide(color: AppTheme.primaryColor),
                        ),
                      ),
                      style: const TextStyle(color: AppTheme.textPrimary),
                      onChanged: (value) {
                        if (value.isNotEmpty) {
                          setState(() {
                            selectedNode = value;
                          });
                        }
                      },
                    ),
                  ],
                ],
              ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    'Cancel',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                ),
                ElevatedButton(
                  onPressed: () async {
                    Navigator.of(context).pop();

                    screenSetState(() {
                      _useLocalNode = useLocal;
                    });

                    if (useLocal) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: const Text(
                            'Starting built-in local node...',
                          ),
                          backgroundColor: AppTheme.primaryColor,
                        ),
                      );
                      final ep = await app.nodeConnection.switchToLocal(
                        useTestnet: app.useTestnet,
                      );
                      if (!mounted) return;
                      screenSetState(() {
                        _fuegodHost = ep.chainHost;
                        _fuegodPort = ep.chainPort;
                        _fuegodConfigured = ep.proxyRunning;
                      });
                      if (ep.error != null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(ep.error!),
                            backgroundColor: AppTheme.errorColor,
                          ),
                        );
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Local node ready — ${ep.walletBaseUrl}',
                            ),
                            backgroundColor: AppTheme.successColor,
                          ),
                        );
                      }
                    } else {
                      final custom = customNodeController.text.trim();
                      final target = custom.isNotEmpty ? custom : selectedNode;

                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Connecting via remote $target...'),
                          backgroundColor: AppTheme.primaryColor,
                        ),
                      );

                      final ep = await app.nodeConnection.switchToRemote(
                        host: target,
                        useTestnet: app.useTestnet,
                      );
                      if (!mounted) return;
                      screenSetState(() {
                        _fuegodHost = ep.chainHost;
                        _fuegodPort = ep.chainPort;
                        _fuegodConfigured = ep.proxyRunning;
                      });

                      // Keep WalletProvider node URL in sync with wallet proxy.
                      final walletProvider = Provider.of<WalletProvider>(
                        context,
                        listen: false,
                      );
                      await walletProvider.connectToNode(ep.walletBaseUrl);

                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              ep.proxyRunning
                                  ? 'Remote chain $target via proxy ${ep.walletBaseUrl}'
                                  : (ep.error ?? 'Connected to $target'),
                              style: const TextStyle(color: Colors.white),
                            ),
                            backgroundColor: AppTheme.primaryColor,
                          ),
                        );
                      }
                    }
                  },
                  child: const Text('Connect'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Deterministic QR version for a payload length (binary mode, level L).
  /// The auto-detection path in qr_flutter 4.1.x can hang or throw on some
  /// inputs; choosing the version explicitly keeps QR generation O(1).
  int _qrVersionForLength(int length) {
    const capacities = <int>[
      0, // version 0 is unused
      17, 32, 53, 78, 106, 134, 154, 192, 230, 271, // 1..10
      321, 367, 425, 458, 520, 586, 644, 718, 792, 858, // 11..20
      929, 1003, 1091, 1171, 1273, 1367, 1465, 1528, 1628, 1732, // 21..30
      1840, 1952, 2068, 2188, 2303, 2431, 2563, 2699, 2809, 2953, // 31..40
    ];
    for (int v = 1; v <= 40; v++) {
      if (length <= capacities[v]) return v;
    }
    return 40;
  }

  void _showAddressDialog(String? address) {
    if (address == null || address.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No wallet address loaded yet'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
      return;
    }

    final qrVersion = _qrVersionForLength(address.length);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppTheme.cardColor,
          title: const Text('Wallet Address'),
          content: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: _buildQrSafely(address, qrVersion),
              ),
              const SizedBox(height: 16),
              SelectableText(
                address,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontFamily: 'IBMPlexMono',
                ),
              ),
            ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: address));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Address copied to clipboard')),
                );
              },
              child: const Text('Copy'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  /// QR rendering with a hard failure fallback: an explicit version avoids
  /// the auto-detection path (qr_flutter 4.1.x auto can hang or throw), and
  /// errorStateBuilder guarantees the dialog renders even if generation
  /// fails.
  ///
  /// CRITICAL: [QrImageView] builds a [LayoutBuilder], which cannot report
  /// intrinsic dimensions. `AlertDialog` measures its content with
  /// `IntrinsicWidth`, which reaches down through the tree and hits that
  /// [LayoutBuilder], throwing "LayoutBuilder does not support returning
  /// intrinsic dimensions" and freezing the app in debug builds. The
  /// fixed-size [SizedBox] reports its own intrinsic dimensions and shields
  /// the QR widget from that measurement.
  Widget _buildQrSafely(String address, int version) {
    return SizedBox(
      width: 200,
      height: 200,
      child: QrImageView(
        data: address,
        version: version,
        errorCorrectionLevel: QrErrorCorrectLevel.L,
        size: 200.0,
        errorStateBuilder: (_, __) => const SizedBox(
          width: 200,
          height: 200,
          child: Center(child: Icon(Icons.qr_code_2, size: 96)),
        ),
      ),
    );
  }

  Future<void> _showBackupPhraseDialog() async {
    final vault = context.read<FuegoVaultService>();
    if (vault.activeWallet == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No wallet on this device yet'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
      return;
    }

    final passwordController = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardColor,
        title: const Text(
          'Wallet Password',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: TextField(
          controller: passwordController,
          obscureText: true,
          maxLength: 64,
          decoration: const InputDecoration(
            labelText: 'Enter this wallet\'s password to view backup secrets',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(passwordController.text),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
    passwordController.dispose();
    if (password == null || password.isEmpty || !mounted) return;

    if (!vault.isUnlocked) {
      final unlocked = await vault.unlockActive(password);
      if (!unlocked) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invalid password'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
        return;
      }
    }

    String mnemonic = 'Unavailable';
    String spendPub = '';
    String spendSec = '';
    String viewPub = '';
    String viewSec = '';

    try {
      // Prefer the ACTIVE wallet's seed from the unlocked vault so the
      // backup always matches the wallet currently in use. Fall back to
      // the PIN-encrypted seed in secure storage.
      final seed = vault.getSeed();
      if (seed != null && seed.length == 64) {
        mnemonic = bip39.entropyToMnemonic(seed);
      } else {
        final storedSeed = await _securityService.getWalletSeed(password);
        if (storedSeed != null && SecurityService.validateMnemonic(storedSeed)) {
          mnemonic = storedSeed;
        }
      }
      final spendKeys = vault.deriveKeypair(0);
      final viewKeys = vault.deriveKeypair(1);
      spendPub = spendKeys['public'] as String? ?? '';
      spendSec = spendKeys['secret'] as String? ?? '';
      viewPub = viewKeys['public'] as String? ?? '';
      viewSec = viewKeys['secret'] as String? ?? '';
    } catch (e) {
      mnemonic = 'Could not load backup material';
    }

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppTheme.cardColor,
          title: const Text('Wallet Backup'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Save these keys offline. Anyone with the secret keys can spend your funds.',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 16),
                _buildKeyTile('Mnemonic Phrase', mnemonic, isMnemonic: true),
                _buildKeyTile('Address', vault.address),
                _buildKeyTile('Spend Key (Public)', spendPub),
                _buildKeyTile('Spend Key (Secret)', spendSec),
                _buildKeyTile('View Key (Public)', viewPub),
                _buildKeyTile('View Key (Secret)', viewSec),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildKeyTile(String title, String value, {bool isMnemonic = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  value,
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontFamily: isMnemonic ? 'IBMPlexMono' : null,
                    fontSize: isMnemonic ? 16 : 14,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.copy,
                  size: 18,
                  color: AppTheme.textSecondary,
                ),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: value));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard')),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showFuegodConfigDialog() {
    final hostController = TextEditingController(text: _fuegodHost);
    final portController = TextEditingController(text: _fuegodPort.toString());

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: AppTheme.cardColor,
          title: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.swap_horiz,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'Fuego Daemon',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Connect to a fuegod instance for DEX trading and swaps.',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: hostController,
                  decoration: InputDecoration(
                    hintText: '207.244.247.64',
                    hintStyle: TextStyle(
                      color: AppTheme.textSecondary.withOpacity(0.5),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: AppTheme.textSecondary.withOpacity(0.3),
                      ),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: AppTheme.primaryColor),
                    ),
                    labelText: 'Host',
                    labelStyle: TextStyle(color: AppTheme.textSecondary),
                  ),
                  style: const TextStyle(color: AppTheme.textPrimary),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: portController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    hintText: '18180',
                    hintStyle: TextStyle(
                      color: AppTheme.textSecondary.withOpacity(0.5),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: AppTheme.textSecondary.withOpacity(0.3),
                      ),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: AppTheme.primaryColor),
                    ),
                    labelText: 'RPC Port',
                    labelStyle: TextStyle(color: AppTheme.textSecondary),
                  ),
                  style: const TextStyle(color: AppTheme.textPrimary),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'Cancel',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
            ),
            ElevatedButton(
              onPressed: () {
                final host = hostController.text.trim();
                final port = int.tryParse(portController.text.trim()) ?? 18180;

                if (host.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('Please enter a host address'),
                      backgroundColor: AppTheme.errorColor,
                    ),
                  );
                  return;
                }

                setState(() {
                  _fuegodHost = host;
                  _fuegodPort = port;
                  _fuegodConfigured = true;
                });

                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('fuego daemon: $host:$port'),
                    backgroundColor: AppTheme.successColor,
                  ),
                );
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: AppTheme.cardColor,
          title: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.local_fire_department,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'Fuego Valise',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Version 1.0.0',
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Privacy Bank & Purchasing Power Chain',
                style: TextStyle(
                  color: AppTheme.primaryColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'A privacy-focused cryptocurrency wallet for Fuego (XFG)',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 16),
              const Text(
                'Features:',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '• Private transactions with ring signatures\n'
                '• ΗΞΔŦ flatcoin — mint or sell\n'
                '• Certificates of Deposit earning yield\n'
                '• Built-in unified daemon (fuegod + walletd + xfg-swapd)\n'
                '• Cross-chain atomic swaps (12 chains)\n'
                '• Built-in mining capabilities\n'
                '• Advanced security features',
                style: TextStyle(color: AppTheme.textSecondary, height: 1.5),
              ),
            ],
            ),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        elevation: 0,
        backgroundColor: Colors.transparent,
        automaticallyImplyLeading: false,
      ),
      body: BlocBuilder<WalletCubit, WalletState>(
        builder: (context, state) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Account section
              _buildSectionHeader('Account'),
              _buildSettingsTile(
                icon: Icons.account_balance_wallet,
                title: 'Wallet Address',
                subtitle: _truncateAddress(state.address ?? 'Not available'),
                onTap: () => _showAddressDialog(state.address),
              ),
              _buildSettingsTile(
                icon: Icons.key,
                title: 'Backup Phrase',
                subtitle: 'View your wallet backup phrase',
                onTap: _showBackupPhraseDialog,
                trailing: const Icon(Icons.chevron_right),
              ),
              _buildSettingsTile(
                icon: Icons.account_balance_wallet_outlined,
                title: 'Wallets',
                subtitle: 'Switch, add, or import saved wallets',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const WalletsScreen(),
                    ),
                  );
                },
                trailing: const Icon(Icons.chevron_right),
              ),

              const SizedBox(height: 24),

              // Alias Section
              _buildSectionHeader('Alias'),
              _buildSettingsTile(
                icon: Icons.alternate_email,
                title: 'Register Alias',
                subtitle: 'Register a human-readable alias',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const AliasRegistrationScreen(),
                    ),
                  );
                },
                trailing: const Icon(Icons.chevron_right),
              ),

              const SizedBox(height: 24),

              // Security section
              _buildSectionHeader('Security'),
              _buildSettingsTile(
                icon: Icons.fingerprint,
                title: 'Biometric Authentication',
                subtitle: 'Use fingerprint or face recognition',
                trailing: Switch(
                  value: _biometricEnabled,
                  onChanged: _toggleBiometric,
                ),
              ),
              _buildSettingsTile(
                icon: Icons.lock_reset,
                title: 'Change PIN',
                subtitle: 'Update your wallet PIN',
                onTap: _showChangePINDialog,
                trailing: const Icon(Icons.chevron_right),
              ),

              const SizedBox(height: 24),

              // Network section
              _buildSectionHeader('Network'),
              _buildSettingsTile(
                icon: Icons.cloud,
                title: 'Node Connection',
                subtitle: _useLocalNode
                    ? 'Built-in node (unified daemon)'
                    : 'Remote node — ${_fuegodHost}:${_fuegodPort}',
                trailing: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: state.isConnected
                        ? AppTheme.successColor
                        : AppTheme.errorColor,
                    shape: BoxShape.circle,
                  ),
                ),
                onTap: _showNodeSelectionDialog,
              ),
              _buildSettingsTile(
                icon: walletProvider.networkConfig.isTestnet
                    ? Icons.science
                    : Icons.public,
                title: 'Network',
                subtitle: walletProvider.networkConfig.name,
                trailing: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: walletProvider.networkConfig.isTestnet
                        ? Colors.orange.withOpacity(0.2)
                        : Colors.green.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: walletProvider.networkConfig.isTestnet
                          ? Colors.orange
                          : Colors.green,
                      width: 1,
                    ),
                  ),
                  child: Text(
                    walletProvider.networkConfig.isTestnet
                        ? 'TESTNET'
                        : 'MAINNET',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: walletProvider.networkConfig.isTestnet
                          ? Colors.orange
                          : Colors.green,
                    ),
                  ),
                ),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const NetworkSelectionScreen(),
                    ),
                  );
                },
              ),
              _buildSettingsTile(
                icon: Icons.sync,
                title: 'Sync Status',
                subtitle: state.isSynced
                    ? 'Synchronized (height ${state.blockHeight})'
                    : 'Syncing (height ${state.blockHeight})',
                onTap: () {
                  // TODO: Show sync details
                },
              ),

              const SizedBox(height: 24),

              // DEX Server section
              _buildSectionHeader('DEX (Fuego Native)'),
              _buildSettingsTile(
                icon: Icons.swap_horiz,
                title: 'Fuego Daemon',
                subtitle: _fuegodConfigured
                    ? 'Connected to $_fuegodHost:$_fuegodPort'
                    : 'Not configured — DEX unavailable',
                trailing: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _fuegodConfigured
                        ? AppTheme.successColor
                        : AppTheme.errorColor,
                    shape: BoxShape.circle,
                  ),
                ),
                onTap: _showFuegodConfigDialog,
              ),
              _buildSettingsTile(
                icon: Icons.hub_outlined,
                title: 'Cross-Chain Swap Settings',
                subtitle:
                    'Configure xfg-swapd chain RPCs, keys and SPV servers',
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SwapSettingsScreen()),
                ),
              ),

              const SizedBox(height: 24),

              // App section
              _buildSectionHeader('App'),
              _buildSettingsTile(
                icon: Icons.font_download,
                title: 'App Font',
                subtitle:
                    fontOptions.firstWhere((f) => f.family == _fontFamily).label,
                onTap: _showFontPickerDialog,
                trailing: const Icon(Icons.chevron_right),
              ),
              _buildSettingsTile(
                icon: Icons.currency_exchange,
                title: 'XFG Symbol',
                subtitle: XfgTicker.options
                    .firstWhere((o) => o.family == XfgTicker.font,
                        orElse: () => XfgTicker.options.first)
                    .label,
                onTap: _showTickerPickerDialog,
                trailing: const Icon(Icons.chevron_right),
              ),
              _buildSettingsTile(
                icon: Icons.info,
                title: 'About',
                subtitle: 'Version and app information',
                onTap: _showAboutDialog,
                trailing: const Icon(Icons.chevron_right),
              ),
              _buildSettingsTile(
                icon: Icons.help,
                title: 'Help & Support',
                subtitle: 'Get help using Fuego Valise',
                onTap: () {
                  // TODO: Open help/support
                },
                trailing: const Icon(Icons.chevron_right),
              ),

              const SizedBox(height: 32),

              // Danger zone
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.errorColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.errorColor.withOpacity(0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.warning, color: AppTheme.errorColor),
                        SizedBox(width: 8),
                        Text(
                          'Danger Zone',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.errorColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _isLoading ? null : _showResetWalletDialog,
                        icon: _isLoading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    AppTheme.errorColor,
                                  ),
                                ),
                              )
                            : const Icon(Icons.delete_forever),
                        label: const Text('Reset Wallet'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.errorColor,
                          side: const BorderSide(color: AppTheme.errorColor),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: AppTheme.primaryColor,
        ),
      ),
    );
  }

  Widget _buildSettingsTile({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
      child: Material(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: AppTheme.primaryColor, size: 20),
          ),
          title: Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          subtitle: Text(
            subtitle,
            style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
          ),
          trailing: trailing,
          onTap: onTap,
        ),
      ),
    );
  }

  String _truncateAddress(String address) {
    if (address.length <= 20) return address;
    return '${address.substring(0, 10)}...${address.substring(address.length - 10)}';
  }
}
