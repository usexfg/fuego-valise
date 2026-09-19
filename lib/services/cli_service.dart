import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:logging/logging.dart';

class BurnProofAnalytics {
  static final Logger _logger = Logger('BurnProofService');

  static void logBurnProofGeneration(BurnProofResult result) {
    _logger.info(
      'Burn Proof Generated: '
      'Amount: ${result.burnAmount}, '
      'Recipient: ${result.recipientAddress}, '
      'Proof Hash: ${result.proofHash}',
    );
  }

  static void logBurnProofError(dynamic error, StackTrace stackTrace) {
    _logger.severe('Burn Proof Generation Failed', error, stackTrace);
  }
}

class BurnProofResult {
  final String proofHash;
  final int burnAmount;
  final String recipientAddress;
  final DateTime timestamp;

  const BurnProofResult({
    required this.proofHash,
    required this.burnAmount,
    required this.recipientAddress,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'proofHash': proofHash,
    'burnAmount': burnAmount,
    'recipientAddress': recipientAddress,
    'timestamp': timestamp.toIso8601String(),
  };

  factory BurnProofResult.fromJson(Map<String, dynamic> json) =>
      BurnProofResult(
        proofHash: json['proofHash'],
        burnAmount: json['burnAmount'],
        recipientAddress: json['recipientAddress'],
        timestamp: DateTime.parse(json['timestamp']),
      );
}

class CLIService {
  static final Logger _logger = Logger('CLIService');

  /// Supported burn denominations
  static const Map<String, int> burnDenominations = {
    'Standard Burn': 800000, // 0.8 XFG = 8 Million HEAT
    'Large Burn': 80000000, // 800 XFG = 8 Billion HEAT
  };

  /// Determines the correct path for the CLI binary based on the current platform
  static Future<String> _getBinaryPath() async {
    final Directory appDir = await getApplicationSupportDirectory();
    final String binaryName = Platform.isWindows
        ? 'xfg-stark-cli.exe'
        : Platform.isMacOS
        ? 'xfg-stark-cli-macos'
        : 'xfg-stark-cli-linux';

    return path.join(appDir.path, 'bin', binaryName);
  }

  /// Extracts the bundled CLI binary to a temporary directory
  static Future<String> _extractBinary() async {
    try {
      final Directory tempDir = await getTemporaryDirectory();
      final String binaryName = Platform.isWindows
          ? 'xfg-stark-cli.exe'
          : Platform.isMacOS
          ? 'xfg-stark-cli-macos'
          : 'xfg-stark-cli-linux';

      final File binaryFile = File(path.join(tempDir.path, binaryName));

      // Extract binary from assets
      final ByteData data = await rootBundle.load('assets/bin/$binaryName');
      await binaryFile.create(recursive: true);
      await binaryFile.writeAsBytes(data.buffer.asUint8List());

      // Set executable permissions for non-Windows platforms
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', binaryFile.path]);
      }

      _logger.info('CLI binary extracted successfully: $binaryName');
      return binaryFile.path;
    } catch (e, stackTrace) {
      _logger.severe('Failed to extract CLI binary', e, stackTrace);
      throw Exception('Failed to extract CLI binary: $e');
    }
  }

  /// Generates a STARK proof for a burn transaction
  static Future<BurnProofResult> generateBurnProof({
    required String transactionHash,
    required String recipientAddress,
    required int burnAmount,
    String burnType = 'Standard Burn',
  }) async {
    try {
      // Validate Ethereum address
      if (!isValidEthereumAddress(recipientAddress)) {
        throw ArgumentError('Invalid Ethereum address');
      }

      // Validate burn amount
      if (!burnDenominations.containsKey(burnType)) {
        throw ArgumentError('Invalid burn type');
      }

      // Extract or get the CLI binary path
      final String binaryPath = await _extractBinary();

      // Prepare the process arguments
      final List<String> args = [
        'burn-proof',
        transactionHash,
        recipientAddress,
        burnAmount.toString(),
        burnType,
      ];

      // Run the CLI command
      final ProcessResult result = await Process.run(binaryPath, args);

      // Check the result
      if (result.exitCode == 0) {
        // Parse the output to extract proof details
        final Map<String, dynamic> proofDetails = _parseProofOutput(
          result.stdout,
        );

        final BurnProofResult proofResult = BurnProofResult(
          proofHash: proofDetails['proofHash'],
          burnAmount: burnAmount,
          recipientAddress: recipientAddress,
          timestamp: DateTime.now(),
        );

        // Log the successful burn proof generation
        BurnProofAnalytics.logBurnProofGeneration(proofResult);

        return proofResult;
      } else {
        // Log the error
        _logger.severe('Burn proof generation failed: ${result.stderr}');
        throw Exception('Burn proof generation failed: ${result.stderr}');
      }
    } catch (e, stackTrace) {
      // Log the error
      BurnProofAnalytics.logBurnProofError(e, stackTrace);
      rethrow;
    }
  }

  /// Parse the output from the CLI burn proof generation
  static Map<String, dynamic> _parseProofOutput(String output) {
    try {
      // This is a placeholder. Actual parsing depends on the CLI tool's output format
      return {
        'proofHash': output.trim(), // Assuming the output is the proof hash
      };
    } catch (e) {
      _logger.severe('Error parsing proof output: $e');
      throw FormatException('Unable to parse burn proof output');
    }
  }

  /// Validates an Ethereum address
  static bool isValidEthereumAddress(String address) {
    // Basic Ethereum address validation
    final RegExp ethAddressRegex = RegExp(r'^0x[a-fA-F0-9]{40}$');
    return ethAddressRegex.hasMatch(address);
  }

  /// Calculates HEAT token amount based on burn amount
  static int calculateHeatTokens(int burnAmount) {
    // Conversion logic based on burn denominations
    if (burnAmount == burnDenominations['Standard Burn']) {
      return 8000000; // 8 Million HEAT
    } else if (burnAmount == burnDenominations['Large Burn']) {
      return 8000000000; // 8 Billion HEAT
    }
    throw ArgumentError('Invalid burn amount');
  }
}
