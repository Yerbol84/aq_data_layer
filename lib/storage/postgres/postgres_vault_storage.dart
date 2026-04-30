import 'package:aq_schema/aq_schema.dart';
import 'package:postgres/postgres.dart';

import '../sql/postgres_query_compiler.dart';
import '../sql/sql_vault_storage.dart';

/// PostgreSQL [VaultStorage] — делегирует в [SQLVaultStorage] с [PostgresQueryCompiler].
///
/// Публичный API не изменился — все вызывающие стороны работают как раньше.
/// Вся SQL логика теперь в [PostgresQueryCompiler] и [SQLVaultStorage].
final class PostgresVaultStorage implements VaultStorage {
  final Pool<Object?> pool;
  final String tenantId;
  final SQLVaultStorage _delegate;

  PostgresVaultStorage({
    required this.pool,
    required this.tenantId,
  }) : _delegate = SQLVaultStorage(
          pool: pool,
          tenantId: tenantId,
          compiler: const PostgresQueryCompiler(),
        );

  @override
  Future<void> ensureCollection(String collection) =>
      _delegate.ensureCollection(collection);

  @override
  Future<void> put(String collection, String id, Map<String, dynamic> data) =>
      _delegate.put(collection, id, data);

  @override
  Future<Map<String, dynamic>?> get(String collection, String id) =>
      _delegate.get(collection, id);

  @override
  Future<void> delete(String collection, String id) =>
      _delegate.delete(collection, id);

  @override
  Future<bool> exists(String collection, String id) =>
      _delegate.exists(collection, id);

  @override
  Future<void> putAll(String collection, Map<String, Map<String, dynamic>> entries) =>
      _delegate.putAll(collection, entries);

  @override
  Future<List<Map<String, dynamic>>> query(String collection, VaultQuery query) =>
      _delegate.query(collection, query);

  @override
  Future<PageResult<Map<String, dynamic>>> queryPage(String collection, VaultQuery query) =>
      _delegate.queryPage(collection, query);

  @override
  Future<int> count(String collection, VaultQuery query) =>
      _delegate.count(collection, query);

  @override
  Future<void> createIndex(String collection, VaultIndex index) =>
      _delegate.createIndex(collection, index);

  @override
  Future<void> updateIndex(String collection, String id, Map<String, dynamic> indexData) =>
      _delegate.updateIndex(collection, id, indexData);

  @override
  Future<void> removeFromIndex(String collection, String id) =>
      _delegate.removeFromIndex(collection, id);

  @override
  Future<T> transaction<T>(Future<T> Function(VaultStorage tx) action) =>
      _delegate.transaction(action);

  @override
  Stream<void> watchChanges(String collection) =>
      _delegate.watchChanges(collection);

  @override
  Future<void> clear(String collection) => _delegate.clear(collection);

  @override
  Future<void> dispose() => _delegate.dispose();
}
