import 'dart:async';
import 'dart:convert';

import 'package:aq_schema/aq_schema.dart';

/// In-memory [VaultStorage] implementation.
///
/// - Zero external dependencies.
/// - Correct JSON serialisation via [jsonEncode] / [jsonDecode].
/// - Working indexes with uniqueness enforcement.
/// - Pagination via [VaultQuery.limit] / [VaultQuery.offset].
/// - Reactive: [watchChanges] emits on every write.
/// - Multi-tenant: фильтрация по tenantId без префикса коллекций.
///
/// **Not** suitable for production persistence — data is lost on process exit.
/// Use as a drop-in for tests and demos, or replace with [PostgresVaultStorage].
final class InMemoryVaultStorage implements VaultStorage {
  // collection → { id → _InMemoryRecord }
  final _store = <String, Map<String, _InMemoryRecord>>{};

  // collection → { indexName → { fieldValue → Set<id> } }
  final _indexes = <String, Map<String, Map<String, Set<String>>>>{};

  // collection → VaultIndex definitions (for uniqueness checks)
  final _indexDefs = <String, Map<String, VaultIndex>>{};

  // change notification streams
  final _controllers = <String, StreamController<void>>{};

  /// Tenant ID для изоляции данных.
  /// Все операции фильтруются по этому tenantId.
  final String tenantId;

  InMemoryVaultStorage({this.tenantId = 'system'});

  // ── Collections ────────────────────────────────────────────────────────────

  @override
  Future<void> ensureCollection(String collection) async {
    _store.putIfAbsent(collection, () => {});
    _indexes.putIfAbsent(collection, () => {});
    _indexDefs.putIfAbsent(collection, () => {});
    _controllers.putIfAbsent(
      collection,
      () => StreamController<void>.broadcast(),
    );
  }

  // ── CRUD ───────────────────────────────────────────────────────────────────

  @override
  Future<void> put(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    await ensureCollection(collection);
    _store[collection]![id] = _InMemoryRecord(
      tenantId: tenantId,
      jsonData: jsonEncode(data),
    );
    await _rebuildIndexesForRecord(collection, id, data);
    _notify(collection);
  }

  @override
  Future<Map<String, dynamic>?> get(String collection, String id) async {
    final record = _store[collection]?[id];
    if (record == null || record.tenantId != tenantId) return null;
    return record.data;
  }

  @override
  Future<void> delete(String collection, String id) async {
    final record = _store[collection]?[id];
    if (record?.tenantId == tenantId) {
      _store[collection]?.remove(id);
      await removeFromIndex(collection, id);
      _notify(collection);
    }
  }

  @override
  Future<bool> exists(String collection, String id) async {
    final record = _store[collection]?[id];
    return record != null && record.tenantId == tenantId;
  }

  @override
  Future<void> putAll(
    String collection,
    Map<String, Map<String, dynamic>> entries,
  ) async {
    await ensureCollection(collection);
    for (final e in entries.entries) {
      _store[collection]![e.key] = _InMemoryRecord(
        tenantId: tenantId,
        jsonData: jsonEncode(e.value),
      );
      await _rebuildIndexesForRecord(collection, e.key, e.value);
    }
    _notify(collection);
  }

  // ── Queries ────────────────────────────────────────────────────────────────

  @override
  Future<List<Map<String, dynamic>>> query(
    String collection,
    VaultQuery q,
  ) async {
    final all = _allRecords(collection);
    return q.apply(all);
  }

  @override
  Future<PageResult<Map<String, dynamic>>> queryPage(
    String collection,
    VaultQuery q,
  ) async {
    final all = _allRecords(collection);
    final filtered = q.applyFiltersOnly(all);
    final total = filtered.length;

    // Apply sort + pagination
    final paged = q.apply(all);

    return PageResult(
      items: paged,
      total: total,
      offset: q.offset ?? 0,
      limit: q.limit ?? total,
    );
  }

  @override
  Future<int> count(String collection, VaultQuery q) async {
    final all = _allRecords(collection);
    return q.applyFiltersOnly(all).length;
  }

