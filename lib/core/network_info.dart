class NetworkInfo {
  final int height;
  final String topBlockHash;
  final int difficulty;
  final int hashrate;
  final int peerCount;
  final int txCount;
  final int txPoolSize;

  const NetworkInfo({
    required this.height,
    required this.topBlockHash,
    required this.difficulty,
    required this.hashrate,
    required this.peerCount,
    required this.txCount,
    required this.txPoolSize,
  });

  factory NetworkInfo.fromJson(Map<String, dynamic> json) => NetworkInfo(
    height: json['height'] as int,
    topBlockHash: json['top_block_hash'] as String? ?? '',
    difficulty: json['difficulty'] as int? ?? 0,
    hashrate: json['hashrate'] as int? ?? 0,
    peerCount:
        (json['incoming_connections_count'] as int? ?? 0) +
        (json['outgoing_connections_count'] as int? ?? 0),
    txCount: json['tx_count'] as int? ?? 0,
    txPoolSize: json['tx_pool_size'] as int? ?? 0,
  );
}
