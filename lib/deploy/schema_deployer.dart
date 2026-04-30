import 'package:aq_schema/aq_schema.dart';

import 'domain_registration.dart';

/// A record of an applied migration stored in the `_vault_migrations` table.
final class AppliedMigration {
  final String collection;
  final String fromVersion;
  final String toVersion;
  final String description;
  final DateTime appliedAt;

  const AppliedMigration({
    required this.collection,
    required this.fromVersion,
    required this.toVersion,
    required this.description,
    required this.appliedAt,
  });

  Map<String, dynamic> toMap() => {
        'collection': collection,
        'fromVersion': fromVersion,
        'toVersion': toVersion,
        'description': description,
        'appliedAt': appliedAt.toIso8601String(),
      };

  factory AppliedMigration.fromMap(Map<String, dynamic> m) => AppliedMigration(
        collection: m['collection'] as String,
        fromVersion: m['fromVersion'] as String,
        toVersion: m['toVersion'] as String,
        description: m['description'] as String,
        appliedAt: DateTime.parse(m['appliedAt'] as String),
      );
}

/// Describes a schema migration for a single collection.
///
/// Because dart_vault stores data as JSON objects, most domain model changes
/// (adding nullable fields, renaming) are handled automatically.
/// Migrations are only needed for:
/// - **Data transforms**: renaming a field, changing value format
/// - **Index changes**: adding or dropping indexed fields
///
/// ## JSON-based migration (recommended)
///
/// Define migrations as Dart const objects next to your domain model:
///
/// ```dart
/// const blueprintV1toV2 = DomainMigration(
///   collection: 'blueprints',
///   fromVersion: '1.0.0',
///   toVersion: '2.0.0',
///   description: 'Rename "dataJson" field to "graphData"',
///   transform: _renameField,
///   indexesToCreate: [VaultIndex(name: 'idx_type', field: 'type')],
/// );
///
/// Map<String,dynamic>? _renameField(Map<String,dynamic> data) {
///   if (!data.containsKey('dataJson')) return null; // already migrated
///   return {...data, 'graphData': data.remove('dataJson')};
/// }
/// ```
final class DomainMigration {
  final String collection;
  final String fromVersion;
  final String toVersion;
  final String description;

  /// Optional per-record transform. Return null to skip the record (no change).
  final Map<String, dynamic>? Function(Map<String, dynamic>)? transform;

  final List<VaultIndex> indexesToCreate;
  final List<String> indexesToDrop;

  const DomainMigration({
    required this.collection,
    required this.fromVersion,
    required this.toVersion,
    required this.description,
    this.transform,
    this.indexesToCreate = const [],
    this.indexesToDrop = const [],
  });
}

/// Interface for database schema lifecycle management.
///
/// Implementations auto-create and evolve the storage schema based on
/// [DomainRegistration]s.  The [SchemaDeployer] is the bridge between
/// dart_vault's abstract domain model and the concrete storage backend.
///
/// ## Supported backends
///
/// - `PostgresSchemaDeployer` (aq_studio_data_service package)
/// - `InMemorySchemaDeployer` (built-in, for tests — no-op)
///
/// ## Table structure contract (for SQL backends)
///
/// Every collection table MUST expose at minimum:
/// ```sql
/// id        TEXT  PRIMARY KEY
/// data      JSONB NOT NULL     -- entire domain object as JSON
/// ```
/// Additional system columns (ts, tenant_id, etc.) are backend-specific.
///
/// For `versioned` mode, two system tables are added:
///   `{collection}__meta` and `{collection}__nodes`
///
/// For `logged` mode, one log table is added:
///   `{collection}__log`
abstract interface class SchemaDeployer {
  /// Ensure all tables, indexes, and system tables exist for [domains].
  /// Idempotent — safe to call on every startup.
  Future<void> ensureSchema(List<DomainRegistration> domains);

  /// Apply a migration: run [migration.transform] on all records, then
  /// create/drop indexes as specified.  Records the migration in
  /// `_vault_migrations`.
  Future<void> applyMigration(DomainMigration migration);

  /// True if [collection] has NOT yet been migrated to [toVersion].
  Future<bool> needsMigration(String collection, String toVersion);

  /// All migrations applied to this storage backend, chronological order.
  Future<List<AppliedMigration>> history();
}

/// No-op [SchemaDeployer] for in-memory storage and tests.
/// Tables are created on demand by InMemoryVaultStorage.ensureCollection().
final class InMemorySchemaDeployer implements SchemaDeployer {
  final _applied = <AppliedMigration>[];
  final _versions = <String, String>{}; // collection → version

  @override
  Future<void> ensureSchema(List<DomainRegistration> domains) async {
    for (final d in domains) {
      _versions.putIfAbsent(d.collection, () => d.schemaVersion);
    }
  }

  @override
  Future<void> applyMigration(DomainMigration m) async {
    _versions[m.collection] = m.toVersion;
    _applied.add(AppliedMigration(
      collection: m.collection,
      fromVersion: m.fromVersion,
      toVersion: m.toVersion,
      description: m.description,
      appliedAt: DateTime.now(),
    ));
  }

  @override
  Future<bool> needsMigration(String collection, String toVersion) async =>
      _versions[collection] != toVersion;

  @override
  Future<List<AppliedMigration>> history() async => List.unmodifiable(_applied);
}
