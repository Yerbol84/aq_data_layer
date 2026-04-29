import 'dart:convert';
import 'package:postgres/postgres.dart';
import 'package:aq_schema/aq_schema.dart';
import 'package:meta/meta.dart';
import '../../deploy/schema_deployer.dart';
import '../../deploy/domain_registration.dart';
import '../versioned_storage_contract.dart';

/// PostgreSQL implementation of [SchemaDeployer].
///
/// Auto-creates tables from JSON Schema in [DomainRegistration].
/// Supports all three storage modes: Direct, Versioned, Logged.
///
/// ## Table Naming Convention
///
/// - Direct: `{collection}`
/// - Versioned: `{collection}_versions`, `{collection}_current`
/// - Logged: `{collection}`, `{collection}_log`
///
/// ## Multi-tenancy
///
/// All tables include `tenant_id TEXT NOT NULL` column.
/// Queries are filtered by tenant_id in PostgresVaultStorage.
///
/// ## Migrations
///
/// Migrations are tracked in `_vault_migrations` table.
@internal
final class PostgresSchemaDeployer implements SchemaDeployer {
  final Pool _pool;

  PostgresSchemaDeployer({required Pool pool}) : _pool = pool;

  /// Доступ к пулу соединений.
  Pool get pool => _pool;

  @override
  Future<void> ensureSchema(List<DomainRegistration> domains) async {
    // Create migrations table if not exists
    await _ensureMigrationsTable();

    // Create registry table if not exists
    await _ensureRegistryTable();

    // Validate registry against code
    await _validateRegistry(domains);

    // Validate and create tables for each domain based on mode
    for (final domain in domains) {
      // Проверка существования таблицы
      final exists = await _tableExists(domain.collection);

      if (exists) {
        // Таблица существует - валидируем структуру
        await _validateTableStructure(domain);
      } else {
        // Таблица не существует - создаём
        await _createTablesForDomain(domain);
      }

      // Записать/обновить регистрацию в _vault_registry
      await _upsertRegistry(domain);
    }
  }

  /// Создать таблицы для домена в зависимости от режима.
  Future<void> _createTablesForDomain(DomainRegistration domain) async {
    switch (domain.mode) {
      case StorageMode.direct:
        await _createDirectTable(domain);
        break;
      case StorageMode.versioned:
        await _createVersionedTables(domain);
        break;
      case StorageMode.logged:
        await _createLoggedTables(domain);
        break;
      case StorageMode.artifact:
      case StorageMode.vector:
        // TODO: Implement in future sprints
        break;
    }
  }

  /// Ensure _vault_migrations table exists.
  Future<void> _ensureMigrationsTable() async {
    await _pool.run((Session connection) async {
      await connection.execute('''
        CREATE TABLE IF NOT EXISTS _vault_migrations (
          id SERIAL PRIMARY KEY,
          collection TEXT NOT NULL,
          from_version TEXT NOT NULL,
          to_version TEXT NOT NULL,
          description TEXT NOT NULL,
          applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
      ''');
    });
  }

  /// Ensure _vault_registry table exists.
  Future<void> _ensureRegistryTable() async {
    await _pool.run((Session connection) async {
      await connection.execute('''
        CREATE TABLE IF NOT EXISTS _vault_registry (
          collection      TEXT PRIMARY KEY,
          mode            TEXT NOT NULL,
          schema_version  TEXT NOT NULL,
          index_defs      JSONB NOT NULL DEFAULT '[]',
          dart_class      TEXT,
          registered_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
      ''');
    });
  }

  /// Validate registry: check for mode conflicts between DB and code.
  Future<void> _validateRegistry(List<DomainRegistration> domains) async {
    await _pool.run((Session connection) async {
      for (final domain in domains) {
        final result = await connection.execute(
          Sql.named(
            'SELECT mode FROM _vault_registry WHERE collection = @collection',
          ),
          parameters: {'collection': domain.collection},
        );

        if (result.isEmpty) continue; // новая коллекция — всё ок

        final registeredMode = result.first[0] as String;
        if (registeredMode != domain.mode.name) {
          throw StateError(
            'Collection "${domain.collection}" was registered as mode '
            '"$registeredMode" in the database, but current code uses '
            '"${domain.mode.name}". '
            'This is a breaking change. Run a migration or drop the table.',
          );
        }
      }
    });
  }

