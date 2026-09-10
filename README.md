#  Fuego Valise 💼

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.44.4-blue?logo=flutter" alt="Flutter Version" />
  <img src="https://img.shields.io/badge/Dart-3.4.3-blue?logo=dart" alt="Dart Version" />
  <img src="https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20macOS%20%7C%20Linux%20%7C%20Windows-lightgrey" alt="Platform Support" />
  <img src="https://img.shields.io/badge/License-MIT-green" alt="License" />
</p>

A desktop & mobile _valise_ for Fuego Blockchain Bank of **XFG** privacy cryptocurrency & Fuego's new flatcoin ΗΞΔŦ - pegged to purchasing power by tracking the US dollar's rate of inflation since Q1|2009 (or 1.58)
Burn XFG to mint ΗΞΔŦ or buy & sell on HⲈⲆ☈ⲦН Floor; Fuego's on-chain orderbook block-discrete market swap & limit order exchange, DeXFG cross-chain atomic (PTLC & HTLC) swaps, earn yield on ΗΞΔŦ_𝖢𝖣s, register your 8-character fire alias, built-in pool mining and more. 🔥

<p align="center">
  <img src="https://github.com/usexfg/fuego-valise/raw/master/assets/images/xfgwalletdesktopsplash.gif" alt="Fuego Valise Screenshot" />
</p>

### 🔐 Advanced Security
- **PIN Authentication** with PBKDF2 secure hashing
- **Biometric Authentication** (fingerprint/Face ID)
- **AES-256-CBC Encryption** for wallet data
- **Secure Device Storage** with hardware keychain
- **25-word Mnemonic** backup / recovery

### 💼 Valise Management
- **Create New Wallets** with secure entropy
- **Restore from Backup** using mnemonic phrase or private keys
- **Real-time Balance Display** with privacy toggle
- **Blockchain Sync** progress tracking
- **Transaction History** with confirmation status monitoring

### 💸 Privacy Transactions
- **Send XFG** or ΗΞΔŦ; default max privacy levels
- **Ring Signatures** (8-32 mixins for anonymity)
- **Receive with QR Codes** and integrated addresses
- **Open Alias Support** for oa1:xfg transactions
- **Fee Estimation** and validation

### ⛏️ Built-in Mining
- **CPU Mining Controls** directly from device
- **Thread Configuration** (1-8 CPU threads)
- **Real-time Hashrate** monitoring
- **Mining Performance** tracking

### 🔄 Unified Daemon
The app uses a **unified daemon** process (`unified`) that bundles fuegod, walletd, and xfg-swapd into a single embedded process for local node operation. When the unified daemon is unavailable, the app falls back to a remote node connection.

## Get Started

### Prerequisites

- **Flutter SDK**: 3.44.4 or higher
- **Dart SDK**: 3.4.3 or higher
- **Android Studio** / **Xcode** for platform-specific builds
- **Internet connection** to connect to Fuego network nodes

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/usexfg/fuego-valise.git
   cd fuego-valise
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Run the app**
   ```bash
   flutter run
   ```

### Building for Production

```bash
# Android APK
flutter build apk --release

# Android App Bundle
flutter build appbundle --release

# iOS (requires Xcode)
flutter build ios --release

# macOS
flutter build macos --release

# Linux
flutter build linux --release

# Windows
flutter build windows --release
```

##  Architecture

### Project Structure
```
lib/
├── main.dart                          # App entry point
├── models/                            # Data models
│   ├── candlestick.dart
│   ├── cd.dart
│   ├── heat_amm.dart
│   ├── network_config.dart
│   ├── subaddress.dart
│   ├── swap_models.dart
│   ├── transaction_model.dart
│   ├── wallet.dart
│   └── wallet.g.dart
├── services/                          # Business logic
│   ├── cli_service.dart
│   ├── daemon_event_bus.dart          # Unified daemon health monitoring
│   ├── daemon_manager.dart            # Daemon lifecycle management
│   ├── fuego_daemon_client.dart       # Fuego node RPC client
│   ├── fuego_rpc_service.dart         # RPC communication
│   ├── fuego_vault_service.dart       # Vault management
│   ├── output_scanner.dart
│   ├── pool_mining_service.dart
│   ├── price_history_service.dart
│   ├── security_service.dart          # Secure storage & PIN auth
│   ├── swap_config_service.dart
│   ├── swap_daemon_client.dart
│   ├── wallet_service.dart
│   ├── walletd_service.dart
│   └── web3_multi_chain_service.dart
├── providers/                         # State management
│   └── wallet_provider.dart
├── screens/                           # UI screens
│   ├── auth/                          # Authentication
│   ├── cd/                            # CD/staking features
│   ├── dex/                           # DEX swap interface
│   ├── fuego/                         # Fuego-specific features
│   ├── home/                          # Main dashboard
│   ├── main/                          # Main navigation
│   ├── settings/                      # Configuration
│   ├── splash_screen.dart             # Launch screen
│   └── transactions/                  # Send/receive
├── widgets/                           # Reusable components
│   ├── fuego_chart.dart
│   ├── mnemonic_display.dart
│   ├── mnemonic_input.dart
│   ├── pin_input_widget.dart
│   └── quick_actions.dart
└── utils/                             # Utilities & theming
    ├── hearth_theme.dart
    └── theme.dart
```

