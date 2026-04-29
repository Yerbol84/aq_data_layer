/// Simple in-memory cache for secrets
///
/// Caches secrets for a configurable TTL to reduce load on secrets backend.
/// Thread-safe for concurrent access.
class SecretsCache {
  final Duration ttl;
  final Map<String, _CacheEntry> _cache = {};

  SecretsCache({required this.ttl});

  /// Get cached secret value
  String? get(String key) {
    final entry = _cache[key];
    if (entry == null) return null;

    if (DateTime.now().isAfter(entry.expiresAt)) {
      _cache.remove(key);
      return null;
    }

    return entry.value;
  }

  /// Cache secret value
  void set(String key, String value) {
    _cache[key] = _CacheEntry(
      value: value,
      expiresAt: DateTime.now().add(ttl),
    );
  }

  /// Invalidate cached secret
  void invalidate(String key) {
    _cache.remove(key);
  }

  /// Clear all cached secrets
  void clear() {
    _cache.clear();
  }

  /// Get cache statistics
  Map<String, dynamic> getStats() {
    final now = DateTime.now();
    final expired = _cache.values.where((e) => now.isAfter(e.expiresAt)).length;

    return {
      'total': _cache.length,
      'active': _cache.length - expired,
      'expired': expired,
      'ttl_seconds': ttl.inSeconds,
    };
  }

  /// Remove expired entries
  void cleanup() {
    final now = DateTime.now();
    _cache.removeWhere((key, entry) => now.isAfter(entry.expiresAt));
  }
}

class _CacheEntry {
  final String value;
  final DateTime expiresAt;

  _CacheEntry({
    required this.value,
    required this.expiresAt,
  });
}