  /// Upsert domain registration into _vault_registry.
  Future<void> _upsertRegistry(DomainRegistration domain) async {
    await _pool.run((Session connection) async {
      final indexDefs = domain.indexes
          .map((i) => {'name': i.name, 'field': i.field})
          .toList();

      // Сериализуем в JSON строку для передачи в PostgreSQL
      final indexDefsJson = jsonEncode(indexDefs);

      await connection.execute(
        Sql.named('''
          INSERT INTO _vault_registry
            (collection, mode, schema_version, index_defs, dart_class, updated_at)
          VALUES
            (@collection, @mode, @version, @indexes::jsonb, @dart_class, NOW())
          ON CONFLICT (collection) DO UPDATE SET
            mode           = EXCLUDED.mode,
            schema_version = EXCLUDED.schema_version,
            index_defs     = EXCLUDED.index_defs,
            dart_class     = EXCLUDED.dart_class,
            updated_at     = NOW()
        '''),
        parameters: {
          'collection': domain.collection,
          'mode': domain.mode.name,
          'version': domain.schemaVersion,
          'indexes': indexDefsJson,
          'dart_class': domain.dartClass,
        },
      );
    });
  }

  /// Get all registry entries from _vault_registry.
  Future<List<Map<String, dynamic>>> getRegistryEntries() async {
    return await _pool.run((Session connection) async {
      final result = await connection.execute(
        'SELECT collection, mode, schema_version, index_defs, dart_class, '
        'registered_at, updated_at '
        'FROM _vault_registry ORDER BY registered_at',
      );
      return result.map((row) => {
        'collection':     row[0] as String,
        'mode':           row[1] as String,
        'schemaVersion':  row[2] as String,
        'indexDefs':      row[3],
        'dartClass':      row[4] as String?,
        'registeredAt':   (row[5] as DateTime).toIso8601String(),
        'updatedAt':      (row[6] as DateTime).toIso8601String(),
      }).toList();
    });
  }

  /// Enable Row Level Security (RLS) on a table.
  /// Creates policies for tenant isolation.
  Future<void> _enableRls(String tableName) async {
    await _pool.run((Session connection) async {
      // Enable RLS on the table (FORCE применяет RLS даже к владельцу таблицы)
      await connection.execute('ALTER TABLE $tableName ENABLE ROW LEVEL SECURITY');
      await connection.execute('ALTER TABLE $tableName FORCE ROW LEVEL SECURITY');

      // Policy for SELECT: see only own tenant data
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

      // Policy for INSERT: insert only into own tenant
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
    });
  }

  @override
  Future<void> applyMigration(DomainMigration migration) async {
    await _pool.run((Session connection) async {
      final keys = Storable.keys.dbKeys;

      // If transform is provided, apply it to all records
      if (migration.transform != null) {
        // Fetch all records
        final result = await connection.execute(
          'SELECT ${keys.id}, ${keys.tenantId}, ${keys.data} FROM ${migration.collection}',
        );

        // Transform each record
        for (final row in result) {
          final id = row[0] as String;
          final tenantId = row[1] as String;
          final data = row[2] as Map<String, dynamic>;

          final transformed = migration.transform!(data);
          if (transformed != null) {
            // Update with transformed data
            await connection.execute(
              Sql.named(
                'UPDATE ${migration.collection} SET ${keys.data} = @data WHERE ${keys.id} = @id AND ${keys.tenantId} = @tenant_id',
              ),
              parameters: {
                'data': transformed,
                'id': id,
                'tenant_id': tenantId,
              },
            );
          }
        }
      }

      // Drop indexes
      for (final indexName in migration.indexesToDrop) {
        await connection.execute('DROP INDEX IF EXISTS $indexName');
      }

      // Create new indexes
      await _createIndexes(migration.collection, migration.indexesToCreate);

      // Record migration
      await connection.execute(
        Sql.named('''
        INSERT INTO _vault_migrations (collection, from_version, to_version, description)
        VALUES (@collection, @from, @to, @desc)
        '''),
        parameters: {
          'collection': migration.collection,
          'from': migration.fromVersion,
          'to': migration.toVersion,
          'desc': migration.description,
        },
      );
    });
  }

