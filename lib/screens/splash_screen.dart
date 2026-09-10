import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:animated_text_kit/animated_text_kit.dart';
import '../main.dart' as app;
import '../providers/wallet_provider.dart';
import '../services/security_service.dart';
import '../utils/theme.dart';

import 'auth/pin_entry_screen.dart';
import 'main/main_screen.dart';
import '../../utils/xfg_ticker.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _fadeController;
  late AnimationController _slideController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  bool _isInitializing = true;
  String _initMessage = 'Initializing Fuego Valise...';
  String _versionString = '';
  String? _daemonWarning;

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _loadVersion();
    _initializeApp();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      setState(() {
        _versionString =
            'Fuego Valise v${info.version} • Privacy Bank & Purchasing Power Chain';
      });
    } catch (_) {
      setState(() {
        _versionString = 'Fuego Valise v5.11.0 • Privacy Bank & Purchasing Power Chain';
      });
    }
  }

  void _setupAnimations() {
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    _slideController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    ));

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutBack,
    ));

    // Start animations
    _fadeController.forward();
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) _slideController.forward();
    });
  }

  Future<void> _initializeApp() async {
    try {
      // Splash visible for at least 3 seconds
      await Future.delayed(const Duration(seconds: 3));
      if (!mounted) return;

      setState(() {
        _initMessage = 'Checking wallet status...';
      });

      // Check for daemon errors
      if (app.daemonError != null) {
        setState(() {
          _daemonWarning = app.daemonError;
        });
      }

      final securityService = SecurityService();
      final walletProvider = Provider.of<WalletProvider>(context, listen: false);

      // Always clear stale lockout FIRST — before any PIN/wallet checks.
      // This runs unconditionally so a stale lockout never blocks navigation.
      try {
        await securityService.clearStaleLockout();
      } catch (_) {}

      bool hasWallet = false;
      bool hasPIN = false;
      try {
        hasWallet = await walletProvider.hasWalletData();
        hasPIN = await securityService.hasPIN();
      } catch (e) {
        debugPrint('Secure storage check failed — requiring setup/unlock');
      }

      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;

      // Skip PIN screen — go straight to MainScreen.
      _navigateToScreen(const MainScreen());
    } catch (e) {
      if (!mounted) return;

      // Clear lockout even in error path
      try {
        await SecurityService().clearStaleLockout();
      } catch (_) {}

      setState(() {
        _initMessage = 'Unable to initialize securely. Please unlock or set up.';
      });

      await Future.delayed(const Duration(milliseconds: 1500));
      if (mounted) {
        _navigateToScreen(const MainScreen());
      }
    }
  }

  void _navigateToScreen(Widget screen) {
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => screen,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 800),
      ),
    );
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _slideController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                flex: 3,
                child: Center(
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: SlideTransition(
                      position: _slideAnimation,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Fuego Logo
                          Container(
                            width: 120,
                            height: 120,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: AppTheme.primaryGradient,
                              boxShadow: [
                                BoxShadow(
                                  color: AppTheme.primaryColor.withOpacity(0.4),
                                  blurRadius: 20,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Image.asset(
                                'assets/logo/fuegologo.png',
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                          const SizedBox(height: 32),
                          // App Name with animation
                          AnimatedTextKit(
                            animatedTexts: [
                              TypewriterAnimatedText(
                                'Fuego (XFG) Wallet',
                                textStyle: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.textPrimary,
                                  letterSpacing: 2,
                                ),
                                speed: const Duration(milliseconds: 100),
                              ),
                            ],
                            totalRepeatCount: 1,
                          ),
                          const SizedBox(height: 16),
                          // Brand
                          Text(
                            'HEATWAVE v1.11.0 (Suite) Release',
                            style: TextStyle(
                              fontSize: 20,
                              color: AppTheme.primaryColor,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 2,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'feat HEARTH Floor | DeXFG',
                            style: TextStyle(
                              fontSize: 14,
                              color: AppTheme.textSecondary,
                              fontWeight: FontWeight.w300,
                              letterSpacing: 1,
                            ),
                          ),
                          const SizedBox(height: 12),
                          // Swap pair
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                            decoration: BoxDecoration(
                              color: AppTheme.surfaceColor,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: AppTheme.primaryColor.withOpacity(0.3),
                                width: 1,
                              ),
                            ),
                            child: Text(
                              'XFG + ΗΞΔŦ',
                              style: TextStyle(
                                fontSize: 13,
                                color: AppTheme.primaryColor,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                flex: 1,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Loading indicator
                    const CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(
                        AppTheme.primaryColor,
                      ),
                      strokeWidth: 3,
                    ),
                    const SizedBox(height: 24),
                    // Status text
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: Text(
                        _initMessage,
                        key: ValueKey(_initMessage),
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppTheme.textSecondary,
                          fontWeight: FontWeight.w400,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    // Daemon error banner
                    if (_daemonWarning != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 32),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.warningColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.warningColor.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.warning_amber_rounded, color: AppTheme.warningColor, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _daemonWarning!,
                                style: const TextStyle(color: AppTheme.warningColor, fontSize: 12),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Footer
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    if (_versionString.isNotEmpty) ...[
                      Text(
                        _versionString,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.primaryColor.withOpacity(0.7),
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                    ],
                    Text(
                      'Based upon the CryptoNote protocol',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.textMuted,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.security,
                          size: 16,
                          color: AppTheme.successColor,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Sovereign • Untraceable • Purchasing Power',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textMuted,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Custom animated logo widget for more sophisticated animation
class AnimatedFuegoLogo extends StatefulWidget {
  const AnimatedFuegoLogo({super.key});

  @override
  State<AnimatedFuegoLogo> createState() => _AnimatedFuegoLogoState();
}

class _AnimatedFuegoLogoState extends State<AnimatedFuegoLogo>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _rotateController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _rotateAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );

    _rotateController = AnimationController(
      duration: const Duration(milliseconds: 10000),
      vsync: this,
    );

    _pulseAnimation = Tween<double>(
      begin: 0.8,
      end: 1.2,
    ).animate(CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    ));

    _rotateAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(_rotateController);

    _pulseController.repeat(reverse: true);
    _rotateController.repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _rotateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_pulseAnimation, _rotateAnimation]),
      builder: (context, child) {
        return Transform.scale(
          scale: _pulseAnimation.value,
          child: Transform.rotate(
            angle: _rotateAnimation.value * 2 * 3.14159,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: AppTheme.primaryGradient,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primaryColor.withOpacity(0.4),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(
                Icons.local_fire_department,
                size: 60,
                color: Colors.white,
              ),
            ),
          ),
        );
      },
    );
  }
}
