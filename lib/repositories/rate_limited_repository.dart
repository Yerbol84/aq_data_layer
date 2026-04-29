import '../security/rate_limit_store.dart';
import 'repository.dart';
import '../security/vault_rate_limiter.dart';
import '../security/dos_protection.dart';
import '../security/rate_limit_config.dart';
import '../security/dos_config.dart';

/// Repository wrapper that adds rate limiting and DoS protection
///
/// Wraps any repository and adds:
/// - Rate limiting (global/tenant/user)
/// - DoS protection (batch size, query complexity, memory limits)
/// - Automatic validation before operations
class RateLimitedRepository<T> implements Repository<T> {
  final Repository<T> _inner;
  final VaultRateLimiter _rateLimiter;
  final DosProtection _dosProtection;
  final String _tenantId;
  final String? _userId;

  RateLimitedRepository({
    required Repository<T> inner,
    required VaultRateLimiter rateLimiter,
    required DosProtection dosProtection,
    required String tenantId,
    String? userId,
  })  : _inner = inner,
        _rateLimiter = rateLimiter,
        _dosProtection = dosProtection,
        _tenantId = tenantId,
        _userId = userId;

  /// Check rate limit before operation
  Future<void> _checkRateLimit(String operation) async {
    final result = await _rateLimiter.checkLimit(
      tenantId: _tenantId,
      operation: operation,
      userId: _userId,
    );

    if (!result.allowed) {
      throw RateLimitExceededException(
        message: 'Rate limit exceeded for $operation',
        limitType: result.limitType!,
        retryAfterSeconds: result.retryAfterSeconds!,
        currentCount: result.currentCount,
        limit: result.limit,
      );
    }
  }

  @override
  Future<T> save(T entity) async {
    await _checkRateLimit('save');
    return _inner.save(entity);
  }

  @override
  Future<List<T>> saveAll(List<T> entities) async {
    await _checkRateLimit('saveAll');
    _dosProtection.validateBatchSize(entities.length, operation: 'saveAll');
    return _inner.saveAll(entities);
  }

  @override
  Future<T?> findById(String id) async {
    await _checkRateLimit('findById');
    return _inner.findById(id);
  }

  @override
  Future<List<T>> findAll({
    int? limit,
    int? offset,
    Map<String, dynamic>? where,
  }) async {
    await _checkRateLimit('findAll');

    // DoS protection: require pagination
    _dosProtection.validatePagination(limit: limit, offset: offset);

    return _inner.findAll(limit: limit, offset: offset, where: where);
  }

  @override
  Future<int> count({Map<String, dynamic>? where}) async {
    await _checkRateLimit('count');
    return _inner.count(where: where);
  }

  @override
  Future<void> delete(String id) async {
    await _checkRateLimit('delete');
    return _inner.delete(id);
  }

  @override
  Future<void> deleteAll(List<String> ids) async {
    await _checkRateLimit('deleteAll');
    _dosProtection.validateBatchSize(ids.length, operation: 'deleteAll');
    return _inner.deleteAll(ids);
  }

  @override
  Future<bool> exists(String id) async {
    await _checkRateLimit('exists');
    return _inner.exists(id);
  }

  /// Get current rate limit status
  Future<Map<String, dynamic>> getRateLimitStatus() async {
    return _rateLimiter.getStatus(
      tenantId: _tenantId,
      userId: _userId,
    );
  }
}

/// Exception thrown when rate limit is exceeded
class RateLimitExceededException implements Exception {
  final String message;
  final String limitType;
  final int retryAfterSeconds;
  final int currentCount;
  final int limit;

  const RateLimitExceededException({
    required this.message,
    required this.limitType,
    required this.retryAfterSeconds,
    required this.currentCount,
    required this.limit,
  });

  @override
  String toString() => 'RateLimitExceededException: $message '
      '($limitType: $currentCount/$limit, retry after ${retryAfterSeconds}s)';
}

/// Factory for creating rate-limited repositories
class RateLimitedRepositoryFactory {
  final VaultRateLimiter rateLimiter;
  final DosProtection dosProtection;

  RateLimitedRepositoryFactory({
    RateLimitConfig? rateLimitConfig,
    DosConfig? dosConfig,
    required RateLimitStore store,
  })  : rateLimiter = VaultRateLimiter(
          config: rateLimitConfig ?? RateLimitConfig.production(),
          store: store,
        ),
        dosProtection = DosProtection(
          config: dosConfig ?? DosConfig.production(),
        );

  /// Wrap repository with rate limiting and DoS protection
  RateLimitedRepository<T> wrap<T>({
    required Repository<T> repository,
    required String tenantId,
    String? userId,
  }) {
    return RateLimitedRepository<T>(
      inner: repository,
      rateLimiter: rateLimiter,
      dosProtection: dosProtection,
      tenantId: tenantId,
      userId: userId,
    );
  }
}
