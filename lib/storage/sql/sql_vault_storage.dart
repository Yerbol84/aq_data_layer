import 'dart:async';
import 'dart:convert';

import 'package:aq_schema/aq_schema.dart';
import 'package:postgres/postgres.dart';

import 'i_sql_query_compiler.dart';

/// SQL-based [VaultStorage] driven by [ISQLQueryCompiler].
///
/// ## Архитектура
///
/// [SQLVaultStorage] — тонкий исполнитель. Он не знает о диалекте SQL.
/// Всю трансляцию [VaultQuery] → SQL делает [ISQLQueryCompiler].
///
/// ```
/// VaultQuery → ISQLQueryCompiler → CompiledQuery → Pool.run → PostgreSQL
/// ```
///
/// ## Tenant isolation
///
/// tenant_id передаётся явным параметром в каждый запрос.
/// Нет session state, нет `set_config`, нет RLS зависимостей.
/// Это устраняет класс ошибок с prepared statement конфликтами.
///
/// ## Использование
///
/// ```dart
/// final storage = SQLVaultStorage(
///   pool: pool,
///   tenantId: 'user-123',
///   compiler: const PostgresQueryCompiler(),
/// );
/// ```
final class SQLVaultStorage implements VaultStorage {
  final Pool<Object?> _pool;
  final String tenantId;
  final ISQLQueryCompiler _compiler;

  final _controllers = <String, StreamController<void>>{};

  SQLVaultStorage({
    required Pool<Object?> pool,
    required this.tenantId,
    required ISQLQueryCompiler compiler,
  })  : _pool = pool,
        _compiler = compiler;

  // ── Collections ────────────────────────────────────────────────────────────

  @override
  Future<void> ensureCollection(String collection) async {
    await _pool.run((s) => s.execute(_compiler.createTableSql(collection)));
  }

  // ── CRUD ───────────────────────────────────────────────────────────────────

  @override
  Future<void> put(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    final q = _compiler.upsert(collection, tenantId, id, data);
    await _pool.run((s) => s.execute(q.sql, parameters: q.params));
    _notify(collection);
  }

  @override
  Future<Map<String, dynamic>?> get(String collection, String id) async {
    final q = _compiler.select(collection, tenantId, id);
    final rows = await _pool.run((s) => s.execute(q.sql, parameters: q.params));
    if (rows.isEmpty) return null;
    return _decode(rows.first[0]);
  }

  @override
  Future<void> delete(String collection, String id) async {
    final q = _compiler.delete(collection, tenantId, id);
    await _pool.run((s) => s.execute(q.sql, parameters: q.params));
    _notify(collection);
  }

  @override
  Future<bool> exists(String collection, String id) async {
    final q = _compiler.exists(collection, tenantId, id);
    final rows = await _pool.run((s) => s.execute(q.sql, parameters: q.params));
    return rows.first[0] as bool? ?? false;
  }

  @override
  Future<void> putAll(
    String collection,
    Map<String, Map<String, dynamic>> entries,
  ) async {
    await _pool.run((s) async {
      for (final e in entries.entries) {
        final q = _compiler.upsert(collection, tenantId, e.key, e.value);
        await s.execute(q.sql, parameters: q.params);
      }
    });
    _notify(collection);
  }

  // ── Queries ────────────────────────────────────────────────────────────────

  @override
  Future<List<Map<String, dynamic>>> query(
    String collection,
    VaultQuery query,
  ) async {
    final q = _compiler.selectAll(collection, tenantId, query);
    final rows = await _pool.run((s) => s.execute(q.sql, parameters: q.params));
    return rows.map((r) => _decode(r[0])).toList();
  }

  @override
  Future<PageResult<Map<String, dynamic>>> queryPage(
    String collection,
    VaultQuery query,
  ) async {
    return await _pool.run((s) async {
      final countQ = _compiler.count(collection, tenantId, query);
      final countRows = await s.execute(countQ.sql, parameters: countQ.params);
      final total = countRows.first[0] as int? ?? 0;

      final dataQ = _compiler.selectAll(collection, tenantId, query);
      final dataRows = await s.execute(dataQ.sql, parameters: dataQ.params);
      final items = dataRows.map((r) => _decode(r[0])).toList();

      return PageResult(
        items: items,
        total: total,
        offset: query.offset ?? 0,
        limit: query.limit ?? items.length,
      );
    });
  }

  @override
  Future<int> count(String collection, VaultQuery query) async {
    final q = _compiler.count(collection, tenantId, query);
    final rows = await _pool.run((s) => s.execute(q.sql, parameters: q.params));
    return rows.first[0] as int? ?? 0;
  }

  // ── Indexes ────────────────────────────────────────────────────────────────

  @override
  Future<void> createIndex(String collection, VaultIndex index) async {
    final sql = _compiler.createIndexSql(
      collection,
      index.name,
      index.field,
      unique: index.unique,
    );
    await _pool.run((s) => s.execute(sql));
  }

  @override
  Future<void> updateIndex(String collection, String id, Map<String, dynamic> indexData) async {
    // JSONB индексы обновляются автоматически при upsert — no-op.
  }

  @override
  Future<void> removeFromIndex(String collection, String id) async {
    // JSONB индексы обновляются автоматически при delete — no-op.
  }

  // ── Transactions ───────────────────────────────────────────────────────────

