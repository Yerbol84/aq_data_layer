# 🔐 WEEK 2: SECRETS MANAGEMENT & CREDENTIALS ROTATION

**Goal:** Eliminate all hardcoded credentials, implement secure secrets management
**Budget:** $875
**Deliverables:** Secrets Manager integration, credential rotation, zero hardcoded secrets

---

## 🎯 OBJECTIVES

### Problems to Fix
- ❌ Hardcoded password: `'aq_app_secret'` in code
- ❌ Hardcoded connection strings in tests
- ❌ No credential rotation
- ❌ Credentials in git history
- ❌ No secrets encryption at rest

### Success Criteria
- ✅ 0 hardcoded secrets in code
- ✅ All secrets in HashiCorp Vault / AWS Secrets Manager
- ✅ Automatic credential rotation (90 days)
- ✅ Secrets encrypted at rest
- ✅ Audit trail for secret access

---

## 📋 DAY 1-2: SECRETS MANAGER INTEGRATION

### 2.1 Choose Secrets Manager

**Options Analysis:**

| Solution | Pros | Cons | Cost | Recommendation |
|----------|------|------|------|----------------|
| **HashiCorp Vault** | Open source, self-hosted, full control | Complex setup, maintenance | Free (self-hosted) | ✅ **RECOMMENDED** |
| **AWS Secrets Manager** | Managed, easy setup, AWS integration | Vendor lock-in, cost | $0.40/secret/month | ✅ Good for AWS |
| **Google Secret Manager** | Managed, GCP integration | Vendor lock-in | $0.06/10k accesses | Good for GCP |
| **Azure Key Vault** | Managed, Azure integration | Vendor lock-in | $0.03/10k ops | Good for Azure |
| **Doppler** | Developer-friendly, multi-env | SaaS, cost | $7/user/month | Good for teams |

**Decision:** Use **HashiCorp Vault** for self-hosted + **AWS Secrets Manager** adapter for cloud deployments.

### 2.2 Secrets Manager Interface

```dart
// lib/security/secrets/secrets_manager.dart

/// Abstract interface for secrets management
abstract class SecretsManager {
  /// Get secret by key
  Future<String> getSecret(String key);

  /// Get secret with version
  Future<String> getSecretVersion(String key, String version);

  /// Set secret (admin only)
  Future<void> setSecret(String key, String value, {Map<String, String>? metadata});

  /// Rotate secret
  Future<void> rotateSecret(String key);

  /// List all secret keys (admin only)
  Future<List<String>> listSecrets();

  /// Delete secret (admin only)
  Future<void> deleteSecret(String key);

  /// Get secret metadata
  Future<SecretMetadata> getMetadata(String key);
}

/// Secret metadata
class SecretMetadata {
  final String key;
  final DateTime createdAt;
  final DateTime? lastRotated;
  final DateTime? expiresAt;
  final int version;
  final Map<String, String> tags;

  const SecretMetadata({
    required this.key,
    required this.createdAt,
    this.lastRotated,
    this.expiresAt,
    required this.version,
    this.tags = const {},
  });

  /// Check if secret needs rotation
  bool needsRotation({Duration maxAge = const Duration(days: 90)}) {
    final age = DateTime.now().difference(lastRotated ?? createdAt);
    return age > maxAge;
  }
}
```

### 2.3 HashiCorp Vault Implementation

