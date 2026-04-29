import 'dart:async';
import 'package:aq_schema/aq_schema.dart';
import 'package:meta/meta.dart';
import 'remote_vault_storage.dart';

/// Remote implementation of [LoggedRepository] that uses RPC directly.
///
/// Unlike [LoggedRepositoryImpl] which works through [VaultStorage.put/get],
/// this implementation calls RPC operations directly with proper actorId support.
@internal
final class RemoteLoggedRepository<T extends LoggedStorable>
    implements LoggedRepository<T> {
  final RemoteVaultStorage _storage;
  final String _collection;
  final T Function(Map<String, dynamic>) _fromMap;

  RemoteLoggedRepository({
    required RemoteVaultStorage storage,
    required String collection,
    required T Function(Map<String, dynamic>) fromMap,
  })  : _storage = storage,
        _collection = collection,
        _fromMap = fromMap;

  // ── Helper: Serialize VaultQuery ──────────────────────────────────────────

  Map<String, dynamic> _serializeQuery(VaultQuery q) => {
        'filters': q.filters
            .map((f) => {
                  'field': f.field,
                  'operator': f.operator.name,
                  'value': f.value,
                })
            .toList(),
        'sortField': q.sort?.field,
        'sortDescending': q.sort?.descending ?? false,
        'limit': q.limit,
        'offset': q.offset,
      };

  @override
  Future<void> save(T entity, {required String actorId}) async {
    await _storage.rpc(_collection, 'put', {
      'id': entity.id,
      'data': entity.toMap(),
      'actorId': actorId,
    });
  }

  @override
  Future<void> delete(String entityId, {required String actorId}) async {
    await _storage.rpc(_collection, 'delete', {
      'id': entityId,
      'actorId': actorId,
    });
  }

  @override
  Future<T?> findById(String id) async {
    final res = await _storage.rpc(_collection, 'get', {'id': id});
    if (res == null) return null;
    return _fromMap(Map<String, dynamic>.from(res as Map));
  }

  @override
  Future<List<T>> findAll({VaultQuery? query}) async {
    final res = await _storage.rpc(_collection, 'query', {
      if (query != null) 'query': _serializeQuery(query),
    });
    final list = res as List? ?? [];
    return list
        .map((e) => _fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  @override
  Future<PageResult<T>> findPage(VaultQuery query) async {
    final res = await _storage.rpc(_collection, 'queryPage', {
      'query': _serializeQuery(query),
    }) as Map<String, dynamic>;

    final items = (res['items'] as List)
        .map((e) => _fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();

    return PageResult(
      items: items,
      total: res['total'] as int,
      offset: res['offset'] as int,
      limit: res['limit'] as int,
    );
  }

  @override
  Future<int> count({VaultQuery? query}) async {
    final res = await _storage.rpc(_collection, 'count', {
      if (query != null) 'query': _serializeQuery(query),
    });
    return res as int? ?? 0;
  }

  @override
  Future<bool> exists(String id) async {
    final res = await _storage.rpc(_collection, 'exists', {'id': id});
    return res as bool? ?? false;
  }

  @override
  Future<List<LogEntry>> getHistory(String entityId) async {
    final res = await _storage.rpc(_collection, 'getHistory', {
      'entityId': entityId,
    });
    final list = res as List? ?? [];
    return list
        .map((e) => LogEntry.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  @override
  Future<List<LogEntry>> queryHistory(String entityId, VaultQuery query) async {
    final res = await _storage.rpc(_collection, 'queryHistory', {
      'entityId': entityId,
      'query': _serializeQuery(query),
    });
    final list = res as List? ?? [];
    return list
        .map((e) => LogEntry.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  @override
  Future<PageResult<LogEntry>> getHistoryPage(
      String entityId, VaultQuery query) async {
    final res = await _storage.rpc(_collection, 'getHistoryPage', {
      'entityId': entityId,
      'query': _serializeQuery(query),
    }) as Map<String, dynamic>;

    final items = (res['items'] as List)
        .map((e) => LogEntry.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();

    return PageResult(
      items: items,
      total: res['total'] as int,
      offset: res['offset'] as int,
      limit: res['limit'] as int,
    );
  }

  @override
  Future<T?> getStateAt(String entityId, DateTime moment) async {
    final res = await _storage.rpc(_collection, 'getStateAt', {
      'entityId': entityId,
      'moment': moment.toIso8601String(),
    });
    if (res == null) return null;
    return _fromMap(Map<String, dynamic>.from(res as Map));
  }

  @override
  Future<LogEntry?> getLastEntry(String entityId) async {
    final res = await _storage.rpc(_collection, 'getLastEntry', {
      'entityId': entityId,
    });
    if (res == null) return null;
    return LogEntry.fromMap(Map<String, dynamic>.from(res as Map));
  }

  @override
  Future<List<LogEntry>> getCollectionLog(
      {DateTime? from, DateTime? to}) async {
    final res = await _storage.rpc(_collection, 'getCollectionLog', {
      if (from != null) 'from': from.toIso8601String(),
      if (to != null) 'to': to.toIso8601String(),
    });
    final list = res as List? ?? [];
    return list
        .map((e) => LogEntry.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  @override
  Future<void> rollbackTo(
    String entityId,
    String entryId, {
    required String actorId,
  }) async {
    await _storage.rpc(_collection, 'rollbackTo', {
      'entityId': entityId,
      'entryId': entryId,
      'actorId': actorId,
    });
  }

  @override
  Future<void> registerIndex(VaultIndex index) async {
    await _storage.rpc(_collection, 'createIndex', {
      'name': index.name,
      'field': index.field,
      'unique': index.unique,
    });
  }

  @override
  Stream<List<LogEntry>> watchHistory(String entityId) {
    // TODO: Implement SSE-based watch
    throw UnimplementedError(
        'watchHistory not yet implemented for remote storage');
  }

  @override
  Stream<List<T>> watchAll({VaultQuery? query}) {
    // TODO: Implement SSE-based watch
    throw UnimplementedError('watchAll not yet implemented for remote storage');
  }

  @override
  Future<List<T>> findAllIncludingDeleted({VaultQuery? query}) {
    // TODO: implement findAllIncludingDeleted
    throw UnimplementedError();
  }

  @override
  Future<void> restore(String entityId, {required String actorId}) {
    // TODO: implement restore
    throw UnimplementedError();
  }
}
