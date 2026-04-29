import 'secrets_manager.dart';
import 'secrets_cache.dart';

/// Mock AWS Secrets Manager implementation for testing
///
/// NOTE: This is a simplified mock implementation.
/// For production, use the official AWS SDK for Dart.
class AwsSecretsManager implements SecretsManager {
  final String _region;
  final SecretsCache _cache;
  final Map<String, _AwsSecret> _mockStorage = {};

  AwsSecretsManager({
    required String region,
    String? accessKeyId,
    String? secretAccessKey,
    Duration cacheTTL = const Duration(minutes: 5),
  })  : _region = region,
        _cache = SecretsCache(ttl: cacheTTL);

  @override
  Future<String> getSecret(String key) async {
    // Check cache
    final cached = _cache.get(key);
    if (cached != null) return cached;

    // Get from mock storage
    final secret = _mockStorage[key];
    if (secret == null) {
      throw SecretNotFoundException(
        key: key,
        message: 'Secret not found in AWS Secrets Manager',
      );
    }

    // Cache it
    _cache.set(key, secret.value);

    return secret.value;
  }

  @override
  Future<String> getSecretVersion(String key, String version) async {
    final secret = _mockStorage[key];
    if (secret == null) {
      throw SecretNotFoundException(
        key: key,
        message: 'Secret not found',
      );
    }

    final versionData = secret.versions[version];
    if (versionData == null) {
      throw SecretOperationException(
        operation: 'getSecretVersion',
        message: 'Version not found',
      );
    }

    return versionData;
  }

  @override
  Future<void> setSecret(
    String key,
    String value, {
    Map<String, String>? metadata,
  }) async {
    final existing = _mockStorage[key];
    final now = DateTime.now();

    if (existing == null) {
      _mockStorage[key] = _AwsSecret(
        name: key,
        value: value,
        createdAt: now,
        updatedAt: now,
        version: 1,
        versions: {'1': value},
        tags: metadata ?? {},
      );
    } else {
      final newVersion = existing.version + 1;
      _mockStorage[key] = _AwsSecret(
        name: key,
        value: value,
        createdAt: existing.createdAt,
        updatedAt: now,
        version: newVersion,
        versions: {
          ...existing.versions,
          newVersion.toString(): value,
        },
        tags: {...existing.tags, ...?metadata},
      );
    }

    // Invalidate cache
    _cache.invalidate(key);
  }

  @override
  Future<void> rotateSecret(String key) async {
    final secret = _mockStorage[key];
    if (secret == null) {
      throw SecretNotFoundException(
        key: key,
        message: 'Secret not found',
      );
    }

    // Generate new secret
    final newValue = _generateNewSecret(key);

    await setSecret(
      key,
      newValue,
      metadata: {
        ...secret.tags,
        'rotated_at': DateTime.now().toIso8601String(),
      },
    );
  }

  @override
  Future<List<String>> listSecrets() async {
    return _mockStorage.keys.toList();
  }

  @override
  Future<void> deleteSecret(String key) async {
    _mockStorage.remove(key);
    _cache.invalidate(key);
  }

  @override
  Future<SecretMetadata> getMetadata(String key) async {
    final secret = _mockStorage[key];
    if (secret == null) {
      throw SecretNotFoundException(
        key: key,
        message: 'Secret not found',
      );
    }

    return SecretMetadata(
      key: key,
      createdAt: secret.createdAt,
      lastRotated: secret.updatedAt != secret.createdAt ? secret.updatedAt : null,
      version: secret.version,
      tags: secret.tags,
    );
  }

  @override
  Future<bool> exists(String key) async {
    return _mockStorage.containsKey(key);
  }

  String _generateNewSecret(String key) {
    // Simple generation for mock
    return 'aws_secret_${DateTime.now().millisecondsSinceEpoch}';
  }
}

class _AwsSecret {
  final String name;
  final String value;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int version;
  final Map<String, String> versions;
  final Map<String, String> tags;

  _AwsSecret({
    required this.name,
    required this.value,
    required this.createdAt,
    required this.updatedAt,
    required this.version,
    required this.versions,
    required this.tags,
  });
}
