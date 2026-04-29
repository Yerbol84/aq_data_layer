import 'secrets_manager.dart';
import 'secrets_cache.dart';
import 'vault_http_client.dart';

/// HashiCorp Vault implementation of SecretsManager
///
/// Integrates with HashiCorp Vault KV v2 secrets engine.
/// Supports versioning, metadata, and automatic caching.
class VaultSecretsManager implements SecretsManager {
  final VaultHttpClient _client;
  final String _mountPath;
  final SecretsCache _cache;

  VaultSecretsManager({
    required String vaultUrl,
    required String token,
    String mountPath = 'secret',
    Duration cacheTTL = const Duration(minutes: 5),
    Duration timeout = const Duration(seconds: 30),
  })  : _client = VaultHttpClient(
          baseUrl: vaultUrl,
          token: token,
          timeout: timeout,
        ),
        _mountPath = mountPath,
        _cache = SecretsCache(ttl: cacheTTL);

  @override
  Future<String> getSecret(String key) async {
    // Check cache first
    final cached = _cache.get(key);
    if (cached != null) return cached;

    // Fetch from Vault
    try {
      final response = await _client.get('/v1/$_mountPath/data/$key');
      final data = response['data'] as Map<String, dynamic>?;
      if (data == null) {
        throw SecretNotFoundException(
          key: key,
          message: 'Secret data not found in response',
        );
      }

      final secretData = data['data'] as Map<String, dynamic>?;
      if (secretData == null) {
        throw SecretNotFoundException(
          key: key,
          message: 'Secret value not found',
        );
      }

      final value = secretData['value'] as String?;
      if (value == null) {
        throw SecretNotFoundException(
          key: key,
          message: 'Secret value is null',
        );
      }

      // Cache it
      _cache.set(key, value);

      return value;
    } on VaultHttpException catch (e) {
      if (e.statusCode == 404) {
        throw SecretNotFoundException(
          key: key,
          message: 'Secret not found in Vault',
        );
      }
      throw SecretOperationException(
        operation: 'getSecret',
        message: 'Failed to get secret from Vault',
        cause: e,
      );
    }
  }

  @override
  Future<String> getSecretVersion(String key, String version) async {
    try {
      final response = await _client.get(
        '/v1/$_mountPath/data/$key?version=$version',
      );

      final data = response['data'] as Map<String, dynamic>?;
      final secretData = data?['data'] as Map<String, dynamic>?;
      final value = secretData?['value'] as String?;

      if (value == null) {
        throw SecretNotFoundException(
          key: key,
          message: 'Secret version not found',
        );
      }

      return value;
    } on VaultHttpException catch (e) {
      throw SecretOperationException(
        operation: 'getSecretVersion',
        message: 'Failed to get secret version',
        cause: e,
      );
    }
  }

  @override
  Future<void> setSecret(
    String key,
    String value, {
    Map<String, String>? metadata,
  }) async {
    try {
      await _client.post(
        '/v1/$_mountPath/data/$key',
        {
          'data': {
            'value': value,
            'metadata': metadata ?? {},
            'created_at': DateTime.now().toIso8601String(),
          },
        },
      );

      // Invalidate cache
      _cache.invalidate(key);
    } on VaultHttpException catch (e) {
      throw SecretOperationException(
        operation: 'setSecret',
        message: 'Failed to set secret in Vault',
        cause: e,
      );
    }
  }

  @override
  Future<void> rotateSecret(String key) async {
    try {
      // Get current secret
      final current = await getSecret(key);

      // Generate new secret (simple implementation)
      final newSecret = _generateNewSecret(key, current);

      // Update in Vault
      await setSecret(
        key,
        newSecret,
        metadata: {
          'rotated_at': DateTime.now().toIso8601String(),
          'previous_value_hash': current.hashCode.toString(),
        },
      );
    } catch (e) {
      throw SecretOperationException(
        operation: 'rotateSecret',
        message: 'Failed to rotate secret',
        cause: e,
      );
    }
  }

  @override
  Future<List<String>> listSecrets() async {
    try {
      final response = await _client.get('/v1/$_mountPath/metadata?list=true');
      final data = response['data'] as Map<String, dynamic>?;
      final keys = data?['keys'] as List<dynamic>?;

      if (keys == null) return [];

      return keys.cast<String>();
    } on VaultHttpException catch (e) {
      if (e.statusCode == 404) return [];
      throw SecretOperationException(
        operation: 'listSecrets',
        message: 'Failed to list secrets',
        cause: e,
      );
    }
  }

  @override
  Future<void> deleteSecret(String key) async {
    try {
      await _client.delete('/v1/$_mountPath/metadata/$key');
      _cache.invalidate(key);
    } on VaultHttpException catch (e) {
      throw SecretOperationException(
        operation: 'deleteSecret',
        message: 'Failed to delete secret',
        cause: e,
      );
    }
  }

  @override
  Future<SecretMetadata> getMetadata(String key) async {
    try {
      final response = await _client.get('/v1/$_mountPath/metadata/$key');
      final data = response['data'] as Map<String, dynamic>?;

      if (data == null) {
        throw SecretNotFoundException(
          key: key,
          message: 'Metadata not found',
        );
      }

      final createdTime = data['created_time'] as String?;
      final currentVersion = data['current_version'] as int?;
      final customMetadata = data['custom_metadata'] as Map<String, dynamic>?;

      return SecretMetadata(
        key: key,
        createdAt: createdTime != null
            ? DateTime.parse(createdTime)
            : DateTime.now(),
        version: currentVersion ?? 1,
        tags: customMetadata?.cast<String, String>() ?? {},
      );
    } on VaultHttpException catch (e) {
      throw SecretOperationException(
        operation: 'getMetadata',
        message: 'Failed to get metadata',
        cause: e,
      );
    }
  }

  @override
  Future<bool> exists(String key) async {
    try {
      await getMetadata(key);
      return true;
    } on SecretNotFoundException {
      return false;
    } on SecretOperationException {
      return false;
    }
  }

  /// Generate new secret value (placeholder implementation)
  String _generateNewSecret(String key, String current) {
    // In real implementation, this would use proper secret generation
    // For now, just append timestamp
    return '${current}_rotated_${DateTime.now().millisecondsSinceEpoch}';
  }
}