  // ── Indexes ────────────────────────────────────────────────────────────────

  @override
  Future<void> createIndex(String collection, VaultIndex index) async {
    await ensureCollection(collection);
    _indexDefs[collection]![index.name] = index;
    _indexes[collection]!.putIfAbsent(index.name, () => {});

    // Backfill existing records (только для текущего тенанта).
    final records = _store[collection]!;
    for (final entry in records.entries) {
      if (entry.value.tenantId != tenantId) continue;
      final data = entry.value.data;
      final fieldVal = data[index.field]?.toString();
      if (fieldVal != null) {
        _indexes[collection]![index.name]!
            .putIfAbsent(fieldVal, () => {})
            .add(entry.key);
      }
    }
  }

  @override
  Future<void> updateIndex(
    String collection,
    String id,
    Map<String, dynamic> indexData,
  ) async {
    final defs = _indexDefs[collection] ?? {};
    for (final def in defs.values) {
      final val = indexData[def.field]?.toString();
      if (val == null) continue;

      // Uniqueness check
      if (def.unique) {
        final existing = _indexes[collection]?[def.name]?[val];
        if (existing != null && existing.isNotEmpty && !existing.contains(id)) {
          throw StateError(
            'Unique index "${def.name}" violated: '
            'field "${def.field}" = "$val" already exists',
          );
        }
      }

      _indexes[collection]!
          .putIfAbsent(def.name, () => {})
          .putIfAbsent(val, () => {})
          .add(id);
    }
  }

  @override
  Future<void> removeFromIndex(String collection, String id) async {
    final colIdx = _indexes[collection];
    if (colIdx == null) return;
    for (final idx in colIdx.values) {
      for (final set in idx.values) {
        set.remove(id);
      }
    }
  }

  // ── Transactions ───────────────────────────────────────────────────────────

  @override
  Future<T> transaction<T>(Future<T> Function(VaultStorage tx) action) async {
    // In-memory: single-threaded Dart — run directly.
    // For true ACID semantics, use a backend that supports transactions.
    return action(this);
  }

  // ── Reactivity ─────────────────────────────────────────────────────────────

  @override
  Stream<void> watchChanges(String collection) {
    _controllers.putIfAbsent(
      collection,
      () => StreamController<void>.broadcast(),
    );
    return _controllers[collection]!.stream;
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> clear(String collection) async {
    _store[collection]?.removeWhere((_, record) => record.tenantId == tenantId);
    // Очистить индексы только для записей текущего тенанта
    final colIdx = _indexes[collection];
    if (colIdx != null) {
      for (final idx in colIdx.values) {
        for (final set in idx.values) {
          set.removeWhere((id) {
            final record = _store[collection]?[id];
            return record?.tenantId == tenantId;
          });
        }
      }
    }
    _notify(collection);
  }

  @override
  Future<void> dispose() async {
    for (final ctrl in _controllers.values) {
      await ctrl.close();
    }
    _controllers.clear();
    _store.clear();
    _indexes.clear();
    _indexDefs.clear();
  }

  // ── Private ────────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> _allRecords(String collection) {
    final raw = _store[collection];
    if (raw == null) return [];
    return raw.values
        .where((record) => record.tenantId == tenantId)
        .map((record) => record.data)
        .toList();
  }

  Future<void> _rebuildIndexesForRecord(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    final defs = _indexDefs[collection];
    if (defs == null || defs.isEmpty) return;
    await updateIndex(collection, id, data);
  }

  void _notify(String collection) {
    _controllers[collection]?.add(null);
  }
}

/// Внутренняя запись в InMemoryVaultStorage с tenant-изоляцией.
class _InMemoryRecord {
  final String tenantId;
  final String jsonData;

  const _InMemoryRecord({
    required this.tenantId,
    required this.jsonData,
  });

  Map<String, dynamic> get data =>
      Map<String, dynamic>.from(jsonDecode(jsonData) as Map);
}
