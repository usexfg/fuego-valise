import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../main.dart' as app;
import '../../models/network_config.dart';
import '../../providers/wallet_provider.dart';
import '../../utils/theme.dart';

class NetworkSelectionScreen extends StatefulWidget {
  const NetworkSelectionScreen({super.key});

  @override
  State<NetworkSelectionScreen> createState() => _NetworkSelectionScreenState();
}

class _NetworkSelectionScreenState extends State<NetworkSelectionScreen> {
  NetworkConfig _selectedNetwork = app.nodeConnection.networkConfig;
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Network Selection'),
        backgroundColor: AppTheme.backgroundColor,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Choose Network',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Select the Fuego network you want to connect to:',
              style: TextStyle(
                fontSize: 16,
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            
            // Mainnet Option
            _buildNetworkCard(
              config: NetworkConfig.mainnet,
              icon: Icons.public,
              color: Colors.green,
              description: 'Production network with real XFG tokens',
            ),
            
            const SizedBox(height: 16),
            
            // Testnet Option
            _buildNetworkCard(
              config: NetworkConfig.testnet,
              icon: Icons.science,
              color: Colors.orange,
              description: 'Testing network with test tokens',
            ),
            
            const SizedBox(height: 32),
            
            // Network Info Card
            if (_selectedNetwork.isTestnet) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.info_outline, color: Colors.orange),
                        const SizedBox(width: 8),
                        const Text(
                          'Testnet Information',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.orange,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '• Test tokens have no real value\n'
                      '• Perfect for testing and development\n'
                      '• Faster block times for testing\n'
                      '• Separate from mainnet funds',
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                    if (_selectedNetwork.faucetUrl != null) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () {
                          // TODO: Open faucet URL
                        },
                        icon: const Icon(Icons.water_drop),
                        label: const Text('Get Test Tokens'),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            
            // Connect Button
            ElevatedButton(
              onPressed: _isLoading ? null : _connectToNetwork,
              style: ElevatedButton.styleFrom(
                backgroundColor: _selectedNetwork.isTestnet ? Colors.orange : AppTheme.primaryColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.all(16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _isLoading
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        ),
                        SizedBox(width: 12),
                        Text('Connecting...'),
                      ],
                    )
                  : Text('Connect to ${_selectedNetwork.name}'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNetworkCard({
    required NetworkConfig config,
    required IconData icon,
    required Color color,
    required String description,
  }) {
    final isSelected = _selectedNetwork == config;
    
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedNetwork = config;
        });
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected 
              ? color.withOpacity(0.1) 
              : AppTheme.backgroundColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? color : AppTheme.textSecondary.withOpacity(0.3),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    config.name,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? color : AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _buildInfoChip('Daemon: ${config.daemonRpcPort}'),
                      const SizedBox(width: 8),
                      _buildInfoChip('Wallet: ${config.walletRpcPort}'),
                    ],
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle, color: color, size: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.textSecondary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }

  Future<void> _connectToNetwork() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final walletProvider = Provider.of<WalletProvider>(context, listen: false);
      final ep = await app.nodeConnection.switchNetwork(_selectedNetwork);
      await walletProvider.updateNetworkConfig(_selectedNetwork);
      if (!ep.proxyRunning) {
        throw Exception(ep.error ?? 'wallet proxy did not start');
      }

      // Show success message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connected to ${_selectedNetwork.name}'),
            backgroundColor: _selectedNetwork.isTestnet ? Colors.orange : Colors.green,
          ),
        );
        
        // Navigate back or to main screen
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to connect: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }
}
