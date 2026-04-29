import 'rate_limit_store.dart';

/// In-memory implementation of RateLimitStore
///
/// Uses a Map to store request timestamps. Suitable for single-instance
/// deployments. For distributed systems, use Redis-backed implementation.
class InMemoryRateLimitStore implements RateLimitStore {
  final _store = <String, List<int>>{};

  @override
  Future<void> add(String key, int timestamp) async {
    _store.putIfAbsent(key, () => []).add(timestamp);
  }

  @override
  Future<int> count(String key) async {
    return _store[key]?.length ?? 0;
  }

  @override
  Future<void> removeOldEntries(String key, int beforeTimestamp) async {
    final entries = _store[key];
    if (entries == null) return;

    entries.removeWhere((timestamp) => timestamp < beforeTimestamp);

    if (entries.isEmpty) {
      _store.remove(key);
    }
  }

  @override
  Future<int?> getOldestEntry(String key) async {
    final entries = _store[key];
    if (entries == null || entries.isEmpty) return null;
    return entries.first;
  }

  @override
  Future<void> clear(String key) async {
    _store.remove(key);
  }

  @override
  Future<void> clearAll() async {
    _store.clear();
  }
}