  @override
  Future<bool> needsMigration(String collection, String toVersion) async {
    return await _pool.run((Session connection) async {
      final result = await connection.execute(
        Sql.named('''
        SELECT COUNT(*) FROM _vault_migrations
        WHERE collection = @collection AND to_version = @version
        '''),
        parameters: {
          'collection': collection,
          'version': toVersion,
        },
      );

      final count = result.first[0] as int;
      return count == 0; // Needs migration if not found
    });
  }

  @override
  Future<List<AppliedMigration>> history() async {
    return await _pool.run((Session connection) async {
      final result = await connection.execute(
        '''
        SELECT collection, from_version, to_version, description, applied_at
        FROM _vault_migrations
        ORDER BY applied_at ASC
        ''',
      );

      return result.map((row) {
        return AppliedMigration(
          collection: row[0] as String,
          fromVersion: row[1] as String,
          toVersion: row[2] as String,
          description: row[3] as String,
          appliedAt: row[4] as DateTime,
        );
      }).toList();
    });
  }

  /// Create table for Direct mode.
  Future<void> _createDirectTable(DomainRegistration domain) async {
    await _pool.run((Session connection) async {
      final keys = Storable.keys.dbKeys;

      // Main table: id, tenant_id, data, timestamps
      await connection.execute('''
        CREATE TABLE IF NOT EXISTS ${domain.collection} (
          ${keys.id} TEXT NOT NULL,
          ${keys.tenantId} TEXT NOT NULL,
          ${keys.data} JSONB NOT NULL,
          ${keys.createdAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          ${keys.updatedAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          PRIMARY KEY (${keys.id}, ${keys.tenantId})
        )
      ''');

      // Create indexes
      await _createIndexes(domain.collection, domain.indexes);

      // Create index on tenant_id for fast filtering
      await connection.execute('''
        CREATE INDEX IF NOT EXISTS idx_${domain.collection}_tenant
        ON ${domain.collection}(${keys.tenantId})
      ''');

      // Enable RLS for tenant isolation
      await _enableRls(domain.collection);
    });

    // Create deleted table for soft/hard delete tracking
    await _createDeletedTable(domain.collection);
  }

