import 'dart:async';

import 'package:aq_schema/aq_schema.dart';
import 'package:meta/meta.dart';

import '../storage/local_buffer_vault_storage.dart';
import '../exceptions/vault_exceptions.dart';

// ── Watch-stream race-condition fix (see direct_repository_impl.dart) ──────────
Stream<List<T>> _watchWithBuffer<T>(
  Stream<void> rawChanges,
  Future<List<T>> Function() load,
) async* {
  final buffer = StreamController<void>();
  final sub = rawChanges.listen((_) {
    if (!buffer.isClosed) buffer.add(null);
  });
  try {
    yield await load();
    await for (final _ in buffer.stream) {
      yield await load();
    }
  } finally {
    await sub.cancel();
    await buffer.close();
  }
}

/// Default implementation of [LoggedRepository] backed by [VaultStorage].
///
/// Two internal collections:
/// - `{collection}`       — current entity state
/// - `{collection}_log`  — [LogEntry] records (append-only)
@internal
final class LoggedRepositoryImpl<T extends LoggedStorable>
    implements LoggedRepository<T> {
  final VaultStorage _storage;
  final String _collection;
  final String _logCollection;
  final T Function(Map<String, dynamic>) _fromMap;
  final bool _captureFullSnapshot;

  int _rngState = 0;

  LoggedRepositoryImpl({
    required VaultStorage storage,
    required String collection,
    required T Function(Map<String, dynamic>) fromMap,
    bool captureFullSnapshot = false,
  })  : _storage = storage,
        _collection = collection,
        _logCollection = '${collection}_log',
        _fromMap = fromMap,
        _captureFullSnapshot = captureFullSnapshot;

  Future<void> _ensureCollections() async {
    await _storage.ensureCollection(_collection);
    await _storage.ensureCollection(_logCollection);
  }

  // ── Write ──────────────────────────────────────────────────────────────────

  @override
  Future<void> save(T entity, {required String actorId}) async {
    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    if (baseStorage is ProxyStorage) {
      // Remote: вызываем RPC напрямую, сервер создаст log entry
      await (baseStorage as dynamic).rpc(
        _collection,
        'put',
        {
          'data': entity.toMap(),
          'actorId': actorId,
        },
      );
    } else {
      // Local: создаём log entry вручную
      await _ensureCollections();

      final existing = await _storage.get(_collection, entity.id);
      final operation =
          existing == null ? LogOperation.created : LogOperation.updated;

      await _storage.put(_collection, entity.id, entity.toMap());

      if (entity.indexFields.isNotEmpty) {
        await _storage.updateIndex(_collection, entity.id, entity.indexFields);
      }

      final diff = _computeDiff(
        existing,
        entity.toMap(),
        trackedFields:
            entity.trackedFields.isEmpty ? null : entity.trackedFields,
      );

      final entry = LogEntry(
        entryId: _uuid(),
        entityId: entity.id,
        collectionId: _collection,
        changedBy: actorId,
        changedAt: DateTime.now(),
        operation: operation,
        diff: diff,
        snapshot: _captureFullSnapshot ? Map.from(entity.toMap()) : null,
      );

      await _storage.put(_logCollection, entry.entryId, entry.toMap());
    }
  }

  @override
  Future<void> delete(String entityId, {required String actorId}) async {
    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    if (baseStorage is ProxyStorage) {
      // Remote: server handles soft/hard delete logic
      await (baseStorage as dynamic).rpc(
        _collection,
        'delete',
        {
          'id': entityId,
          'actorId': actorId,
        },
      );
    } else {
      // Local: handle soft/hard delete
      await _ensureCollections();

      final existing = await _storage.get(_collection, entityId);
      if (existing == null) return;

      final entity = _fromMap(existing);

      if (entity.softDelete) {
        // SOFT DELETE: Mark as deleted
        final map = entity.toMap();
        map['deletedAt'] = DateTime.now().toIso8601String();
        await _storage.put(_collection, entityId, map);

        // Create log entry for soft delete
        final entry = LogEntry(
          entryId: _uuid(),
          entityId: entityId,
          collectionId: _collection,
          changedBy: actorId,
          changedAt: DateTime.now(),
          operation: LogOperation.updated,
          diff: {
            'deletedAt': FieldDiff(before: null, after: map['deletedAt'])
          },
          snapshot: null,
        );
        await _storage.put(_logCollection, entry.entryId, entry.toMap());

        // Log to deleted table
        await _logDeletion(entity, deleteType: 'soft', actorId: actorId);
      } else {
        // HARD DELETE: Remove from DB
        await _logDeletion(entity, deleteType: 'hard', actorId: actorId);
        await _storage.delete(_collection, entityId);

        // Create log entry for hard delete
        final entry = LogEntry(
          entryId: _uuid(),
          entityId: entityId,
          collectionId: _collection,
          changedBy: actorId,
          changedAt: DateTime.now(),
          operation: LogOperation.deleted,
          diff: _computeDiff(existing, null),
          snapshot: null,
        );
        await _storage.put(_logCollection, entry.entryId, entry.toMap());
      }
    }
  }

  @override
  Future<void> restore(String entityId, {required String actorId}) async {
    await _ensureCollections();

    final data = await _storage.get(_collection, entityId);
    if (data == null) {
      throw VaultNotFoundException('Entity $entityId not found in $_collection');
    }

    final entity = _fromMap(data);
    if (!entity.softDelete) {
      throw VaultStateException(
        'Cannot restore entity $entityId: softDelete is disabled for this model',
      );
    }

    // Clear deletedAt field
    final map = entity.toMap();
    final oldDeletedAt = map['deletedAt'];
    map['deletedAt'] = null;
    await _storage.put(_collection, entityId, map);

    // Create log entry for restore
    final entry = LogEntry(
      entryId: _uuid(),
      entityId: entityId,
      collectionId: _collection,
      changedBy: actorId,
      changedAt: DateTime.now(),
      operation: LogOperation.updated,
      diff: {
        'deletedAt': FieldDiff(before: oldDeletedAt, after: null)
      },
      snapshot: null,
    );
    await _storage.put(_logCollection, entry.entryId, entry.toMap());
  }

  Future<void> _logDeletion(
    T entity, {
    required String deleteType,
    required String actorId,
  }) async {
    final deletedCollection = '${_collection}_deleted';
    await _storage.ensureCollection(deletedCollection);

    final log = {
      'id': entity.id,
      'tenant_id': _getTenantId(entity),
      'data': entity.toMap(),
      'deleted_at': DateTime.now().toIso8601String(),
      'deleted_by': actorId,
      'delete_type': deleteType,
    };

    await _storage.put(deletedCollection, entity.id, log);
  }

  String _getTenantId(T entity) {
    final map = entity.toMap();
    return map['tenantId'] as String? ?? 'system';
  }

  // ── Read ───────────────────────────────────────────────────────────────────

  @override
  Future<T?> findById(String id) async {
    final data = await _storage.get(_collection, id);
    return data != null ? _fromMap(data) : null;
  }

  @override
  Future<List<T>> findAll({VaultQuery? query}) async {
    await _ensureCollections();

    // Exclude soft-deleted records by default
    var q = query ?? const VaultQuery();
    q = q.where('deletedAt', VaultOperator.isNull, null);

    final rows = await _storage.query(_collection, q);
    return rows.map(_fromMap).toList();
  }

  @override
  Future<List<T>> findAllIncludingDeleted({VaultQuery? query}) async {
    await _ensureCollections();
    final rows = await _storage.query(_collection, query ?? const VaultQuery());
    return rows.map(_fromMap).toList();
  }

  @override
  Future<PageResult<T>> findPage(VaultQuery query) async {
    await _ensureCollections();
    final page = await _storage.queryPage(_collection, query);
    return page.map(_fromMap);
  }

  @override
  Future<bool> exists(String id) => _storage.exists(_collection, id);

  @override
  Future<int> count({VaultQuery? query}) =>
      _storage.count(_collection, query ?? const VaultQuery());

  // ── History ────────────────────────────────────────────────────────────────

  @override
  Future<List<LogEntry>> getHistory(String entityId) async {
    final rows = await _storage.query(
      _logCollection,
      VaultQuery()
          .where('entityId', VaultOperator.equals, entityId)
          .orderBy('changedAt'),
    );
    return rows.map(LogEntry.fromMap).toList();
  }

  @override
  Future<List<LogEntry>> queryHistory(
    String entityId,
    VaultQuery query,
  ) async {
    final history = await getHistory(entityId);
    final maps = history.map((e) => e.toMap()).toList();
    return query.apply(maps).map(LogEntry.fromMap).toList();
  }

  @override
  Future<PageResult<LogEntry>> getHistoryPage(
    String entityId,
    VaultQuery query,
  ) async {
    final history = await getHistory(entityId);
    final maps = history.map((e) => e.toMap()).toList();
    final filtered = query.applyFiltersOnly(maps);
    final total = filtered.length;
    final paged = query.apply(maps);
    return PageResult(
      items: paged.map(LogEntry.fromMap).toList(),
      total: total,
      offset: query.offset ?? 0,
      limit: query.limit ?? total,
    );
  }

  @override
  Future<T?> getStateAt(String entityId, DateTime moment) async {
    final history = await getHistory(entityId);
    Map<String, dynamic>? state;

    for (final entry in history) {
      if (entry.changedAt.isAfter(moment)) break;
      if (entry.operation == LogOperation.deleted) {
        state = null;
      } else if (entry.snapshot != null) {
        state = Map<String, dynamic>.from(entry.snapshot!);
      } else {
        state ??= {};
        for (final diffEntry in entry.diff.entries) {
          state[diffEntry.key] = diffEntry.value.after;
        }
      }
    }

    return state != null ? _fromMap(state) : null;
  }

  @override
  Future<LogEntry?> getLastEntry(String entityId) async {
    final history = await getHistory(entityId);
    return history.isEmpty ? null : history.last;
  }

  @override
  Future<List<LogEntry>> getCollectionLog({
    DateTime? from,
    DateTime? to,
  }) async {
    var q = const VaultQuery().orderBy('changedAt');
    if (from != null) {
      q = q.where(
          'changedAt', VaultOperator.greaterOrEqual, from.toIso8601String());
    }
    if (to != null) {
      q = q.where('changedAt', VaultOperator.lessOrEqual, to.toIso8601String());
    }
    final rows = await _storage.query(_logCollection, q);
    return rows.map(LogEntry.fromMap).toList();
  }

  // ── Rollback ───────────────────────────────────────────────────────────────

  @override
  Future<void> rollbackTo(
    String entityId,
    String entryId, {
    required String actorId,
  }) async {
    await _ensureCollections();

    final targetEntry = await _getEntryOrThrow(entryId, entityId);

    Map<String, dynamic> restoredData;
    if (targetEntry.snapshot != null) {
      restoredData = Map<String, dynamic>.from(targetEntry.snapshot!);
    } else {
      final reconstructed = await getStateAt(entityId, targetEntry.changedAt);
      if (reconstructed == null) {
        throw VaultStateException(
          'Cannot reconstruct state for entry $entryId — '
          'no snapshot available and history is incomplete.',
        );
      }
      restoredData = reconstructed.toMap();
    }

    final currentData = await _storage.get(_collection, entityId);
    await _storage.put(_collection, entityId, restoredData);

    final diff = _computeDiff(currentData, restoredData);
    final rollbackEntry = LogEntry(
      entryId: _uuid(),
      entityId: entityId,
      collectionId: _collection,
      changedBy: actorId,
      changedAt: DateTime.now(),
      operation: LogOperation.rollback,
      diff: diff,
      snapshot: _captureFullSnapshot ? Map.from(restoredData) : null,
      rollbackToEntryId: entryId,
    );

    await _storage.put(
        _logCollection, rollbackEntry.entryId, rollbackEntry.toMap());
  }

  // ── Indexes ────────────────────────────────────────────────────────────────

  @override
  Future<void> registerIndex(VaultIndex index) =>
      _storage.createIndex(_collection, index);

  // ── Streams ────────────────────────────────────────────────────────────────

  @override
  Stream<List<LogEntry>> watchHistory(String entityId) =>
      _watchWithBuffer<LogEntry>(
        _storage.watchChanges(_logCollection),
        () => getHistory(entityId),
      );

  @override
  Stream<List<T>> watchAll({VaultQuery? query}) => _watchWithBuffer<T>(
        _storage.watchChanges(_collection),
        () => findAll(query: query),
      );

  // ── Private helpers ────────────────────────────────────────────────────────

  Map<String, FieldDiff> _computeDiff(
    Map<String, dynamic>? before,
    Map<String, dynamic>? after, {
    Set<String>? trackedFields,
  }) {
    final diff = <String, FieldDiff>{};
    final allKeys = <String>{...?before?.keys, ...?after?.keys};

    for (final key in allKeys) {
      if (trackedFields != null &&
          trackedFields.isNotEmpty &&
          !trackedFields.contains(key)) continue;

      final bv = before?[key];
      final av = after?[key];
      if (_equal(bv, av)) continue;
      diff[key] = FieldDiff(before: bv, after: av);
    }
    return diff;
  }

  bool _equal(dynamic a, dynamic b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!_equal(a[k], b[k])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_equal(a[i], b[i])) return false;
      }
      return true;
    }
    // ✅ Compare string representations — NOT .toString() on arbitrary objects
    return a.toString() == b.toString();
  }

  Future<LogEntry> _getEntryOrThrow(String entryId, String entityId) async {
    final data = await _storage.get(_logCollection, entryId);
    if (data == null) {
      throw VaultNotFoundException('Log entry $entryId not found');
    }
    final entry = LogEntry.fromMap(data);
    if (entry.entityId != entityId) {
      throw VaultNotFoundException(
        'Log entry $entryId does not belong to entity $entityId',
      );
    }
    return entry;
  }

  String _uuid() {
    final now = DateTime.now().microsecondsSinceEpoch;
    _rngState = (_rngState * 6364136223846793005 + 1442695040888963407) &
        0x7FFFFFFFFFFFFFFF;
    return '${now.toRadixString(16)}-log-${_rngState.toRadixString(16).padLeft(8, '0')}';
  }
}
