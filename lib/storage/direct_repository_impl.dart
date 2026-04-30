import 'dart:async';
import 'package:aq_schema/aq_schema.dart';

import '../exceptions/vault_exceptions.dart';

// ── Watch-stream helper ────────────────────────────────────────────────────────
//
// Problem: async* generators have a race window between the initial
// `yield await findAll()` and the `await for` loop.  If a storage
// notification fires during that window (broadcast streams don't buffer),
// the event is silently dropped.
//
// Fix: subscribe to the raw changes stream FIRST and buffer notifications
// in a local StreamController.  The generator drains that buffer after
// the initial snapshot, so no events are ever lost.
// Exported so ArtifactRepositoryImpl and KnowledgeRepositoryImpl can reuse it.
Stream<List<T>> watchWithBuffer<T>(
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

/// Default implementation of [DirectRepository] backed by [VaultStorage].
final class DirectRepositoryImpl<T extends DirectStorable>
    implements DirectRepository<T> {
  final VaultStorage _storage;
  final String _collection;
  final T Function(Map<String, dynamic>) _fromMap;

  DirectRepositoryImpl({
    required VaultStorage storage,
    required String collection,
    required T Function(Map<String, dynamic>) fromMap,
  })  : _storage = storage,
        _collection = collection,
        _fromMap = fromMap;

  Future<void> _ensureCollection() => _storage.ensureCollection(_collection);

  // ── Write ──────────────────────────────────────────────────────────────────

  @override
  Future<void> save(T entity) async {
    await _ensureCollection();
    await _storage.put(_collection, entity.id, entity.toMap());
    if (entity.indexFields.isNotEmpty) {
      await _storage.updateIndex(_collection, entity.id, entity.indexFields);
    }
  }

  @override
  Future<void> saveAll(List<T> entities) async {
    await _ensureCollection();
    final entries = {
      for (final e in entities) e.id: e.toMap(),
    };
    await _storage.putAll(_collection, entries);
    for (final e in entities) {
      if (e.indexFields.isNotEmpty) {
        await _storage.updateIndex(_collection, e.id, e.indexFields);
      }
    }
  }

  @override
  Future<void> delete(String id) async {
    final entity = await findById(id);
    if (entity == null) return;

    if (entity.softDelete) {
      // SOFT DELETE: Mark as deleted
      final map = entity.toMap();
      map['deletedAt'] = DateTime.now().toIso8601String();
      await _storage.put(_collection, id, map);

      // Log to deleted table
      await _logDeletion(entity, deleteType: 'soft', actorId: 'system');
    } else {
      // HARD DELETE: Remove from DB
      await _logDeletion(entity, deleteType: 'hard', actorId: 'system');
      await _storage.delete(_collection, id);
    }
  }

  @override
  Future<void> restore(String id) async {
    // Query including deleted to find the entity
    final data = await _storage.get(_collection, id);
    if (data == null) {
      throw VaultNotFoundException('Entity $id not found in $_collection');
    }

    final entity = _fromMap(data);
    if (!entity.softDelete) {
      throw VaultStateException(
        'Cannot restore entity $id: softDelete is disabled for this model',
      );
    }

    // Clear deletedAt field
    final map = entity.toMap();
    map['deletedAt'] = null;
    await _storage.put(_collection, id, map);
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
    await _ensureCollection();

    // Exclude soft-deleted records by default
    var q = query ?? const VaultQuery();
    q = q.where('deletedAt', VaultOperator.isNull, null);

    final rows = await _storage.query(_collection, q);
    return rows.map(_fromMap).toList();
  }

  @override
  Future<List<T>> findAllIncludingDeleted({VaultQuery? query}) async {
    await _ensureCollection();
    final rows = await _storage.query(_collection, query ?? const VaultQuery());
    return rows.map(_fromMap).toList();
  }

  @override
  Future<bool> exists(String id) => _storage.exists(_collection, id);

  @override
  Future<int> count({VaultQuery? query}) =>
      _storage.count(_collection, query ?? const VaultQuery());

  // ── Pagination ─────────────────────────────────────────────────────────────

  @override
  Future<PageResult<T>> findPage(VaultQuery query) async {
    await _ensureCollection();
    final page = await _storage.queryPage(_collection, query);
    return page.map(_fromMap);
  }

  // ── Indexes ────────────────────────────────────────────────────────────────

  @override
  Future<void> registerIndex(VaultIndex index) =>
      _storage.createIndex(_collection, index);

  // ── Streams ────────────────────────────────────────────────────────────────

  @override
  Stream<List<T>> watchAll({VaultQuery? query}) => watchWithBuffer<T>(
        _storage.watchChanges(_collection),
        () => findAll(query: query),
      );
}
