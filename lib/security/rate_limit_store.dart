/// Abstract interface for rate limit storage
///
/// Stores request timestamps for rate limiting using sliding window algorithm.
/// Implementations can use in-memory storage, Redis, or other backends.
abstract class RateLimitStore {
  /// Add a request timestamp for the given key
  Future<void> add(String key, int timestamp);

  /// Count requests in the current window for the given key
  Future<int> count(String key);

  /// Remove entries older than the given timestamp
  Future<void> removeOldEntries(String key, int beforeTimestamp);

  /// Get the oldest entry timestamp for the given key
  /// Returns null if no entries exist
  Future<int?> getOldestEntry(String key);

  /// Clear all entries for the given key
  Future<void> clear(String key);

  /// Clear all entries in the store
  Future<void> clearAll();
}