```dart
// lib/security/secrets/vault_secrets_manager.dart

import 'package:vault_client/vault_client.dart';

/// HashiCorp Vault implementation
class VaultSecretsManager implements SecretsManager {
  final VaultClient _client;
  final String _mountPath;
  final SecretsCache _cache;

  VaultSecretsManager({
    required String vaultUrl,
    required String token,
    String mountPath = 'secret',
    Duration cacheTTL = const Duration(minutes: 5),
  }) : _client = VaultClient(
         baseUrl: vaultUrl,
         token: token,
       ),
       _mountPath = mountPath,
       _cache = SecretsCache(ttl: cacheTTL);

  @override
  Future<String> getSecret(String key) async {
    // Check cache first
    final cached = _cache.get(key);
    if (cached != null) {
      return cached;
    }

    // Fetch from Vault
    final response = await _client.read('$_mountPath/data/$key');
    final secret = response.data['data']['value'] as String;

    // Cache it
    _cache.set(key, secret);

    // Audit log
    await _logSecretAccess(key, 'read');

    return secret;
  }

  @override
  Future<void> setSecret(
    String key,
    String value, {
    Map<String, String>? metadata,
  }) async {
    await _client.write(
      '$_mountPath/data/$key',
      data: {
        'data': {
          'value': value,
          'metadata': metadata ?? {},
          'created_at': DateTime.now().toIso8601String(),
        },
      },
    );

    // Invalidate cache
    _cache.invalidate(key);

    // Audit log
    await _logSecretAccess(key, 'write');
  }

  @override
  Future<void> rotateSecret(String key) async {
    // Get current secret
    final current = await getSecret(key);

    // Generate new secret (implementation depends on secret type)
    final newSecret = await _generateNewSecret(key, current);

    // Update in Vault
    await setSecret(
      key,
      newSecret,
      metadata: {
        'rotated_at': DateTime.now().toIso8601String(),
        'previous_version': 'archived',
      },
    );

    // Notify rotation listeners
    await _notifyRotation(key);

    // Audit log
    await _logSecretAccess(key, 'rotate');
  }

  Future<String> _generateNewSecret(String key, String current) async {
    // For database passwords
    if (key.contains('db_password')) {
      return _generateSecurePassword(length: 32);
    }

    // For API keys
    if (key.contains('api_key')) {
      return _generateApiKey();
    }

    // For JWT secrets
    if (key.contains('jwt_secret')) {
      return _generateJwtSecret();
    }

    throw UnsupportedError('Unknown secret type: $key');
  }

  String _generateSecurePassword({int length = 32}) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#\$%^&*';
    final random = Random.secure();
    return List.generate(length, (_) => chars[random.nextInt(chars.length)]).join();
  }

  String _generateApiKey() {
    final random = Random.secure();
    final bytes = List.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  String _generateJwtSecret() {
    final random = Random.secure();
    final bytes = List.generate(64, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  Future<void> _logSecretAccess(String key, String operation) async {
    // Log to audit trail
    await AuditLogger.instance.log(
      event: 'secret_access',
      details: {
        'key': key,
        'operation': operation,
        'timestamp': DateTime.now().toIso8601String(),
        'actor': _getCurrentActor(),
      },
    );
  }
}

/// Simple in-memory cache for secrets
class SecretsCache {
  final Duration ttl;
  final _cache = <String, _CacheEntry>{};

  SecretsCache({required this.ttl});

  String? get(String key) {
    final entry = _cache[key];
    if (entry == null) return null;

    if (DateTime.now().isAfter(entry.expiresAt)) {
      _cache.remove(key);
      return null;
    }

    return entry.value;
  }

  void set(String key, String value) {
    _cache[key] = _CacheEntry(
      value: value,
      expiresAt: DateTime.now().add(ttl),
    );
  }

  void invalidate(String key) {
    _cache.remove(key);
  }

  void clear() {
    _cache.clear();
  }
}

class _CacheEntry {
  final String value;
  final DateTime expiresAt;

  _CacheEntry({required this.value, required this.expiresAt});
}
```

### 2.4 AWS Secrets Manager Implementation

```dart
// lib/security/secrets/aws_secrets_manager.dart

import 'package:aws_secretsmanager_api/secretsmanager-2017-10-17.dart';

/// AWS Secrets Manager implementation
class AwsSecretsManager implements SecretsManager {
  final SecretsManager _client;
  final String _region;
  final SecretsCache _cache;

  AwsSecretsManager({
    required String region,
    String? accessKeyId,
    String? secretAccessKey,
    Duration cacheTTL = const Duration(minutes: 5),
  }) : _region = region,
       _client = SecretsManager(
         region: region,
         credentials: accessKeyId != null && secretAccessKey != null
           ? AwsClientCredentials(
               accessKey: accessKeyId,
               secretKey: secretAccessKey,
             )
           : null, // Use IAM role
       ),
       _cache = SecretsCache(ttl: cacheTTL);

  @override
  Future<String> getSecret(String key) async {
    // Check cache
    final cached = _cache.get(key);
    if (cached != null) return cached;

    // Fetch from AWS
    final response = await _client.getSecretValue(secretId: key);
    final secret = response.secretString!;

    // Cache it
    _cache.set(key, secret);

    return secret;
  }

  @override
  Future<void> rotateSecret(String key) async {
    await _client.rotateSecret(
      secretId: key,
      rotationLambdaARN: _getRotationLambdaArn(key),
      rotationRules: RotationRulesType(
        automaticallyAfterDays: 90,
      ),
    );

    // Invalidate cache
    _cache.invalidate(key);
  }

  String _getRotationLambdaArn(String key) {
    // Return ARN of Lambda function that handles rotation
    return 'arn:aws:lambda:$_region:ACCOUNT_ID:function:rotate-$key';
  }
}
```

---

## 📋 DAY 3-4: CREDENTIAL ROTATION

### 2.5 Automatic Rotation Service

