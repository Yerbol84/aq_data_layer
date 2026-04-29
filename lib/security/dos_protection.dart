import 'dos_config.dart';

/// DoS (Denial of Service) protection layer
///
/// Protects the system from:
/// - Oversized batch operations
/// - Complex queries that consume too much memory
/// - Unbounded queries without pagination
/// - Long-running queries
class DosProtection {
  final DosConfig config;

  DosProtection({required this.config});

  /// Validate batch size for bulk operations
  void validateBatchSize(int size, {String? operation}) {
    if (size > config.maxBatchSize) {
      throw DosProtectionException(
        message: 'Batch size exceeds maximum allowed',
        violationType: 'batch_size',
        limit: config.maxBatchSize,
        actual: size,
      );
    }
  }

  /// Validate query limit
  void validateQueryLimit(int? limit) {
    if (limit != null && limit > config.maxQueryLimit) {
      throw DosProtectionException(
        message: 'Query limit exceeds maximum allowed',
        violationType: 'query_limit',
        limit: config.maxQueryLimit,
        actual: limit,
      );
    }
  }

  /// Validate that findAll has pagination
  void validatePagination({int? limit, int? offset}) {
    if (limit == null) {
      throw DosProtectionException(
        message: 'findAll without limit is not allowed (DoS protection)',
        violationType: 'missing_pagination',
        limit: 'required',
        actual: 'null',
      );
    }

    validateQueryLimit(limit);
  }

  /// Estimate query complexity score
  ///
  /// Complexity factors:
  /// - Number of conditions (each adds 10 points)
  /// - OR conditions (each adds 20 points)
  /// - IN conditions with large lists (adds 5 * list.length)
  /// - LIKE/contains operations (each adds 15 points)
  /// - Result limit (adds limit / 100)
  int estimateQueryComplexity({
    int conditions = 0,
    int orConditions = 0,
    int inConditions = 0,
    int inListSize = 0,
    int likeConditions = 0,
    int? resultLimit,
  }) {
    var complexity = 0;

    // Base conditions
    complexity += conditions * 10;

    // OR conditions are more expensive
    complexity += orConditions * 20;

    // IN conditions with large lists
    complexity += inConditions * 5 * inListSize;

    // LIKE/contains operations
    complexity += likeConditions * 15;

    // Result limit
    if (resultLimit != null) {
      complexity += resultLimit ~/ 100;
    }

    return complexity;
  }

  /// Validate query complexity
  void validateQueryComplexity(int complexity) {
    if (complexity > config.maxQueryComplexity) {
      throw DosProtectionException(
        message: 'Query complexity exceeds maximum allowed',
        violationType: 'query_complexity',
        limit: config.maxQueryComplexity,
        actual: complexity,
      );
    }
  }

  /// Estimate memory usage for query result
  ///
  /// Rough estimation based on:
  /// - Number of results
  /// - Average entity size
  int estimateMemoryUsage({
    required int resultCount,
    required int avgEntitySizeBytes,
  }) {
    return resultCount * avgEntitySizeBytes;
  }

  /// Validate memory usage
  void validateMemoryUsage(int estimatedBytes) {
    if (estimatedBytes > config.maxMemoryPerQuery) {
      throw DosProtectionException(
        message: 'Estimated memory usage exceeds maximum allowed',
        violationType: 'memory_limit',
        limit: config.maxMemoryPerQuery,
        actual: estimatedBytes,
      );
    }
  }

  /// Validate timeout
  void validateTimeout(Duration? timeout) {
    if (timeout != null &&
        timeout.inSeconds > config.maxQueryTimeoutSeconds) {
      throw DosProtectionException(
        message: 'Query timeout exceeds maximum allowed',
        violationType: 'timeout',
        limit: config.maxQueryTimeoutSeconds,
        actual: timeout.inSeconds,
      );
    }
  }

  /// Check if operation is safe
  ///
  /// Returns true if all checks pass, throws exception otherwise
  bool isSafe({
    int? batchSize,
    int? queryLimit,
    int? queryComplexity,
    int? memoryUsage,
    Duration? timeout,
  }) {
    if (batchSize != null) {
      validateBatchSize(batchSize);
    }

    if (queryLimit != null) {
      validateQueryLimit(queryLimit);
    }

    if (queryComplexity != null) {
      validateQueryComplexity(queryComplexity);
    }

    if (memoryUsage != null) {
      validateMemoryUsage(memoryUsage);
    }

    if (timeout != null) {
      validateTimeout(timeout);
    }

    return true;
  }
}
