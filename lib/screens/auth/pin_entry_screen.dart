import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';
import '../../bloc/wallet/wallet_cubit.dart';
import '../../providers/wallet_provider.dart';
import '../../services/fuego_vault_service.dart';
import '../../services/security_service.dart';
import '../../utils/theme.dart';
import '../../widgets/pin_input_widget.dart';
import '../main/main_screen.dart';


class PinEntryScreen extends StatefulWidget {
  const PinEntryScreen({super.key});

  @override
  State<PinEntryScreen> createState() => _PinEntryScreenState();
}

class _PinEntryScreenState extends State<PinEntryScreen>
    with TickerProviderStateMixin {
  final SecurityService _securityService = SecurityService();
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  
  bool _isLoading = false;
  String? _errorMessage;
  bool _canUseBiometric = false;
  int _failedAttempts = 0;
  static const int maxFailedAttempts = SecurityService.maxFailedAttempts;

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _checkBiometricCapability();
    _tryBiometricAuth();
  }

  void _setupAnimations() {
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 3000),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    ));

    _fadeController.forward();
  }

  Future<void> _checkBiometricCapability() async {
    final available = await _securityService.isBiometricAvailable();
    final enabled = await _securityService.isBiometricEnabled();
    
    setState(() {
      _canUseBiometric = available && enabled;
    });
  }

  Future<void> _tryBiometricAuth() async {
    if (!_canUseBiometric) return;

    // Delay to allow screen to render
    await Future.delayed(const Duration(milliseconds: 800));

    if (mounted) {
      await _authenticateWithBiometric();
    }
  }

  Future<void> _authenticateWithBiometric() async {
    try {
      if (await _securityService.isLockedOut()) {
        if (mounted) {
          setState(() {
            _errorMessage = 'Too many failed attempts. Try again later.';
          });
        }
        return;
      }
      final walletProvider = Provider.of<WalletProvider>(context, listen: false);
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
      final success = await walletProvider.unlockWithBiometrics();
      if (success && mounted) {
        await _onUnlockedSuccess();
      } else if (mounted) {
        setState(() {
          _errorMessage =
              walletProvider.error ?? 'Biometric unlock failed — use PIN';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _onPinComplete(String pin) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (await _securityService.isLockedOut()) {
        final rem = await _securityService.lockoutRemaining();
        final mins = rem?.inMinutes ?? 15;
        setState(() {
          _errorMessage = 'Locked out. Try again in ~$mins min.';
          _isLoading = false;
        });
        return;
      }

      final isValid = await _securityService.verifyPIN(pin);
      if (isValid) {
        await _unlockWallet(pin);
      } else {
        await _handleFailedAttempt();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Authentication failed. Please try again.';
        _isLoading = false;
      });
    }
  }

  Future<void> _unlockWallet(String pin) async {
    try {
      final walletProvider = Provider.of<WalletProvider>(context, listen: false);
      final success = await walletProvider.unlockWallet(pin);

      if (success && mounted) {
        await _onUnlockedSuccess();
      } else if (mounted) {
        setState(() {
          _errorMessage = walletProvider.error ?? 'Failed to unlock wallet';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to unlock wallet';
        _isLoading = false;
      });
    }
  }

  Future<void> _onUnlockedSuccess() async {
    if (!mounted) return;
    try {
      await context.read<WalletCubit>().onUnlocked();
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => const MainScreen()),
    );
  }

  Future<void> _handleFailedAttempt() async {
    final attempts = await _securityService.failedAttempts();
    final lockedOut = await _securityService.isLockedOut();
    if (!mounted) return;
    setState(() {
      _failedAttempts = attempts;
      _isLoading = false;
      if (lockedOut) {
        _errorMessage =
            'Too many failed attempts. Wallet locked for ${SecurityService.lockoutDuration.inMinutes} minutes.';
      } else {
        final remaining = maxFailedAttempts - attempts;
        _errorMessage =
            'Incorrect PIN. $remaining attempt${remaining == 1 ? '' : 's'} remaining.';
      }
    });
  }

  void _onForgotPin() {
    _showResetWalletDialog();
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
                'If you\'ve forgotten your PIN, you\'ll need to reset your wallet using your backup phrase.',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.warningColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppTheme.warningColor.withOpacity(0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning,
                      color: AppTheme.warningColor,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This will remove the current wallet from this device.',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 14,
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
              onPressed: () {
                Navigator.of(context).pop();
                _resetWallet();
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
    try {
      // Wipe the actual vault files first — clearWalletData() only clears
      // SecurityService's PIN/seed entries. Without this, the encrypted
      // vault stays on disk with no PIN to unlock it and no route back to
      // PinEntryScreen (hasPIN becomes false), stranding the user.
      final vault = context.read<FuegoVaultService>();
      await vault.wipe();
      await _securityService.clearWalletData();

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const MainScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error resetting wallet: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: Column(
              children: [
                Expanded(
                  flex: 2,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Logo
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: AppTheme.primaryGradient,
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.primaryColor.withOpacity(0.3),
                              blurRadius: 15,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.local_fire_department,
                          size: 40,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'Welcome Back',
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Enter your PIN to unlock your wallet',
                        style: TextStyle(
                          fontSize: 16,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_isLoading)
                        const Column(
                          children: [
                            CircularProgressIndicator(
                              valueColor: AlwaysStoppedAnimation<Color>(
                                AppTheme.primaryColor,
                              ),
                            ),
                            SizedBox(height: 16),
                            Text(
                              'Unlocking wallet...',
                              style: TextStyle(
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        )
                      else ...[
                        PinInputWidget(
                          onComplete: _onPinComplete,
                          errorMessage: _errorMessage,
                          showForgotPin: true,
                          onForgotPin: _onForgotPin,
                          canUseBiometric: _canUseBiometric,
                          onBiometric: _authenticateWithBiometric,
                        ),
                        
                        // Failed attempts counter
                        if (_failedAttempts > 0) ...[
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.warningColor.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'Failed attempts: $_failedAttempts/$maxFailedAttempts',
                              style: const TextStyle(
                                color: AppTheme.warningColor,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
                
                // Footer
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Your wallet is encrypted and stored securely on this device',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }
}