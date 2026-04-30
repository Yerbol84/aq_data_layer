import 'dart:async';
import 'package:aq_schema/aq_schema.dart';
import 'remote_vault_storage.dart';

/// Remote implementation of [LoggedRepository].
///
/// Тонкий клиент — только типизированные команды/запросы через [RemoteVaultStorage].
/// Не знает о SQL, не знает о _log таблицах, не содержит бизнес-логики.
/// Бизнес-логика живёт на сервере в [LoggedRepositoryImpl].
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

  // ── Write ──────────────────────────────────────────────────────────────────

  @override
  Future<void> save(T entity, {required String actorId}) =>
      _storage.rpc(_collection, 'put', {
        'data': entity.toMap(),
        'actorId': actorId,
      });

  @override
  Future<void> delete(String entityId, {required String actorId}) =>
      _storage.rpc(_collection, 'delete', {
        'id': entityId,
        'actorId': actorId,
      });

  @override
  Future<void> restore(String entityId, {required String actorId}) =>
      _storage.rpc(_collection, 'restore', {
        'id': entityId,
        'actorId': actorId,
      });

  @override
  Future<void> rollbackTo(
    String entityId,
    String entryId, {
    required String actorId,
  }) =>
      _storage.sendCommand(
        _collection,
        RollbackToCommand(
          entityId: entityId,
          entryId: entryId,
          actorId: actorId,
        ),
      );

  // ── Read ───────────────────────────────────────────────────────────────────

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
    return (res as List? ?? [])
        .map((e) => _fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  @override
  Future<List<T>> findAllIncludingDeleted({VaultQuery? query}) async {
    final res = await _storage.rpc(_collection, 'queryIncludingDeleted', {
      if (query != null) 'query': _serializeQuery(query),
    });
    return (res as List? ?? [])
        .map((e) => _fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  @override
  Future<PageResult<T>> findPage(VaultQuery query) async {
    final res = await _storage.rpc(_collection, 'queryPage', {
      'query': _serializeQuery(query),
    }) as Map<String, dynamic>;
    return PageResult(
      items: (res['items'] as List)
          .map((e) => _fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
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

  // ── History ────────────────────────────────────────────────────────────────

  @override
  Future<List<LogEntry>> getHistory(String entityId) =>
      _storage.sendQuery(_collection, GetHistoryQuery(entityId)).then(
            (res) => (res as List? ?? [])
                .map((e) => LogEntry.fromMap(Map<String, dynamic>.from(e as Map)))
                .toList(),
          );

  @override
  Future<List<LogEntry>> queryHistory(String entityId, VaultQuery query) async {
    final res = await _storage.rpc(_collection, 'queryHistory', {
      'entityId': entityId,
      'query': _serializeQuery(query),
    });
    return (res as List? ?? [])
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
    return PageResult(
      items: (res['items'] as List)
          .map((e) => LogEntry.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
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
  Future<List<LogEntry>> getCollectionLog({DateTime? from, DateTime? to}) async {
    final res = await _storage.rpc(_collection, 'getCollectionLog', {
      if (from != null) 'from': from.toIso8601String(),
      if (to != null) 'to': to.toIso8601String(),
    });
    return (res as List? ?? [])
        .map((e) => LogEntry.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  // ── Indexes ────────────────────────────────────────────────────────────────

  @override
  Future<void> registerIndex(VaultIndex index) =>
      _storage.rpc(_collection, 'createIndex', {
        'name': index.name,
        'field': index.field,
        'unique': index.unique,
      });

  // ── Streams ────────────────────────────────────────────────────────────────

  @override
  Stream<List<LogEntry>> watchHistory(String entityId) =>
      throw UnimplementedError('watchHistory not yet implemented for remote');

  @override
  Stream<List<T>> watchAll({VaultQuery? query}) =>
      throw UnimplementedError('watchAll not yet implemented for remote');

  // ── Private ────────────────────────────────────────────────────────────────

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
}
