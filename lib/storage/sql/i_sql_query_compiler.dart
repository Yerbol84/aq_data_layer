import 'package:aq_schema/aq_schema.dart';

/// SQL запрос с параметрами — неразделимый объект.
///
/// SQL и параметры всегда идут вместе. Нельзя передать SQL без параметров
/// или параметры без SQL — это исключает класс ошибок несогласованности.
final class CompiledQuery {
  /// SQL строка с позиционными плейсхолдерами (диалект определяет compiler).
  final String sql;

  /// Позиционные параметры в том же порядке что плейсхолдеры в [sql].
  final List<Object?> params;

  const CompiledQuery(this.sql, this.params);

  @override
  String toString() => 'CompiledQuery($sql, params: $params)';
}

/// Интерфейс компилятора SQL запросов для [SQLVaultStorage].
///
/// ## Философия
///
/// [SQLVaultStorage] не знает о диалекте SQL. Он знает только о [VaultQuery].
/// Compiler переводит [VaultQuery] → [CompiledQuery] для конкретной БД.
///
/// ## Изоляция
///
/// - [ISQLQueryCompiler] живёт в `aq_data_layer` (не в `aq_schema`) —
///   это деталь реализации data layer, не доменный контракт платформы.
/// - Клиент никогда не видит compiler — только репозитории.
///
/// ## Реализации
///
/// - [PostgresQueryCompiler] — PostgreSQL с JSONB хранением
/// - (будущее) `SqliteQueryCompiler` — SQLite для desktop/mobile
/// - (будущее) `MySqlQueryCompiler` — MySQL/MariaDB
///
/// ## Контракт хранения
///
/// Все реализации хранят данные в таблице со структурой:
/// ```sql
/// CREATE TABLE {collection} (
///   id        TEXT NOT NULL,
///   tenant_id TEXT NOT NULL,
///   data      JSONB/TEXT NOT NULL,  -- весь объект
///   PRIMARY KEY (id, tenant_id)
/// );
/// ```
/// tenant_id передаётся явным параметром в каждый запрос — без session state.
abstract interface class ISQLQueryCompiler {
  // ── DDL ────────────────────────────────────────────────────────────────────

  /// SQL для создания таблицы коллекции (если не существует).
  String createTableSql(String table);

  /// SQL для создания индекса на JSONB поле.
  String createIndexSql(String table, String indexName, String field, {bool unique = false});

  // ── DML — Read ─────────────────────────────────────────────────────────────

  /// SELECT одной записи по id и tenant_id.
  CompiledQuery select(String table, String tenantId, String id);

  /// SELECT всех записей по tenant_id с фильтрами, сортировкой, пагинацией.
  CompiledQuery selectAll(String table, String tenantId, VaultQuery query);

  /// SELECT COUNT(*) по tenant_id с фильтрами.
  CompiledQuery count(String table, String tenantId, VaultQuery query);

  /// SELECT EXISTS по id и tenant_id.
  CompiledQuery exists(String table, String tenantId, String id);

  // ── DML — Write ────────────────────────────────────────────────────────────

  /// INSERT ... ON CONFLICT UPDATE (upsert).
  CompiledQuery upsert(
    String table,
    String tenantId,
    String id,
    Map<String, dynamic> data,
  );

  /// DELETE по id и tenant_id.
  CompiledQuery delete(String table, String tenantId, String id);

  /// DELETE всех записей tenant_id в таблице.
  CompiledQuery deleteAll(String table, String tenantId);
}
