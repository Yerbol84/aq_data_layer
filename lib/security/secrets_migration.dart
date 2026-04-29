/// Migration utilities for moving hardcoded secrets to SecretsManager
///
/// This module provides tools to migrate existing hardcoded credentials
/// to a secure secrets management system.
library;

import 'secrets_manager.dart';

/// Migration script for moving hardcoded secrets to SecretsManager
///
/// ## Usage
///
/// ```dart
/// final manager = VaultSecretsManager(
///   vaultUrl: 'http://localhost:8200',
///   token: 'root-token',
/// );
///
/// final migration = SecretsMigration(manager);
/// await migration.migratePostgresCredentials(
///   host: 'localhost',
///   database: 'aq_studio',
///   username: 'postgres',
///   password: 'current_password',
/// );
///
/// // Now use from secrets manager:
/// final password = await manager.getSecret('postgres/password');
/// ```
class SecretsMigration {
  final SecretsManager _manager;

  SecretsMigration(this._manager);

  /// Migrate PostgreSQL connection credentials
  Future<void> migratePostgresCredentials({
    required String host,
    required String database,
    required String username,
    required String password,
    int? port,
  }) async {
    print('🔄 Migrating PostgreSQL credentials...');

    await _manager.setSecret(
      'postgres/host',
      host,
      metadata: {'type': 'postgres', 'component': 'connection'},
    );

    await _manager.setSecret(
      'postgres/database',
      database,
      metadata: {'type': 'postgres', 'component': 'connection'},
    );

    await _manager.setSecret(
      'postgres/username',
      username,
      metadata: {'type': 'postgres', 'component': 'connection'},
    );

    await _manager.setSecret(
      'postgres/password',
      password,
      metadata: {'type': 'postgres', 'component': 'connection', 'sensitive': 'true'},
    );

    if (port != null) {
      await _manager.setSecret(
        'postgres/port',
        port.toString(),
        metadata: {'type': 'postgres', 'component': 'connection'},
      );
    }

    print('✅ PostgreSQL credentials migrated');
  }

  /// Migrate HTTP authentication tokens
  Future<void> migrateAuthToken({
    required String service,
    required String token,
  }) async {
    print('🔄 Migrating auth token for $service...');

    await _manager.setSecret(
      'auth/$service/token',
      token,
      metadata: {'type': 'auth', 'service': service, 'sensitive': 'true'},
    );

    print('✅ Auth token migrated for $service');
  }

  /// Migrate API keys
  Future<void> migrateApiKey({
    required String service,
    required String apiKey,
  }) async {
    print('🔄 Migrating API key for $service...');

    await _manager.setSecret(
      'api/$service/key',
      apiKey,
      metadata: {'type': 'api_key', 'service': service, 'sensitive': 'true'},
    );

    print('✅ API key migrated for $service');
  }

  /// Verify migration by checking all secrets exist
  Future<MigrationReport> verify() async {
    print('🔍 Verifying migration...');

    final secrets = await _manager.listSecrets();
    final report = MigrationReport();

    for (final key in secrets) {
      try {
        final metadata = await _manager.getMetadata(key);
        report.verified.add(key);
        print('  ✅ $key (v${metadata.version})');
      } catch (e) {
        report.failed[key] = e.toString();
        print('  ❌ $key: $e');
      }
    }

    print('✅ Verification complete: ${report.verified.length} verified, ${report.failed.length} failed');
    return report;
  }

  /// Generate migration report
  Future<String> generateReport() async {
    final secrets = await _manager.listSecrets();
    final buffer = StringBuffer();

    buffer.writeln('# Secrets Migration Report');
    buffer.writeln();
    buffer.writeln('**Date:** ${DateTime.now().toIso8601String()}');
    buffer.writeln('**Total Secrets:** ${secrets.length}');
    buffer.writeln();
    buffer.writeln('## Migrated Secrets');
    buffer.writeln();

    for (final key in secrets) {
      try {
        final metadata = await _manager.getMetadata(key);
        buffer.writeln('- **$key**');
        buffer.writeln('  - Version: ${metadata.version}');
        buffer.writeln('  - Created: ${metadata.createdAt}');
        if (metadata.tags.isNotEmpty) {
          buffer.writeln('  - Tags: ${metadata.tags}');
        }
        buffer.writeln();
      } catch (e) {
        buffer.writeln('- **$key** ❌ Error: $e');
        buffer.writeln();
      }
    }

    return buffer.toString();
  }
}

/// Report of migration verification results
class MigrationReport {
  final List<String> verified = [];
  final Map<String, String> failed = {};

  int get total => verified.length + failed.length;
  bool get hasFailures => failed.isNotEmpty;
  bool get success => !hasFailures;

  @override
  String toString() {
    return 'MigrationReport(verified: ${verified.length}, failed: ${failed.length})';
  }
}