  /// Create tables for Versioned mode.
  Future<void> _createVersionedTables(DomainRegistration domain) async {
    await _pool.run((Session connection) async {
      final versionsTable = VersionedStorageContract.versionsTable(domain.collection);
      final currentTable = VersionedStorageContract.currentTable(domain.collection);

      // Versions table: stores all version nodes
      await connection.execute('''
        CREATE TABLE IF NOT EXISTS $versionsTable (
          ${VersionedStorageContract.kNodeId} TEXT PRIMARY KEY,
          ${VersionedStorageContract.kEntityId} TEXT NOT NULL,
          ${VersionedStorageContract.kParentNodeId} TEXT,
          ${VersionedStorageContract.kTenantId} TEXT NOT NULL,
          ${VersionedStorageContract.kVersion} TEXT,
          ${VersionedStorageContract.kStatus} TEXT NOT NULL,
          ${VersionedStorageContract.kBranch} TEXT NOT NULL DEFAULT 'main',
          ${VersionedStorageContract.kSequenceNumber} INTEGER NOT NULL DEFAULT 1,
          ${VersionedStorageContract.kCreatedBy} TEXT NOT NULL DEFAULT '',
          ${VersionedStorageContract.kCreatedAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          ${VersionedStorageContract.kData} JSONB NOT NULL
        )
      ''');

      // Current table: tracks current version per entity
      await connection.execute('''
        CREATE TABLE IF NOT EXISTS $currentTable (
          ${VersionedStorageContract.kEntityId} TEXT NOT NULL,
          ${VersionedStorageContract.kTenantId} TEXT NOT NULL,
          ${VersionedStorageContract.kNodeId} TEXT NOT NULL,
          ${VersionedStorageContract.kUpdatedAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          PRIMARY KEY (${VersionedStorageContract.kEntityId}, ${VersionedStorageContract.kTenantId})
        )
      ''');

      // Indexes
      await connection.execute('''
        CREATE INDEX IF NOT EXISTS idx_${domain.collection}_versions_entity
        ON $versionsTable(${VersionedStorageContract.kEntityId}, ${VersionedStorageContract.kTenantId})
      ''');

      await connection.execute('''
        CREATE INDEX IF NOT EXISTS idx_${domain.collection}_versions_status
        ON $versionsTable(${VersionedStorageContract.kStatus})
      ''');

      await _createIndexes(versionsTable, domain.indexes);

      // Enable RLS for tenant isolation
      await _enableRls(versionsTable);
      await _enableRls(currentTable);
    });

    // Create deleted table for soft/hard delete tracking
    await _createDeletedTable(domain.collection);
  }

  /// Create tables for Logged mode.
  Future<void> _createLoggedTables(DomainRegistration domain) async {
    await _pool.run((Session connection) async {
      final keys = Storable.keys.dbKeys;

      // Main table
      await connection.execute('''
        CREATE TABLE IF NOT EXISTS ${domain.collection} (
          ${keys.id} TEXT NOT NULL,
          ${keys.tenantId} TEXT NOT NULL,
          ${keys.data} JSONB NOT NULL,
          ${keys.createdAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          ${keys.updatedAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          PRIMARY KEY (${keys.id}, ${keys.tenantId})
        )
      ''');

      // Log table: unified schema (id, tenant_id, data JSONB)
      // LogEntry хранится как документ в data JSONB
      await connection.execute('''
        CREATE TABLE IF NOT EXISTS ${domain.collection}_log (
          ${keys.id} TEXT NOT NULL,
          ${keys.tenantId} TEXT NOT NULL,
          ${keys.data} JSONB NOT NULL,
          ${keys.createdAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          ${keys.updatedAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          PRIMARY KEY (${keys.id}, ${keys.tenantId})
        )
      ''');

      // Indexes
      await _createIndexes(domain.collection, domain.indexes);

      // Index на entityId внутри JSONB для быстрого поиска логов по сущности
      await connection.execute('''
        CREATE INDEX IF NOT EXISTS idx_${domain.collection}_log_entity
        ON ${domain.collection}_log((${keys.data}->>'${LogEntry.keys.jsonKeys.entityId}'))
      ''');

      await connection.execute('''
        CREATE INDEX IF NOT EXISTS idx_${domain.collection}_tenant
        ON ${domain.collection}(${keys.tenantId})
      ''');

      // Enable RLS for tenant isolation
      await _enableRls(domain.collection);
      await _enableRls('${domain.collection}_log');
    });

    // Create deleted table for soft/hard delete tracking
    await _createDeletedTable(domain.collection);
  }

