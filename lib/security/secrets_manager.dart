/// Metadata about a secret
class SecretMetadata {
  /// Secret key/name
  final String key;

  /// When the secret was created
  final DateTime createdAt;

  /// When the secret was last rotated
  final DateTime? lastRotated;

  /// When the secret expires (if applicable)
  final DateTime? expiresAt;

  /// Current version number
  final int version;

  /// Custom tags/labels
  final Map<String, String> tags;

  const SecretMetadata({
    required this.key,
    required this.createdAt,
    this.lastRotated,
    this.expiresAt,
    required this.version,
    this.tags = const {},
  });

  /// Check if secret needs rotation based on age
  bool needsRotation({Duration maxAge = const Duration(days: 90)}) {
    final age = DateTime.now().difference(lastRotated ?? createdAt);
    return age > maxAge;
  }

  /// Check if secret is expired
  bool isExpired() {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }

  /// Days until rotation recommended
  int daysUntilRotation({Duration maxAge = const Duration(days: 90)}) {
    final age = DateTime.now().difference(lastRotated ?? createdAt);
    final remaining = maxAge - age;
    return remaining.inDays;
  }
}

/// Abstract interface for secrets management
///
/// Provides secure storage and retrieval of secrets (passwords, API keys, etc.)
/// Implementations can use HashiCorp Vault, AWS Secrets Manager, or other backends.
abstract class SecretsManager {
  /// Get secret value by key
  Future<String> getSecret(String key);

  /// Get specific version of a secret
  Future<String> getSecretVersion(String key, String version);

  /// Set/update secret value (admin only)
  Future<void> setSecret(
    String key,
    String value, {
    Map<String, String>? metadata,
  });

  /// Rotate secret (generate new value)
  Future<void> rotateSecret(String key);

  /// List all secret keys (admin only)
  Future<List<String>> listSecrets();

  /// Delete secret (admin only)
  Future<void> deleteSecret(String key);

  /// Get secret metadata (version, created date, etc.)
  Future<SecretMetadata> getMetadata(String key);

  /// Check if secret exists
  Future<bool> exists(String key);
}

/// Exception thrown when secret is not found
class SecretNotFoundException implements Exception {
  final String key;
  final String message;

  const SecretNotFoundException({
    required this.key,
    required this.message,
  });

  @override
  String toString() => 'SecretNotFoundException: $message (key: $key)';
}

/// Exception thrown when secret operation fails
class SecretOperationException implements Exception {
  final String operation;
  final String message;
  final dynamic cause;

  const SecretOperationException({
    required this.operation,
    required this.message,
    this.cause,
  });

  @override
  String toString() => 'SecretOperationException: $message '
      '(operation: $operation, cause: $cause)';
}
