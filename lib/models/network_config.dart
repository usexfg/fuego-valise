enum NetworkType { mainnet, testnet }

class NetworkConfig {
  final NetworkType type;
  final String name;
  final String addressPrefix;
  final String networkId;
  final int daemonRpcPort;
  final int walletRpcPort;
  final List<String> seedNodes;
  final String? explorerUrl;
  final String? faucetUrl;

  const NetworkConfig({
    required this.type,
    required this.name,
    required this.addressPrefix,
    required this.networkId,
    required this.daemonRpcPort,
    required this.walletRpcPort,
    required this.seedNodes,
    this.explorerUrl,
    this.faucetUrl,
  });

  // Mainnet configuration
  static const NetworkConfig mainnet = NetworkConfig(
    type: NetworkType.mainnet,
    name: 'Fuego Mainnet',
    addressPrefix: 'fire',
    networkId: 'fuego-mainnet',
    daemonRpcPort: 18180,
    walletRpcPort: 18189,
    seedNodes: [
      '207.244.247.64:18180',
      'node1.usexfg.org:18180',
      'node2.usexfg.org:18180',
      'fuego.seednode1.com:18180',
      'fuego.seednode2.com:18180',
      'fuego.communitynode.net:18180',
    ],
    explorerUrl: 'https://explorer.usexfg.org',
  );

  // Testnet configuration
  static const NetworkConfig testnet = NetworkConfig(
    type: NetworkType.testnet,
    name: 'Fuego Testnet',
    addressPrefix: 'TEST',
    networkId: 'fuego-testnet',
    daemonRpcPort: 20808,
    walletRpcPort: 28280,
    seedNodes: [
      'testnet1.usexfg.org:20808',
      'testnet2.usexfg.org:20808',
      'fuego-testnet.seednode1.com:20808',
      'fuego-testnet.seednode2.com:20808',
    ],
    explorerUrl: 'https://testnet-explorer.usexfg.org',
    faucetUrl: 'https://testnet-faucet.usexfg.org',
  );

  // Get configuration by type
  static NetworkConfig getConfig(NetworkType type) {
    switch (type) {
      case NetworkType.mainnet:
        return mainnet;
      case NetworkType.testnet:
        return testnet;
    }
  }

  // Get all available configurations
  static List<NetworkConfig> getAllConfigs() {
    return [mainnet, testnet];
  }

  // Check if this is testnet
  bool get isTestnet => type == NetworkType.testnet;

  // Check if this is mainnet
  bool get isMainnet => type == NetworkType.mainnet;

  // Get formatted network info
  String get networkInfo => '$name ($networkId)';

  // Get default seed node
  String get defaultSeedNode => seedNodes.isNotEmpty ? seedNodes.first : '';

  @override
  String toString() {
    return 'NetworkConfig(type: $type, name: $name, daemonPort: $daemonRpcPort, walletPort: $walletRpcPort)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NetworkConfig && other.type == type;
  }

  @override
  int get hashCode => type.hashCode;
}
