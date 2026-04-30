import 'package:aq_schema/aq_schema.dart';
import 'package:postgres/postgres.dart';

import 'domain_registration.dart' show StorageMode;
import 'i_storage_schema.dart';

/// Versioned storage schema — хранение с версионированием.
///
/// ## Таблицы
/// - `{collection}_versions` — все узлы версий
/// - `{collection}_current` — указатель на текущую версию
/// - `{collection}_deleted` — удалённые сущности
///
/// ## Константы полей
/// Единственный источник правды для имён полей версионированного хранения.
/// Заменяет [VersionedStorageContract] (помечен @Deprecated).
final class VersionedStorageSchema implements IStorageSchema {
  @override
  final String collection;

  const VersionedStorageSchema(this.collection);

  @override
  StorageMode get mode => StorageMode.versioned;

  @override
  StorageTableNames get tableNames => StorageTableNames(
        main: collection,
        deleted: '${collection}_deleted',
        versions: '${collection}_versions',
        current: '${collection}_current',
      );

  // ── Константы полей таблицы versions ──────────────────────────────────────

  static const String kNodeId = 'node_id';
  static const String kEntityId = 'entity_id';
  static const String kParentNodeId = 'parent_node_id';
  static const String kTenantId = 'tenant_id';
  static const String kVersion = 'version';
  static const String kStatus = 'status';
  static const String kBranch = 'branch';
  static const String kData = 'data';
  static const String kCreatedAt = 'created_at';
  static const String kCreatedBy = 'created_by';
  static const String kSequenceNumber = 'sequence_number';
  static const String kIsCurrent = 'is_current';

  // ── Константы полей таблицы current ───────────────────────────────────────

  static const String kUpdatedAt = 'updated_at';

  // ── Константы полей метаданных (InMemory) ─────────────────────────────────

  static const String kOwnerId = 'owner_id';
  static const String kCurrentNodeId = 'current_node_id';
  static const String kGrants = 'grants';
  static const String kSequenceCounter = 'sequence_counter';

  @override
  Future<void> deploy(Session connection, List<VaultIndex> indexes) async {
    final versionsTable = tableNames.versions!;
    final currentTable = tableNames.current!;

    // Versions table
    await connection.execute('''
      CREATE TABLE IF NOT EXISTS $versionsTable (
        $kNodeId TEXT PRIMARY KEY,
        $kEntityId TEXT NOT NULL,
        $kParentNodeId TEXT,
        $kTenantId TEXT NOT NULL,
        $kVersion TEXT,
        $kStatus TEXT NOT NULL,
        $kBranch TEXT NOT NULL DEFAULT 'main',
        $kSequenceNumber INTEGER NOT NULL DEFAULT 1,
        $kCreatedBy TEXT NOT NULL DEFAULT '',
        $kCreatedAt TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        $kData JSONB NOT NULL
      )
    ''');

    // Current pointer table
    await connection.execute('''
      CREATE TABLE IF NOT EXISTS $currentTable (
        $kEntityId TEXT NOT NULL,
        $kTenantId TEXT NOT NULL,
        $kNodeId TEXT NOT NULL,
        $kUpdatedAt TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY ($kEntityId, $kTenantId)
      )
    ''');

    // Indexes on versions table
    await connection.execute('''
      CREATE INDEX IF NOT EXISTS idx_${collection}_versions_entity
      ON $versionsTable($kEntityId, $kTenantId)
    ''');

    await connection.execute('''
      CREATE INDEX IF NOT EXISTS idx_${collection}_versions_status
      ON $versionsTable($kStatus)
    ''');

    // User indexes on versions table
    await _createIndexes(connection, versionsTable, indexes);

    // RLS
    await _enableRls(connection, versionsTable);
    await _enableRls(connection, currentTable);

    // Deleted table
    await _createDeletedTable(connection);
  }

  @override
  Future<void> validate(Session connection) async {
    // TODO: implement validation
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<void> _createDeletedTable(Session connection) async {
    final keys = Storable.keys.dbKeys;
    final deletedTable = tableNames.deleted;

    await connection.execute('''
      CREATE TABLE IF NOT EXISTS $deletedTable (
        ${keys.id} TEXT NOT NULL,
        ${keys.tenantId} TEXT NOT NULL,
        ${keys.data} JSONB NOT NULL DEFAULT '{}',
        ${keys.createdAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        ${keys.updatedAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (${keys.id}, ${keys.tenantId})
      )
    ''');

    await connection.execute('''
      CREATE INDEX IF NOT EXISTS idx_${collection}_deleted_at
      ON $deletedTable ((${keys.data}->>'deleted_at'))
    ''');

    await connection.execute('''
      CREATE INDEX IF NOT EXISTS idx_${collection}_deleted_tenant
      ON $deletedTable(${keys.tenantId})
    ''');

    await _enableRls(connection, deletedTable);
  }

  Future<void> _createIndexes(
    Session connection,
    String tableName,
    List<VaultIndex> indexes,
  ) async {
    for (final index in indexes) {
      await connection.execute('''
        CREATE INDEX IF NOT EXISTS ${index.name}
        ON $tableName((data->>'${index.field}'))
      ''');
    }
  }

  Future<void> _enableRls(Session connection, String tableName) async {
    await connection.execute(
        'ALTER TABLE $tableName ENABLE ROW LEVEL SECURITY');
    await connection.execute(
        'ALTER TABLE $tableName FORCE ROW LEVEL SECURITY');

    await connection.execute('''
      DO \$\$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_policies
          WHERE tablename = '$tableName' AND policyname = '${tableName}_tenant_isolation'
        ) THEN
          CREATE POLICY ${tableName}_tenant_isolation
          ON $tableName
          USING (tenant_id = current_setting('app.current_tenant', true));
        END IF;
      END \$\$;
    ''');

    await connection.execute('''
      DO \$\$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_policies
          WHERE tablename = '$tableName' AND policyname = '${tableName}_tenant_insert'
        ) THEN
          CREATE POLICY ${tableName}_tenant_insert
          ON $tableName
          FOR INSERT
          WITH CHECK (tenant_id = current_setting('app.current_tenant', true));
        END IF;
      END \$\$;
    ''');
  }
}