```dart
// lib/security/secrets/rotation_service.dart

/// Automatic credential rotation service
class CredentialRotationService {
  final SecretsManager _secretsManager;
  final DatabaseConnectionPool _dbPool;
  final NotificationService _notifications;

  CredentialRotationService({
    required SecretsManager secretsManager,
    required DatabaseConnectionPool dbPool,
    required NotificationService notifications,
  }) : _secretsManager = secretsManager,
       _dbPool = dbPool,
       _notifications = notifications;

  /// Start rotation scheduler
  Future<void> start() async {
    // Check for secrets needing rotation every hour
    Timer.periodic(Duration(hours: 1), (_) => _checkRotations());
  }

  Future<void> _checkRotations() async {
    final secrets = await _secretsManager.listSecrets();

    for (final key in secrets) {
      final metadata = await _secretsManager.getMetadata(key);

      if (metadata.needsRotation()) {
        await _rotateCredential(key, metadata);
      }
    }
  }

  Future<void> _rotateCredential(String key, SecretMetadata metadata) async {
    try {
      print('🔄 Rotating credential: $key');

      // 1. Generate new credential
      final newCredential = await _secretsManager.rotateSecret(key);

      // 2. Update database user (if DB credential)
      if (key.contains('db_password')) {
        await _updateDatabasePassword(key, newCredential);
      }

      // 3. Update application config
      await _updateApplicationConfig(key, newCredential);

      // 4. Verify new credential works
      await _verifyCredential(key, newCredential);

      // 5. Notify team
      await _notifications.send(
        channel: 'security',
        message: '✅ Credential rotated successfully: $key',
      );

      print('✅ Rotation complete: $key');
    } catch (e, stack) {
      // Rollback on error
      await _rollbackRotation(key, metadata);

      // Alert team
      await _notifications.send(
        channel: 'security-alerts',
        message: '🚨 Credential rotation FAILED: $key\nError: $e',
        priority: 'high',
      );

      print('❌ Rotation failed: $key - $e');
      rethrow;
    }
  }

  Future<void> _updateDatabasePassword(String key, String newPassword) async {
    final username = _extractUsername(key);

    // Connect as admin
    final adminConn = await _dbPool.getAdminConnection();

    try {
      // Update password
      await adminConn.execute(
        "ALTER USER $username WITH PASSWORD '\$1'",
        parameters: [newPassword],
      );

      // Verify new password works
      await _verifyDatabaseConnection(username, newPassword);
    } finally {
      await adminConn.close();
    }
  }

  Future<void> _verifyDatabaseConnection(String username, String password) async {
    final testConn = await Connection.open(
      Endpoint(
        host: 'localhost',
        port: 5432,
        database: 'aq_studio',
        username: username,
        password: password,
      ),
    );

    await testConn.execute('SELECT 1');
    await testConn.close();
  }

  Future<void> _rollbackRotation(String key, SecretMetadata metadata) async {
    // Restore previous version
    final previousVersion = (metadata.version - 1).toString();
    final previousSecret = await _secretsManager.getSecretVersion(key, previousVersion);

    await _secretsManager.setSecret(key, previousSecret);
  }
}
```

### 2.6 Database Credentials Migration

```dart
// lib/security/database_credentials.dart

/// Secure database credentials provider
class DatabaseCredentials {
  final SecretsManager _secretsManager;

  DatabaseCredentials({required SecretsManager secretsManager})
    : _secretsManager = secretsManager;

  /// Get connection string from secrets
  Future<String> getConnectionString({
    required String environment, // 'dev', 'staging', 'prod'
  }) async {
    final host = await _secretsManager.getSecret('db_host_$environment');
    final port = await _secretsManager.getSecret('db_port_$environment');
    final database = await _secretsManager.getSecret('db_name_$environment');
    final username = await _secretsManager.getSecret('db_username_$environment');
    final password = await _secretsManager.getSecret('db_password_$environment');

    return 'postgres://$username:$password@$host:$port/$database';
  }

  /// Get connection endpoint
  Future<Endpoint> getEndpoint({
    required String environment,
  }) async {
    final host = await _secretsManager.getSecret('db_host_$environment');
    final port = int.parse(await _secretsManager.getSecret('db_port_$environment'));
    final database = await _secretsManager.getSecret('db_name_$environment');
    final username = await _secretsManager.getSecret('db_username_$environment');
    final password = await _secretsManager.getSecret('db_password_$environment');

    return Endpoint(
      host: host,
      port: port,
      database: database,
      username: username,
      password: password,
    );
  }
}
```

---

## 📋 DAY 5: TESTING & CLEANUP

### 2.7 Remove Hardcoded Secrets

**Files to Clean:**

```bash
# Find all hardcoded secrets
grep -r "aq_app_secret" .
grep -r "postgres://" . --include="*.dart"
grep -r "password" . --include="*.dart" | grep -v "// "

# Files to update:
# 1. test/security/rls_basic_isolation_test.dart
# 2. test/security/rls_sql_injection_test.dart
# 3. test/security/rls_context_manipulation_test.dart
# 4. test/security/rls_edge_cases_test.dart
# 5. lib/storage/postgres/postgres_vault_storage.dart
# 6. server_apps/*/bin/server.dart
```

