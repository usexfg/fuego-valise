import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';
import '../../bloc/wallet/wallet_cubit.dart';
import '../../providers/wallet_provider.dart';
import '../../services/fuego_vault_service.dart';
import '../../services/security_service.dart';
import '../../utils/theme.dart';
import '../../widgets/mnemonic_display.dart';
import '../../widgets/pin_input_widget.dart';

/// Creates a brand-new wallet and adds it alongside any existing saved
/// wallets on this device.
///
/// The wallet is encrypted with its OWN password. First-wallet setup also
/// asks for an app PIN (which never touches wallet material); adding another
/// wallet verifies the existing app PIN. The new seed phrase is shown for
/// backup after creation.
class CreateNewWalletScreen extends StatefulWidget {
  const CreateNewWalletScreen({super.key});

  @override
  State<CreateNewWalletScreen> createState() => _CreateNewWalletScreenState();
}

class _CreateNewWalletScreenState extends State<CreateNewWalletScreen> {
  final PageController _pageController = PageController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _pinController = TextEditingController();
  int _currentPage = 0;
  String _firstPin = '';
  String _phrase = '';
  bool _isLoading = false;
  String? _errorMessage;
  late final bool _hasExistingWallets;
  bool _modeReady = false;
  bool _needsPinSetup = true;

  @override
  void initState() {
    super.initState();
    _hasExistingWallets =
        context.read<FuegoVaultService>().wallets.isNotEmpty;
    _determineMode();
  }

  /// Self-heal: if no app PIN has ever been set, walk through PIN creation
  /// instead of demanding verification of a PIN that doesn't exist.
  Future<void> _determineMode() async {
    try {
      final hasPin = await SecurityService().hasPIN().timeout(
        const Duration(seconds: 3),
        onTimeout: () => false,
      );
      if (!mounted) return;
      setState(() {
        _needsPinSetup = !hasPin;
        _modeReady = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _needsPinSetup = true;
        _modeReady = true;
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _passwordController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  int get _pageCount => _needsPinSetup ? 5 : 4;

  void _nextPage() {
    if (_currentPage < _pageCount - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _previousPage() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _onPasswordContinue() {
    final password = _passwordController.text.trim();
    if (password.length < 8) {
      setState(() => _errorMessage = 'Password must be at least 8 characters');
      return;
    }
    setState(() => _errorMessage = null);
    _nextPage();
  }

  void _onFirstPinComplete(String pin) {
    setState(() {
      _firstPin = pin;
      _errorMessage = null;
    });
    _nextPage();
  }

  void _onConfirmPinComplete(String pin) {
    setState(() {
      _errorMessage = null;
    });

    if (_firstPin == pin) {
      _finalizeFirstWallet(pin);
    } else {
      setState(() {
        _errorMessage = 'PINs do not match. Please try again.';
      });
    }
  }

  Future<void> _finalizeFirstWallet(String appPin) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await SecurityService().setPIN(appPin);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to set app PIN: $e';
      });
      return;
    }
    await _createWallet(_passwordController.text.trim());
  }

  Future<void> _verifyPinAndCreate() async {
    final pin = _pinController.text.trim();
    if (pin.isEmpty) {
      setState(() => _errorMessage = 'Enter your PIN');
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    final ok = await SecurityService().verifyPIN(pin);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Invalid PIN';
      });
      return;
    }
    await _createWallet(_passwordController.text.trim());
  }

  Future<void> _createWallet(String password) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final walletProvider = Provider.of<WalletProvider>(context, listen: false);
      final vault = context.read<FuegoVaultService>();

      // Generate the phrase up front so we can display it for backup.
      final phrase = SecurityService.generateMnemonic();
      final success = await walletProvider.createWallet(
        password: password,
        mnemonic: phrase,
        vault: vault,
      );

      if (!mounted) return;