  /// Create deleted table for any storage mode.
  /// This table stores snapshots of deleted entities for audit and restore.
  ///
  /// Used by all storage modes (Direct, Logged, Versioned) to track deletions.
  /// Supports both soft delete (entity marked as deleted) and hard delete
  /// (entity removed from main table).
  Future<void> _createDeletedTable(String collection) async {
    await _pool.run((Session connection) async {
      final keys = Storable.keys.dbKeys;
      final deletedTable = '${collection}_deleted';

      // Deleted table: stores full entity snapshot + deletion metadata
      await connection.execute('''
        CREATE TABLE IF NOT EXISTS $deletedTable (
          ${keys.id} TEXT NOT NULL,
          ${keys.tenantId} TEXT NOT NULL,
          ${keys.data} JSONB NOT NULL,
          ${keys.deletedAt} TIMESTAMPTZ NOT NULL,
          deleted_by TEXT NOT NULL,
          delete_type TEXT NOT NULL,
          ${keys.createdAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          ${keys.updatedAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          PRIMARY KEY (${keys.id}, ${keys.tenantId})
        )
      ''');

      // Index on deleted_at for time-based queries
      await connection.execute('''
        CREATE INDEX IF NOT EXISTS idx_${collection}_deleted_at
        ON $deletedTable(${keys.deletedAt})
      ''');

      // Index on delete_type for filtering soft/hard deletes
      await connection.execute('''
        CREATE INDEX IF NOT EXISTS idx_${collection}_delete_type
        ON $deletedTable(delete_type)
      ''');

      // Index on tenant_id for fast filtering
      await connection.execute('''
        CREATE INDEX IF NOT EXISTS idx_${collection}_deleted_tenant
        ON $deletedTable(${keys.tenantId})
      ''');

      // Enable RLS for tenant isolation
      await _enableRls(deletedTable);
    });
  }

  /// Create indexes from domain.indexes.
  Future<void> _createIndexes(
    String tableName,
    List<VaultIndex> indexes,
  ) async {
    if (indexes.isEmpty) return;

    await _pool.run((Session connection) async {
      for (final index in indexes) {
        // Create index on JSONB field using -> operator
        await connection.execute('''
          CREATE INDEX IF NOT EXISTS ${index.name}
          ON $tableName((data->>'${index.field}'))
        ''');
      }
    });
  }

  // ── Schema Validation ─────────────────────────────────────────────────────

  /// Проверить существование таблицы.
  Future<bool> _tableExists(String tableName) async {
    return await _pool.run((Session connection) async {
      final result = await connection.execute(
        Sql.named('''
        SELECT EXISTS (
          SELECT FROM information_schema.tables
          WHERE table_schema = 'public'
          AND table_name = @table_name
        )
        '''),
        parameters: {'table_name': tableName},
      );

      return result.first[0] as bool;
    });
  }

  /// Валидировать структуру существующей таблицы.
  Future<void> _validateTableStructure(DomainRegistration domain) async {
    final keys = Storable.keys.dbKeys;

    // Получить список колонок таблицы
    final columns = await _getTableColumns(domain.collection);

    // Проверка обязательных колонок
    final requiredColumns = {keys.id, keys.tenantId, keys.data, keys.createdAt, keys.updatedAt};
    final missingColumns = requiredColumns.difference(columns.keys.toSet());

    if (missingColumns.isNotEmpty) {
      throw StateError(
        'Table "${domain.collection}" is missing required columns: ${missingColumns.join(", ")}\n'
        'Expected columns: ${requiredColumns.join(", ")}\n'
        'Found columns: ${columns.keys.join(", ")}\n'
        'Please run migration or drop the table to recreate it.',
      );
    }

    // Проверка типов колонок
    _validateColumnType(domain.collection, columns, keys.id, 'text');
    _validateColumnType(domain.collection, columns, keys.tenantId, 'text');
    _validateColumnType(domain.collection, columns, keys.data, 'jsonb');
    _validateColumnType(domain.collection, columns, keys.createdAt, 'timestamp with time zone');
    _validateColumnType(domain.collection, columns, keys.updatedAt, 'timestamp with time zone');

    // Проверка дополнительных таблиц для Versioned и Logged режимов
    if (domain.mode == StorageMode.versioned) {
      await _validateVersionedTables(domain);
    } else if (domain.mode == StorageMode.logged) {
      await _validateLoggedTables(domain);
    }
  }

  /// Получить список колонок таблицы с их типами.
  Future<Map<String, String>> _getTableColumns(String tableName) async {
    return await _pool.run((Session connection) async {
      final result = await connection.execute(
        Sql.named('''
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = @table_name
        '''),
        parameters: {'table_name': tableName},
      );

      return Map.fromEntries(
        result.map((row) => MapEntry(
              row[0] as String,
              row[1] as String,
            )),
      );
    });
  }

