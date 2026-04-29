import 'rate_limit_config.dart';
import 'rate_limit_store.dart';

/// Multi-level rate limiter using sliding window algorithm
///
/// Implements three levels of rate limiting:
/// 1. Global: Protects entire system from overload
/// 2. Tenant: Isolates tenants from each other
/// 3. User: Prevents single user abuse
class VaultRateLimiter {
  final RateLimitConfig config;
  final RateLimitStore store;

  VaultRateLimiter({
    required this.config,
    required this.store,
  });

  /// Check if request is allowed under rate limits
  ///
  /// Checks limits in order: global → tenant → user
  /// Returns first limit that is exceeded, or allowed if all pass
  Future<RateLimitResult> checkLimit({
    required String tenantId,
    required String operation,
    String? userId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final windowStart = now - (config.windowSeconds * 1000);

    // Level 1: Global limit
    final globalKey = 'global';
    final globalResult = await _checkSingleLimit(
      key: globalKey,
      limit: config.globalLimit,
      now: now,
      windowStart: windowStart,
      limitType: 'global',
    );
    if (!globalResult.allowed) return globalResult;

    // Level 2: Tenant limit
    final tenantKey = 'tenant:$tenantId';
    final tenantResult = await _checkSingleLimit(
      key: tenantKey,
      limit: config.tenantLimit,
      now: now,
      windowStart: windowStart,
      limitType: 'tenant',
    );
    if (!tenantResult.allowed) return tenantResult;

    // Level 3: User limit (if userId provided)
    if (userId != null) {
      final userKey = 'user:$tenantId:$userId';
      final userResult = await _checkSingleLimit(
        key: userKey,
        limit: config.userLimit,
        now: now,
        windowStart: windowStart,
        limitType: 'user',
      );
      if (!userResult.allowed) return userResult;
    }

    // All limits passed - record the request
    await _recordRequest(globalKey, tenantKey, userId != null ? 'user:$tenantId:$userId' : null, now);

    return RateLimitResult.allowed(
      currentCount: globalResult.currentCount + 1,
      limit: config.globalLimit,
    );
  }

  /// Check a single rate limit
  Future<RateLimitResult> _checkSingleLimit({
    required String key,
    required int limit,
    required int now,
    required int windowStart,
    required String limitType,
  }) async {
    // Clean up old entries
    await store.removeOldEntries(key, windowStart);

    // Count current requests in window
    final count = await store.count(key);

    // Check if limit exceeded
    if (count >= limit) {
      // Calculate retry-after based on oldest entry
      final oldestEntry = await store.getOldestEntry(key);
      final retryAfterMs = oldestEntry != null
          ? (oldestEntry + (config.windowSeconds * 1000)) - now
          : config.windowSeconds * 1000;
      final retryAfterSeconds = (retryAfterMs / 1000).ceil();

      return RateLimitResult.denied(
        currentCount: count,
        limit: limit,
        retryAfterSeconds: retryAfterSeconds,
        limitType: limitType,
      );
    }

    return RateLimitResult.allowed(
      currentCount: count,
      limit: limit,
    );
  }

  /// Record request in all applicable stores
  Future<void> _recordRequest(
    String globalKey,
    String tenantKey,
    String? userKey,
    int timestamp,
  ) async {
    await store.add(globalKey, timestamp);
    await store.add(tenantKey, timestamp);
    if (userKey != null) {
      await store.add(userKey, timestamp);
    }
  }

  /// Get current rate limit status for debugging
  Future<Map<String, dynamic>> getStatus({
    required String tenantId,
    String? userId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final windowStart = now - (config.windowSeconds * 1000);

    final globalKey = 'global';
    final tenantKey = 'tenant:$tenantId';
    final userKey = userId != null ? 'user:$tenantId:$userId' : null;

    await store.removeOldEntries(globalKey, windowStart);
    await store.removeOldEntries(tenantKey, windowStart);
    if (userKey != null) {
      await store.removeOldEntries(userKey, windowStart);
    }

    final globalCount = await store.count(globalKey);
    final tenantCount = await store.count(tenantKey);
    final userCount = userKey != null ? await store.count(userKey) : null;

    return {
      'global': {
        'count': globalCount,
        'limit': config.globalLimit,
        'remaining': config.globalLimit - globalCount,
      },
      'tenant': {
        'count': tenantCount,
        'limit': config.tenantLimit,
        'remaining': config.tenantLimit - tenantCount,
      },
      if (userCount != null)
        'user': {
          'count': userCount,
          'limit': config.userLimit,
          'remaining': config.userLimit - userCount,
        },
    };
  }
}