      if (success) {
        setState(() {
          _phrase = phrase;
          _isLoading = false;
        });
        try {
          await context.read<WalletCubit>().onUnlocked();
        } catch (_) {}
        if (mounted) {
          _nextPage();
        }
      } else {
        setState(() {
          _errorMessage = walletProvider.error ?? 'Failed to create wallet';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New Vault'),
        elevation: 0,
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_currentPage > 0) {
              _previousPage();
            } else {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_pageCount, (index) {
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: index <= _currentPage
                        ? AppTheme.primaryColor
                        : AppTheme.textMuted,
                  ),
                );
              }),
            ),
          ),
          Expanded(
            child: !_modeReady
                ? const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (page) {
                      setState(() {
                        _currentPage = page;
                      });
                    },
                    children: _needsPinSetup
                        ? [
                            _buildInfoPage(),
                            _buildPasswordPage(),
                            _buildSetupPinPage(),
                            _buildConfirmPinPage(),
                            _buildBackupPage(),
                          ]
                        : [
                            _buildInfoPage(),
                            _buildPasswordPage(),
                            _buildVerifyPinPage(),
                            _buildBackupPage(),
                          ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoPage() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 24),
          Icon(
            _hasExistingWallets
                ? Icons.add_circle_outline
                : Icons.account_balance_wallet_outlined,
            size: 64,
            color: AppTheme.primaryColor,
          ),
          const SizedBox(height: 24),
          Text(
            _hasExistingWallets ? 'Add Another Vault' : 'Open Your Vault',
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _hasExistingWallets
                ? 'A new vault will be generated alongside your existing '
                      'vaults. Switch between them from Settings > Vault.'
                : 'A new vault will be generated and held on this device.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.primaryColor.withOpacity(0.3),
              ),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.lock, color: AppTheme.primaryColor, size: 18),
                    SizedBox(width: 8),
                    Text(
                      'This wallet gets its own password',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                Text(
                  '• Only this password decrypts this wallet file.\n'
                  '• Your app PIN does not unlock it.\n'
                  '• A seed phrase will be shown after creation — write it '
                  'down.',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _nextPage,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
              ),
              child: const Text(
                'Continue',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPasswordPage() {
    return SingleChildScrollView(
      child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 24),
          const Icon(Icons.key, size: 64, color: AppTheme.primaryColor),
          const SizedBox(height: 24),
          const Text(
            'Wallet Password',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Choose a password for THIS wallet. It encrypts this wallet\'s '
            'file only — other wallets keep their own passwords.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _passwordController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'Wallet password',
              errorText: _errorMessage,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _onPasswordContinue,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
              ),
              child: const Text(
                'Continue',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
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
            child: const Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: AppTheme.warningColor,
                  size: 16,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This password cannot be recovered. If you forget it, '
                    'only the seed phrase can restore the wallet.',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildVerifyPinPage() {
    return SingleChildScrollView(
      child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 24),
          const Icon(Icons.lock_outline, size: 64, color: AppTheme.primaryColor),
          const SizedBox(height: 24),
          const Text(
            'Confirm Your App PIN',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Verify your app PIN to authorize adding a wallet',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _pinController,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: InputDecoration(
              labelText: 'App PIN',
              counterText: '',
              errorText: _errorMessage,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _verifyPinAndCreate(),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _verifyPinAndCreate,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
              ),
              child: _isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text(
                      'Create Wallet',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildSetupPinPage() {
    return SingleChildScrollView(
      child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 24),
          const Icon(Icons.lock_outline, size: 64, color: AppTheme.primaryColor),
          const SizedBox(height: 24),
          const Text(
            'Create Your App PIN',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'This PIN locks the app. It does NOT decrypt your wallets — '
            'each wallet keeps its own password.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 48),
          PinInputWidget(
            onComplete: _onFirstPinComplete,
            errorMessage: _errorMessage,
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildConfirmPinPage() {
    return SingleChildScrollView(
      child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 24),
          const Icon(
            Icons.verified_outlined,
            size: 64,
            color: AppTheme.primaryColor,
          ),
          const SizedBox(height: 24),
          const Text(
            'Confirm Your App PIN',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Enter your PIN again to confirm',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 48),
          PinInputWidget(
            onComplete: _onConfirmPinComplete,
            errorMessage: _errorMessage,
          ),
          const SizedBox(height: 24),
          if (_isLoading) ...[
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 8),
            const Text(
              'Creating wallet...',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ],
          if (_errorMessage != null && !_isLoading) ...[
            const SizedBox(height: 16),
            TextButton(
              onPressed: () {
                setState(() {
                  _firstPin = '';
                  _errorMessage = null;
                  _isLoading = false;
                });
                _previousPage();
              },
              child: const Text('Change PIN'),
            ),
          ],
        ],
      ),
      ),
    );
  }

  Widget _buildBackupPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 16),
          const Icon(Icons.check_circle, size: 64, color: AppTheme.successColor),
          const SizedBox(height: 24),
          const Text(
            'Vault Secured.',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Write down your seed phrase and keep it somewhere safe. '
            'It is the only way to restore this vault.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 24),
          MnemonicDisplay(mnemonic: _phrase),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.successColor,
                foregroundColor: Colors.white,
              ),
              child: const Text(
                'Done',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