### State Management
- **Provider Pattern** for reactive state management
- **Clean Architecture** with separation of concerns
- **Complete Error Handling** throughout

### Daemon Architecture
The app supports two daemon modes:

| Mode | Description | Ports |
|------|-------------|-------|
| **Unified** (preferred) | Single `unified` binary bundling fuegod + walletd + xfg-swapd | walletd: 18189 |
| **Separate** | Individual daemons (fuegod, fuego_walletd, xfg-swapd) | fuegod: 18180, walletd: 18189, swapd: 18902 |

The unified daemon is started automatically when the binary is present in the app bundle. If it fails (missing binary, port conflict, Keychain error), the app falls back to remote node mode.

### Security Implementation
- **Multi-layered Encryption** with industry standards
- **Hardware Security Integration** when available (Keychain on macOS, Keystore on Android)
- **Memory Protection** with automatic data clearing
- **Secure Key Derivation** and storage

##  Configuration

### Local Node (Unified Daemon)
When running with a local node, the app uses the unified daemon process. The daemon is managed automatically by `DaemonManager`:

- **walletd port**: `18189` (unified daemon binds here)
- **fuegod port**: `18180` (internal, managed by unified daemon)
- **swapd port**: `18902` (internal, managed by unified daemon)

### Remote Node Connection
The app connects to remote Fuego network nodes by default. You can configure custom nodes in the app settings.

#### Default Remote Nodes
The app includes several pre-configured remote nodes:
- `207.244.247.64:18180`
- `node1.usexfg.org`
- `node2.usexfg.org`
- `fuego.seednode1.com`
- `fuego.seednode2.com`

#### Custom Node Configuration
You can add custom nodes through the Settings > Node Connection menu, or modify the defaults in:
```dart
// lib/services/fuego_rpc_service.dart
static const List<String> defaultRemoteNodes = [
  'node1.usexfg.org',
  'node2.usexfg.org',
  // ... more nodes
];
```

#### Node Requirements
- RPC port: `18180` (default)
- Must support standard CryptoNote RPC methods

## Security Features

### Cryptographic Protection
- **AES-256-CBC** encryption for all stored wallet data
- **PBKDF2** key derivation with 100,000 iterations
- **Secure random generation** for keys and entropy
- **Hardware security module** integration when available

### Privacy Features
- **Dynamaxin** for highest possible privacy (per available decoy outputs: min 8 max 32)
- **Subaddresses** for better transaction privacy
- **No data tracking** - all operations local

### Authentication Security
- **Multi-factor authentication** with PIN or optional biometric 
- **Failed attempt protection** with progressive lockout
- **Secure session management** with timeout
- **Device binding** with hardware-specific keys

## 🌐 Supported Platforms

- ✅ **Android 7.0+** (API level 24+)
- ✅ **iOS 12.0+**
- ✅ **macOS Desktop**
- ✅ **Linux Desktop**
- ✅ **Windows Desktop**

## 🧪 Testing

```bash
# Run all tests
flutter test

# Run tests with coverage
flutter test --coverage

# Run integration tests
flutter drive --target=test_driver/app.dart
```

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guidelines](CONTRIBUTING.md) for details.

### Development Setup

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Make your changes and test thoroughly
4. Commit your changes: `git commit -m 'Add amazing feature'`
5. Push to the branch: `git push origin feature/amazing-feature`
6. Open a Pull Request

### Code Style

- Follow [Flutter's style guide](https://dart.dev/guides/language/effective-dart/style)
- Use `flutter analyze` to check for issues
- Format code with `dart format`
- Write tests for new features

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🔗 Links

- **Fuego Website**: [https://usexfg.org](https://usexfg.org)
- **Main Repository**: [https://github.com/usexfg/fuego-valise](https://github.com/usexfg/fuego-valise)
- **Discord**: [https://discord.gg/5UJcJJg](https://discord.gg/5UJcJJg)
- **Twitter**: [https://twitter.com/useXFG](https://twitter.com/useXFG)

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/usexfg/fuego-valise/issues)
- **Discord**: [Fuego Community](https://discord.gg/5UJcJJg)

## ⚠️ Disclaimer

Fuogo Valise is provided "as is" without warranty. Cryptocurrency transactions are irreversible. Always:
- **Backup your wallet** securely
- **Verify transactions** before sending
- **Use at your own risk**
- **Keep your backup phrase safe**

---

<p align="center">
  <strong> Built with 🔥 for The Fuego Mob</strong>
</p>  
