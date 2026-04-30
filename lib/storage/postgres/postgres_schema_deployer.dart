import 'dart:convert';
import 'package:postgres/postgres.dart';
import 'package:aq_schema/aq_schema.dart';
import '../../deploy/schema_deployer.dart';
import '../../deploy/domain_registration.dart';
import '../../deploy/versioned_storage_schema.dart';

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
final class PostgresSchemaDeployer implements SchemaDeployer {
  final Pool<Object?> _pool;

  PostgresSchemaDeployer({required Pool<Object?> pool}) : _pool = pool;

  /// Доступ к пулу соединений.
  Pool<Object?> get pool => _pool;

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

  /// Создать таблицы для домена — делегирует в schema.deploy().
  /// Нет switch по режимам — каждый тип хранения знает свою структуру.
  Future<void> _createTablesForDomain(DomainRegistration domain) async {
    await _pool.run((Session connection) async {
      await domain.schema.deploy(connection, domain.indexes);
    });
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
      for (final index in migration.indexesToCreate) {
        await connection.execute('''
          CREATE INDEX IF NOT EXISTS ${index.name}
          ON ${migration.collection}((data->>'${index.field}'))
        ''');
      }

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
    final schema = domain.schema as VersionedStorageSchema;
    final versionsTable = schema.tableNames.versions!;
    final currentTable = schema.tableNames.current!;

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
      VersionedStorageSchema.kNodeId,
      VersionedStorageSchema.kEntityId,
      VersionedStorageSchema.kTenantId,
      VersionedStorageSchema.kVersion,
      VersionedStorageSchema.kStatus,
      VersionedStorageSchema.kBranch,
      VersionedStorageSchema.kData,
      VersionedStorageSchema.kCreatedAt,
      VersionedStorageSchema.kCreatedBy,
      VersionedStorageSchema.kSequenceNumber,
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
      VersionedStorageSchema.kEntityId,
      VersionedStorageSchema.kTenantId,
      VersionedStorageSchema.kNodeId,
      VersionedStorageSchema.kUpdatedAt,
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
    final logTable = domain.schema.tableNames.log!;

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
