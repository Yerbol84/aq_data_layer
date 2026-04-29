/// Configuration for rate limiting
class RateLimitConfig {
  /// Global rate limit (requests per minute for entire system)
  final int globalLimit;

  /// Tenant rate limit (requests per minute per tenant)
  final int tenantLimit;

  /// User rate limit (requests per minute per user)
  final int userLimit;

  /// Time window in seconds (default: 60 seconds = 1 minute)
  final int windowSeconds;

  /// Maximum batch size for bulk operations
  final int maxBatchSize;

  /// Maximum query timeout in seconds
  final int maxQueryTimeoutSeconds;

  const RateLimitConfig({
    this.globalLimit = 10000,
    this.tenantLimit = 1000,
    this.userLimit = 100,
    this.windowSeconds = 60,
    this.maxBatchSize = 1000,
    this.maxQueryTimeoutSeconds = 30,
  });

  /// Development config with relaxed limits
  factory RateLimitConfig.development() {
    return const RateLimitConfig(
      globalLimit: 100000,
      tenantLimit: 10000,
      userLimit: 1000,
      windowSeconds: 60,
      maxBatchSize: 5000,
      maxQueryTimeoutSeconds: 120,
    );
  }

  /// Production config with strict limits
  factory RateLimitConfig.production() {
    return const RateLimitConfig(
      globalLimit: 10000,
      tenantLimit: 1000,
      userLimit: 100,
      windowSeconds: 60,
      maxBatchSize: 1000,
      maxQueryTimeoutSeconds: 30,
    );
  }
}

/// Result of rate limit check
class RateLimitResult {
  /// Whether the request is allowed
  final bool allowed;

  /// Current request count in window
  final int currentCount;

  /// Maximum allowed requests
  final int limit;

  /// Seconds until the oldest request expires (retry after)
  final int? retryAfterSeconds;

  /// Which limit was exceeded (if any)
  final String? limitType;

  const RateLimitResult({
    required this.allowed,
    required this.currentCount,
    required this.limit,
    this.retryAfterSeconds,
    this.limitType,
  });

  /// Create a result for allowed request
  factory RateLimitResult.allowed({
    required int currentCount,
    required int limit,
  }) {
    return RateLimitResult(
      allowed: true,
      currentCount: currentCount,
      limit: limit,
    );
  }

  /// Create a result for denied request
  factory RateLimitResult.denied({
    required int currentCount,
    required int limit,
    required int retryAfterSeconds,
    required String limitType,
  }) {
    return RateLimitResult(
      allowed: false,
      currentCount: currentCount,
      limit: limit,
      retryAfterSeconds: retryAfterSeconds,
      limitType: limitType,
    );
  }
}