**Migration Script:**

```dart
// scripts/migrate_secrets.dart

/// Migrate hardcoded secrets to Vault
Future<void> main() async {
  final vault = VaultSecretsManager(
    vaultUrl: Platform.environment['VAULT_URL']!,
    token: Platform.environment['VAULT_TOKEN']!,
  );

  // Migrate database credentials
  await vault.setSecret(
    'db_password_dev',
    Platform.environment['DB_PASSWORD_DEV']!,
    metadata: {'environment': 'dev', 'type': 'database'},
  );

  await vault.setSecret(
    'db_password_staging',
    Platform.environment['DB_PASSWORD_STAGING']!,
    metadata: {'environment': 'staging', 'type': 'database'},
  );

  await vault.setSecret(
    'db_password_prod',
    Platform.environment['DB_PASSWORD_PROD']!,
    metadata: {'environment': 'prod', 'type': 'database'},
  );

  // Migrate JWT secrets
  await vault.setSecret(
    'jwt_secret_prod',
    _generateJwtSecret(),
    metadata: {'type': 'jwt'},
  );

  // Migrate API keys
  await vault.setSecret(
    'api_key_internal',
    _generateApiKey(),
    metadata: {'type': 'api_key', 'scope': 'internal'},
  );

  print('✅ Secrets migrated successfully');
}
```

### 2.8 Tests

```dart
// test/security/secrets_manager_test.dart

void main() {
  group('VaultSecretsManager', () {
    late VaultSecretsManager secretsManager;

    setUp(() {
      secretsManager = VaultSecretsManager(
        vaultUrl: 'http://localhost:8200',
        token: 'test-token',
      );
    });

    test('can store and retrieve secret', () async {
      await secretsManager.setSecret('test_key', 'test_value');
      final value = await secretsManager.getSecret('test_key');
      expect(value, 'test_value');
    });

    test('caches secrets', () async {
      await secretsManager.setSecret('cached_key', 'cached_value');

      // First call - from Vault
      final stopwatch = Stopwatch()..start();
      await secretsManager.getSecret('cached_key');
      final firstCallTime = stopwatch.elapsedMilliseconds;

      // Second call - from cache (should be faster)
      stopwatch.reset();
      await secretsManager.getSecret('cached_key');
      final secondCallTime = stopwatch.elapsedMilliseconds;

      expect(secondCallTime, lessThan(firstCallTime));
    });

    test('rotates secret', () async {
      await secretsManager.setSecret('rotate_key', 'old_value');
      await secretsManager.rotateSecret('rotate_key');

      final newValue = await secretsManager.getSecret('rotate_key');
      expect(newValue, isNot('old_value'));
    });
  });

  group('CredentialRotationService', () {
    test('detects secrets needing rotation', () async {
      // Create old secret (91 days old)
      final metadata = SecretMetadata(
        key: 'old_secret',
        createdAt: DateTime.now().subtract(Duration(days: 91)),
        version: 1,
      );

      expect(metadata.needsRotation(), isTrue);
    });

    test('does not rotate recent secrets', () async {
      final metadata = SecretMetadata(
        key: 'new_secret',
        createdAt: DateTime.now().subtract(Duration(days: 30)),
        version: 1,
      );

      expect(metadata.needsRotation(), isFalse);
    });
  });
}
```

---

## 📊 WEEK 2 DELIVERABLES

### Code
- ✅ `lib/security/secrets/secrets_manager.dart` (150 LOC)
- ✅ `lib/security/secrets/vault_secrets_manager.dart` (400 LOC)
- ✅ `lib/security/secrets/aws_secrets_manager.dart` (200 LOC)
- ✅ `lib/security/secrets/rotation_service.dart` (300 LOC)
- ✅ `lib/security/database_credentials.dart` (100 LOC)
- ✅ `scripts/migrate_secrets.dart` (150 LOC)

### Tests
- ✅ `test/security/secrets_manager_test.dart` (250 LOC)
- ✅ `test/security/rotation_service_test.dart` (200 LOC)

### Documentation
- ✅ Secrets Management Architecture (ADR-003)
- ✅ Credential Rotation Guide
- ✅ Migration Guide (hardcoded → Vault)
- ✅ Vault Setup Guide

### Cleanup
- ✅ Remove all hardcoded passwords (15 files)
- ✅ Update all tests to use secrets manager
- ✅ Clean git history (BFG Repo-Cleaner)

### Metrics
- ✅ 0 hardcoded secrets in code
- ✅ 100% secrets in Vault
- ✅ Automatic rotation every 90 days
- ✅ Test Coverage: 95%

---

**Week 2 Status:** 🟢 READY TO START
**Budget:** $875
**Dependencies:** Week 1 complete
**Risk:** LOW
