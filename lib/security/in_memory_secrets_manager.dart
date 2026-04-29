import 'dart:math';
import 'dart:convert';
import 'secrets_manager.dart';
import 'secrets_cache.dart';

/// In-memory implementation of SecretsManager for testing/development
///
/// NOT FOR PRODUCTION USE - stores secrets in memory without encryption.
/// Use VaultSecretsManager or AwsSecretsManager for production.
class InMemorySecretsManager implements SecretsManager {
  final Map<String, _SecretEntry> _secrets = {};
  final SecretsCache _cache;
  final Random _random = Random.secure();

  InMemorySecretsManager({
    Duration cacheTTL = const Duration(minutes: 5),
  }) : _cache = SecretsCache(ttl: cacheTTL);

  @override
  Future<String> getSecret(String key) async {
    // Check cache first
    final cached = _cache.get(key);
    if (cached != null) return cached;

    // Get from storage
    final entry = _secrets[key];
    if (entry == null) {
      throw SecretNotFoundException(
        key: key,
        message: 'Secret not found',
      );
    }

    // Cache it
    _cache.set(key, entry.value);

    return entry.value;
  }

  @override
  Future<String> getSecretVersion(String key, String version) async {
    final entry = _secrets[key];
    if (entry == null) {
      throw SecretNotFoundException(
        key: key,
        message: 'Secret not found',
      );
    }

    final versionNum = int.tryParse(version);
    if (versionNum == null || versionNum != entry.version) {
      throw SecretOperationException(
        operation: 'getSecretVersion',
        message: 'Version not found',
      );
    }

    return entry.value;
  }

  @override
  Future<void> setSecret(
    String key,
    String value, {
    Map<String, String>? metadata,
  }) async {
    final now = DateTime.now();
    final existing = _secrets[key];

    _secrets[key] = _SecretEntry(
      value: value,
      version: existing != null ? existing.version + 1 : 1,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      metadata: metadata ?? {},
    );

    // Invalidate cache
    _cache.invalidate(key);
  }

  @override
  Future<void> rotateSecret(String key) async {
    final entry = _secrets[key];
    if (entry == null) {
      throw SecretNotFoundException(
        key: key,
        message: 'Secret not found',
      );
    }

    // Generate new secret based on type
    final newValue = _generateSecret(key);

    await setSecret(
      key,
      newValue,
      metadata: {
        ...entry.metadata,
        'rotated_at': DateTime.now().toIso8601String(),
        'previous_version': entry.version.toString(),
      },
    );
  }

  @override
  Future<List<String>> listSecrets() async {
    return _secrets.keys.toList();
  }

  @override
  Future<void> deleteSecret(String key) async {
    _secrets.remove(key);
    _cache.invalidate(key);
  }

  @override
  Future<SecretMetadata> getMetadata(String key) async {
    final entry = _secrets[key];
    if (entry == null) {
      throw SecretNotFoundException(
        key: key,
        message: 'Secret not found',
      );
    }

    return SecretMetadata(
      key: key,
      createdAt: entry.createdAt,
      lastRotated: entry.updatedAt != entry.createdAt ? entry.updatedAt : null,
      version: entry.version,
      tags: entry.metadata,
    );
  }

  @override
  Future<bool> exists(String key) async {
    return _secrets.containsKey(key);
  }

  /// Generate a new secret value based on key pattern
  String _generateSecret(String key) {
    if (key.contains('password') || key.contains('db_password')) {
      return _generatePassword(length: 32);
    }

    if (key.contains('api_key')) {
      return _generateApiKey();
    }

    if (key.contains('jwt_secret')) {
      return _generateJwtSecret();
    }

    // Default: random string
    return _generatePassword(length: 32);
  }

  String _generatePassword({int length = 32}) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#\$%^&*';
    return List.generate(length, (_) => chars[_random.nextInt(chars.length)])
        .join();
  }

  String _generateApiKey() {
    final bytes = List.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes);
  }

  String _generateJwtSecret() {
    final bytes = List.generate(64, (_) => _random.nextInt(256));
    return base64Url.encode(bytes);
  }
}

class _SecretEntry {
  final String value;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, String> metadata;

  _SecretEntry({
    required this.value,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    required this.metadata,
  });
}
