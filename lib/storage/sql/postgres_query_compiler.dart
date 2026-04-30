import 'dart:convert';
import 'package:aq_schema/aq_schema.dart';
import 'i_sql_query_compiler.dart';

/// PostgreSQL реализация [ISQLQueryCompiler].
///
/// ## Стратегия хранения
///
/// Каждая коллекция — одна таблица с JSONB колонкой `data`.
/// Весь объект хранится в `data`, tenant_id — отдельная колонка для индексации.
///
/// ## Параметры
///
/// Все запросы используют позиционные параметры (`$1`, `$2`, ...).
/// tenant_id **всегда** передаётся явным параметром — без session state,
/// без `set_config`, без RLS зависимостей. Это устраняет класс ошибок
/// с prepared statement конфликтами в connection pool.
///
/// ## Фильтрация JSONB
///
/// Поля фильтруются через `(data->>'field')` — текстовое извлечение из JSONB.
/// Для числовых сравнений используется `CAST`.
final class PostgresQueryCompiler implements ISQLQueryCompiler {
  const PostgresQueryCompiler();

  // ── DDL ────────────────────────────────────────────────────────────────────

  @override
  String createTableSql(String table) => '''
    CREATE TABLE IF NOT EXISTS $table (
      id        TEXT NOT NULL,
      tenant_id TEXT NOT NULL,
      data      JSONB NOT NULL DEFAULT '{}',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (id, tenant_id)
    )
  ''';

  @override
  String createIndexSql(
    String table,
    String indexName,
    String field, {
    bool unique = false,
  }) {
    final uniqueClause = unique ? 'UNIQUE ' : '';
    return 'CREATE ${uniqueClause}INDEX IF NOT EXISTS $indexName '
        "ON $table ((data->>'$field'))";
  }

  // ── DML — Read ─────────────────────────────────────────────────────────────

  @override
  CompiledQuery select(String table, String tenantId, String id) =>
      CompiledQuery(
        'SELECT data FROM $table WHERE id = \$1 AND tenant_id = \$2',
        [id, tenantId],
      );

  @override
  CompiledQuery selectAll(String table, String tenantId, VaultQuery query) {
    final params = <Object?>[tenantId]; // $1 = tenant_id
    final sql = StringBuffer('SELECT data FROM $table WHERE tenant_id = \$1');
    _appendFilters(sql, params, query.filters);
    _appendSort(sql, query.sort);
    _appendPagination(sql, query.limit, query.offset);
    return CompiledQuery(sql.toString(), params);
  }

  @override
  CompiledQuery count(String table, String tenantId, VaultQuery query) {
    final params = <Object?>[tenantId];
    final sql = StringBuffer('SELECT COUNT(*) FROM $table WHERE tenant_id = \$1');
    _appendFilters(sql, params, query.filters);
    return CompiledQuery(sql.toString(), params);
  }

  @override
  CompiledQuery exists(String table, String tenantId, String id) =>
      CompiledQuery(
        'SELECT EXISTS(SELECT 1 FROM $table WHERE id = \$1 AND tenant_id = \$2)',
        [id, tenantId],
      );

  // ── DML — Write ────────────────────────────────────────────────────────────

  @override
  CompiledQuery upsert(
    String table,
    String tenantId,
    String id,
    Map<String, dynamic> data,
  ) =>
      CompiledQuery(
        '''
        INSERT INTO $table (id, tenant_id, data, updated_at)
        VALUES (\$1, \$2, \$3, NOW())
        ON CONFLICT (id, tenant_id) DO UPDATE
          SET data = EXCLUDED.data, updated_at = NOW()
        ''',
        [id, tenantId, jsonEncode(data)],
      );

  @override
  CompiledQuery delete(String table, String tenantId, String id) =>
      CompiledQuery(
        'DELETE FROM $table WHERE id = \$1 AND tenant_id = \$2',
        [id, tenantId],
      );

  @override
  CompiledQuery deleteAll(String table, String tenantId) =>
      CompiledQuery(
        'DELETE FROM $table WHERE tenant_id = \$1',
        [tenantId],
      );

  // ── Private ────────────────────────────────────────────────────────────────

  void _appendFilters(
    StringBuffer sql,
    List<Object?> params,
    List<VaultFilter> filters,
  ) {
    for (final filter in filters) {
      final idx = params.length + 1;
      final field = "(data->>'${filter.field}')";

      switch (filter.operator) {
        case VaultOperator.isNull:
          sql.write(' AND $field IS NULL');
        case VaultOperator.isNotNull:
          sql.write(' AND $field IS NOT NULL');
        case VaultOperator.inList:
          params.add(filter.value);
          sql.write(' AND $field = ANY(\$$idx)');
        case VaultOperator.notInList:
          params.add(filter.value);
          sql.write(' AND NOT ($field = ANY(\$$idx))');
        case VaultOperator.contains:
          params.add('%${filter.value}%');
          sql.write(' AND $field ILIKE \$$idx');
        case VaultOperator.startsWith:
          params.add('${filter.value}%');
          sql.write(' AND $field ILIKE \$$idx');
        default:
          params.add(filter.value?.toString());
          sql.write(' AND $field ${filter.operator.sql} \$$idx');
      }
    }
  }

  void _appendSort(StringBuffer sql, VaultSort? sort) {
    if (sort == null) return;
    final dir = sort.descending ? 'DESC' : 'ASC';
    sql.write(" ORDER BY (data->>'${sort.field}') $dir");
  }

  void _appendPagination(StringBuffer sql, int? limit, int? offset) {
    if (limit != null) sql.write(' LIMIT $limit');
    if (offset != null && offset > 0) sql.write(' OFFSET $offset');
  }
}
