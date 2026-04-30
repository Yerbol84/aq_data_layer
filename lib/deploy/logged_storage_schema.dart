import 'package:aq_schema/aq_schema.dart';
import 'package:postgres/postgres.dart';

import 'domain_registration.dart' show StorageMode;
import 'i_storage_schema.dart';

/// Logged storage schema — хранение с полным аудит-логом.
///
/// ## Таблицы
/// - `{collection}` — основная таблица
/// - `{collection}_log` — лог каждой операции (LogEntry как JSONB)
/// - `{collection}_deleted` — удалённые записи
///
/// ## Индексы
/// - tenant_id на основной таблице
/// - entityId внутри JSONB на log таблице
/// - пользовательские индексы на основной таблице
///
/// ## RLS
/// - tenant isolation на всех трёх таблицах
final class LoggedStorageSchema implements IStorageSchema {
  @override
  final String collection;

  const LoggedStorageSchema(this.collection);

  @override
  StorageMode get mode => StorageMode.logged;

  @override
  StorageTableNames get tableNames => StorageTableNames(
        main: collection,
        deleted: '${collection}_deleted',
        log: '${collection}_log',
      );

  @override
  Future<void> deploy(Session connection, List<VaultIndex> indexes) async {
    final keys = Storable.keys.dbKeys;

    // Main table
    await connection.execute('''
      CREATE TABLE IF NOT EXISTS $collection (
        ${keys.id} TEXT NOT NULL,
        ${keys.tenantId} TEXT NOT NULL,
        ${keys.data} JSONB NOT NULL,
        ${keys.createdAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        ${keys.updatedAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (${keys.id}, ${keys.tenantId})
      )
    ''');

    // Log table — LogEntry хранится как JSONB документ
    await connection.execute('''
      CREATE TABLE IF NOT EXISTS ${tableNames.log!} (
        ${keys.id} TEXT NOT NULL,
        ${keys.tenantId} TEXT NOT NULL,
        ${keys.data} JSONB NOT NULL,
        ${keys.createdAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        ${keys.updatedAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (${keys.id}, ${keys.tenantId})
      )
    ''');

    // Tenant index on main
    await connection.execute('''
      CREATE INDEX IF NOT EXISTS idx_${collection}_tenant
      ON $collection(${keys.tenantId})
    ''');

    // entityId index on log (для быстрого getHistory по сущности)
    final entityIdKey = LogEntry.keys.jsonKeys.entityId;
    await connection.execute('''
      CREATE INDEX IF NOT EXISTS idx_${collection}_log_entity
      ON ${tableNames.log!}((${keys.data}->>'$entityIdKey'))
    ''');

    // User indexes on main table
    await _createIndexes(connection, collection, indexes);

    // RLS
    await _enableRls(connection, collection);
    await _enableRls(connection, tableNames.log!);

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
