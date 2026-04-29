/// Configuration for DoS protection
class DosConfig {
  /// Maximum batch size for bulk operations
  final int maxBatchSize;

  /// Maximum query result limit
  final int maxQueryLimit;

  /// Maximum query timeout in seconds
  final int maxQueryTimeoutSeconds;

  /// Maximum memory per query (bytes)
  final int maxMemoryPerQuery;

  /// Maximum query complexity score
  final int maxQueryComplexity;

  const DosConfig({
    this.maxBatchSize = 1000,
    this.maxQueryLimit = 10000,
    this.maxQueryTimeoutSeconds = 30,
    this.maxMemoryPerQuery = 100 * 1024 * 1024, // 100 MB
    this.maxQueryComplexity = 1000,
  });

  /// Development config with relaxed limits
  factory DosConfig.development() {
    return const DosConfig(
      maxBatchSize: 10000,
      maxQueryLimit: 100000,
      maxQueryTimeoutSeconds: 300,
      maxMemoryPerQuery: 1024 * 1024 * 1024, // 1 GB
      maxQueryComplexity: 10000,
    );
  }

  /// Production config with strict limits
  factory DosConfig.production() {
    return const DosConfig(
      maxBatchSize: 1000,
      maxQueryLimit: 10000,
      maxQueryTimeoutSeconds: 30,
      maxMemoryPerQuery: 100 * 1024 * 1024, // 100 MB
      maxQueryComplexity: 1000,
    );
  }
}

/// DoS protection exception
class DosProtectionException implements Exception {
  final String message;
  final String violationType;
  final dynamic limit;
  final dynamic actual;

  const DosProtectionException({
    required this.message,
    required this.violationType,
    required this.limit,
    required this.actual,
  });

  @override
  String toString() => 'DosProtectionException: $message '
      '(limit: $limit, actual: $actual, type: $violationType)';
}