  /// Проверить тип колонки.
  void _validateColumnType(
    String tableName,
    Map<String, String> columns,
    String columnName,
    String expectedType,
  ) {
    final actualType = columns[columnName];
    if (actualType == null) {
      throw StateError(
        'Table "$tableName" is missing column "$columnName"',
      );
    }

    if (actualType != expectedType) {
      throw StateError(
        'Table "$tableName" column "$columnName" has wrong type.\n'
        'Expected: $expectedType\n'
        'Found: $actualType',
      );
    }
  }

  /// Валидировать таблицы для Versioned режима.
  Future<void> _validateVersionedTables(DomainRegistration domain) async {
    final versionsTable = VersionedStorageContract.versionsTable(domain.collection);
    final currentTable = VersionedStorageContract.currentTable(domain.collection);

    if (!await _tableExists(versionsTable)) {
      throw StateError(
        'Versioned mode requires table "$versionsTable" but it does not exist.\n'
        'Please run migration or drop tables to recreate them.',
      );
    }

    if (!await _tableExists(currentTable)) {
      throw StateError(
        'Versioned mode requires table "$currentTable" but it does not exist.\n'
        'Please run migration or drop tables to recreate them.',
      );
    }

    // Проверка структуры _versions таблицы
    final versionsColumns = await _getTableColumns(versionsTable);
    final requiredVersionsColumns = {
      VersionedStorageContract.kNodeId,
      VersionedStorageContract.kEntityId,
      VersionedStorageContract.kTenantId,
      VersionedStorageContract.kVersion,
      VersionedStorageContract.kStatus,
      VersionedStorageContract.kBranch,
      VersionedStorageContract.kData,
      VersionedStorageContract.kCreatedAt,
      VersionedStorageContract.kCreatedBy,
      VersionedStorageContract.kSequenceNumber,
    };
    final missingVersionsColumns = requiredVersionsColumns.difference(versionsColumns.keys.toSet());

    if (missingVersionsColumns.isNotEmpty) {
      throw StateError(
        'Table "$versionsTable" is missing required columns: ${missingVersionsColumns.join(", ")}',
      );
    }

    // Проверка структуры _current таблицы
    final currentColumns = await _getTableColumns(currentTable);
    final requiredCurrentColumns = {
      VersionedStorageContract.kEntityId,
      VersionedStorageContract.kTenantId,
      VersionedStorageContract.kNodeId,
      VersionedStorageContract.kUpdatedAt,
    };
    final missingCurrentColumns = requiredCurrentColumns.difference(currentColumns.keys.toSet());

    if (missingCurrentColumns.isNotEmpty) {
      throw StateError(
        'Table "$currentTable" is missing required columns: ${missingCurrentColumns.join(", ")}',
      );
    }
  }

  /// Валидировать таблицы для Logged режима.
  Future<void> _validateLoggedTables(DomainRegistration domain) async {
    final keys = Storable.keys.dbKeys;
    final logTable = '${domain.collection}_log';

    if (!await _tableExists(logTable)) {
      throw StateError(
        'Logged mode requires table "$logTable" but it does not exist.\n'
        'Please run migration or drop tables to recreate them.',
      );
    }

    // Проверка структуры _log таблицы (унифицированная схема: id, tenant_id, data, created_at)
    final logColumns = await _getTableColumns(logTable);
    final requiredLogColumns = {keys.id, keys.tenantId, keys.data, keys.createdAt};
    final missingLogColumns = requiredLogColumns.difference(logColumns.keys.toSet());

    if (missingLogColumns.isNotEmpty) {
      throw StateError(
        'Table "$logTable" is missing required columns: ${missingLogColumns.join(", ")}\n'
        'Expected unified schema: ${requiredLogColumns.join(", ")}\n'
        'Found columns: ${logColumns.keys.join(", ")}',
      );
    }
  }
}