  @override
  Future<T> transaction<T>(Future<T> Function(VaultStorage tx) action) async {
    return await _pool.runTx((session) async {
      final tx = _SQLVaultStorageTx(
        session: session,
        tenantId: tenantId,
        compiler: _compiler,
      );
      return await action(tx);
    });
  }

  // ── Reactivity ─────────────────────────────────────────────────────────────

  @override
  Stream<void> watchChanges(String collection) {
    _controllers.putIfAbsent(collection, () => StreamController<void>.broadcast());
    return _controllers[collection]!.stream;
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> clear(String collection) async {
    final q = _compiler.deleteAll(collection, tenantId);
    await _pool.run((s) => s.execute(q.sql, parameters: q.params));
    _notify(collection);
  }

  @override
  Future<void> dispose() async {
    for (final c in _controllers.values) {
      await c.close();
    }
    _controllers.clear();
  }

  // ── Private ────────────────────────────────────────────────────────────────

  void _notify(String collection) => _controllers[collection]?.add(null);

  Map<String, dynamic> _decode(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is String) return jsonDecode(raw) as Map<String, dynamic>;
    return {};
  }
}

// ── Transaction wrapper ───────────────────────────────────────────────────────

/// [VaultStorage] внутри транзакции — использует [TxSession] вместо [Pool].
final class _SQLVaultStorageTx implements VaultStorage {
  final TxSession _session;
  final String tenantId;
  final ISQLQueryCompiler _compiler;

  _SQLVaultStorageTx({
    required TxSession session,
    required this.tenantId,
    required ISQLQueryCompiler compiler,
  })  : _session = session,
        _compiler = compiler;

  @override
  Future<void> ensureCollection(String collection) async {
    await _session.execute(_compiler.createTableSql(collection));
  }

  @override
  Future<void> put(String collection, String id, Map<String, dynamic> data) async {
    final q = _compiler.upsert(collection, tenantId, id, data);
    await _session.execute(q.sql, parameters: q.params);
  }

  @override
  Future<Map<String, dynamic>?> get(String collection, String id) async {
    final q = _compiler.select(collection, tenantId, id);
    final rows = await _session.execute(q.sql, parameters: q.params);
    if (rows.isEmpty) return null;
    final raw = rows.first[0];
    if (raw is Map<String, dynamic>) return raw;
    if (raw is String) return jsonDecode(raw) as Map<String, dynamic>;
    return null;
  }

  @override
  Future<void> delete(String collection, String id) async {
    final q = _compiler.delete(collection, tenantId, id);
    await _session.execute(q.sql, parameters: q.params);
  }

  @override
  Future<bool> exists(String collection, String id) async {
    final q = _compiler.exists(collection, tenantId, id);
    final rows = await _session.execute(q.sql, parameters: q.params);
    return rows.first[0] as bool? ?? false;
  }

  @override
  Future<void> putAll(String collection, Map<String, Map<String, dynamic>> entries) async {
    for (final e in entries.entries) {
      final q = _compiler.upsert(collection, tenantId, e.key, e.value);
      await _session.execute(q.sql, parameters: q.params);
    }
  }

  @override
  Future<List<Map<String, dynamic>>> query(String collection, VaultQuery query) async {
    final q = _compiler.selectAll(collection, tenantId, query);
    final rows = await _session.execute(q.sql, parameters: q.params);
    return rows.map((r) {
      final raw = r[0];
      if (raw is Map<String, dynamic>) return raw;
      if (raw is String) return jsonDecode(raw) as Map<String, dynamic>;
      return <String, dynamic>{};
    }).toList();
  }

  @override
  Future<PageResult<Map<String, dynamic>>> queryPage(String collection, VaultQuery query) async {
    final countQ = _compiler.count(collection, tenantId, query);
    final total = (await _session.execute(countQ.sql, parameters: countQ.params)).first[0] as int? ?? 0;
    final dataQ = _compiler.selectAll(collection, tenantId, query);
    final rows = await _session.execute(dataQ.sql, parameters: dataQ.params);
    final items = rows.map((r) {
      final raw = r[0];
      if (raw is Map<String, dynamic>) return raw;
      if (raw is String) return jsonDecode(raw) as Map<String, dynamic>;
      return <String, dynamic>{};
    }).toList();
    return PageResult(items: items, total: total, offset: query.offset ?? 0, limit: query.limit ?? items.length);
  }

  @override
  Future<int> count(String collection, VaultQuery query) async {
    final q = _compiler.count(collection, tenantId, query);
    return (await _session.execute(q.sql, parameters: q.params)).first[0] as int? ?? 0;
  }

  @override
  Future<void> createIndex(String collection, VaultIndex index) async {
    await _session.execute(_compiler.createIndexSql(collection, index.name, index.field, unique: index.unique));
  }

  @override
  Future<void> updateIndex(String collection, String id, Map<String, dynamic> indexData) async {}

  @override
  Future<void> removeFromIndex(String collection, String id) async {}

  @override
  Future<T> transaction<T>(Future<T> Function(VaultStorage tx) action) => action(this);

  @override
  Stream<void> watchChanges(String collection) => const Stream.empty();

  @override
  Future<void> clear(String collection) async {
    final q = _compiler.deleteAll(collection, tenantId);
    await _session.execute(q.sql, parameters: q.params);
  }

  @override
  Future<void> dispose() async {}
}
