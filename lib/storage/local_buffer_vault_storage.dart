// pkgs/dart_vault_package/lib/storage/local_buffer_vault_storage.dart
//
// Реализация IBufferedStorage.
// Оборачивает любое VaultStorage (обычно RemoteVaultStorage).
// Под капотом использует InMemoryVaultStorage как рабочий буфер.
library;

import 'dart:async';
import 'package:aq_schema/aq_schema.dart';
import 'package:meta/meta.dart';
import 'in_memory_vault_storage.dart';

/// Локальный рабочий буфер поверх любого [VaultStorage].
///
/// ## Архитектура
///
/// ```
/// LocalBufferVaultStorage
///   ├── _buffer: InMemoryVaultStorage   ← все чтения/записи идут сюда
///   │     Хранит данные + ключ _ls (VaultRecordState.name)
///   ├── _remote: VaultStorage           ← источник истины
///   ├── _dirty: Map<col, Set<id>>       ← dirty/localOnly IDs
///   └── _originals: Map<col,Map<id,Map>>← копия до изменений
/// ```
///
/// ## Чтение
/// 1. Есть в буфере → вернуть (мгновенно, без сети).
/// 2. Нет → запросить из remote, положить в буфер как synced.
///
/// ## Запись (put/delete)
/// 1. Если не в буфере → сохранить оригинал из remote (если есть).
/// 2. Записать в буфер с _ls = dirty/localOnly.
/// 3. НЕ писать в remote.
///
/// ## flush → пишет dirty/localOnly в remote.
/// ## discard → восстанавливает из remote/originals.
///
/// ## Запросы (query)
/// Remote запрос + override из буфера по dirty ID.
/// Новые localOnly записи добавляются поверх remote результата.
@internal
final class LocalBufferVaultStorage implements IBufferedStorage {
  final VaultStorage _remote;
  final InMemoryVaultStorage _buffer = InMemoryVaultStorage();

  // collection → Set<id> — все ID с локальными изменениями
  final _dirty = <String, Set<String>>{};

  // collection → id → оригинальные данные до изменений (без _ls)
  final _originals = <String, Map<String, Map<String, dynamic>>>{};

  LocalBufferVaultStorage(this._remote);

  /// Доступ к базовому удалённому хранилищу (для RemoteLoggedRepository).
  VaultStorage get remote => _remote;

  // ══════════════════════════════════════════════════════════════════════════
  // IBufferedStorage — состояние
  // ══════════════════════════════════════════════════════════════════════════

  @override
  bool isDirty(String collection, String id) =>
      _dirty[collection]?.contains(id) ?? false;

  @override
  VaultRecordState? stateOf(String collection, String id) {
    // Проверяем буфер напрямую (синхронно через внутреннюю карту)
    final dirtySet = _dirty[collection];
    if (dirtySet == null || !dirtySet.contains(id)) {
      // Если есть в буфере но не dirty — synced
      // Проверяем через кэш буфера — InMemoryVaultStorage хранит в _store
      // Используем has через exists (async), но для синхронного stateOf
      // проверяем внутренний dirty set
      return null; // не в dirty — либо synced (из сети) либо отсутствует
    }
    final hasOriginal = _originals[collection]?.containsKey(id) ?? false;
    return hasOriginal ? VaultRecordState.dirty : VaultRecordState.localOnly;
  }

  @override
  Set<String> dirtyIds(String collection) =>
      Set.unmodifiable(_dirty[collection] ?? {});

  @override
  Map<String, dynamic>? getOriginal(String collection, String id) =>
      _originals[collection]?[id];

  // ══════════════════════════════════════════════════════════════════════════
  // IBufferedStorage — команды
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Future<void> flush(String collection, {String? id}) async {
    final ids = id != null ? {id} : Set<String>.from(_dirty[collection] ?? {});
    if (ids.isEmpty) return;

    for (final recordId in ids) {
      final localData = await _buffer.get(collection, recordId);
      if (localData == null) continue;

      // Убрать _ls перед отправкой в remote
      final clean = _stripMeta(localData);
      final state = _stateFromMap(localData);

      if (state == VaultRecordState.dirty ||
          state == VaultRecordState.localOnly) {
        await _remote.put(collection, recordId, clean);
      }

      // После flush: запись становится synced
      await _buffer.put(
          collection, recordId, _withState(clean, VaultRecordState.synced));
      _dirty[collection]?.remove(recordId);
      _originals[collection]?.remove(recordId);
    }
  }

  @override
  Future<void> discard(String collection, {String? id}) async {
    final ids = id != null ? {id} : Set<String>.from(_dirty[collection] ?? {});
    if (ids.isEmpty) return;

    for (final recordId in ids) {
      final original = _originals[collection]?[recordId];
      if (original != null) {
        // Восстановить оригинал из сохранённой копии
        await _buffer.put(collection, recordId,
            _withState(original, VaultRecordState.synced));
      } else {
        // localOnly — записи не было в remote, просто удаляем из буфера
        await _buffer.delete(collection, recordId);
      }
      _dirty[collection]?.remove(recordId);
      _originals[collection]?.remove(recordId);
    }
  }

  @override
  Future<void> warmup(String collection, String id) async {
    if (await _buffer.exists(collection, id)) return; // уже в буфере
    final remote = await _remote.get(collection, id);
    if (remote != null) {
      await _buffer.ensureCollection(collection);
      await _buffer.put(
          collection, id, _withState(remote, VaultRecordState.synced));
    }
  }

  @override
  Future<void> warmupAll(String collection, {VaultQuery? query}) async {
    await _buffer.ensureCollection(collection);
    final records =
        await _remote.query(collection, query ?? const VaultQuery());
    for (final record in records) {
      final id = record['id'] as String? ?? record['nodeId'] as String?;
      if (id == null) continue;
      if (!await _buffer.exists(collection, id)) {
        await _buffer.put(
            collection, id, _withState(record, VaultRecordState.synced));
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // VaultStorage — основные операции
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Future<void> ensureCollection(String collection) async {
    await _buffer.ensureCollection(collection);
    await _remote.ensureCollection(collection);
    _dirty.putIfAbsent(collection, () => {});
    _originals.putIfAbsent(collection, () => {});
  }

  @override
  Future<void> put(
      String collection, String id, Map<String, dynamic> data) async {
    await _ensureLocal(collection);

    // Сохранить оригинал если запись ещё не менялась
    if (!isDirty(collection, id)) {
      final existing = await _fetchFromBuffer(collection, id) ??
          await _fetchFromRemote(collection, id);
      if (existing != null) {
        _originals.putIfAbsent(collection, () => {})[id] = _stripMeta(existing);
      }
    }

    // Определить состояние
    final hasOriginal = _originals[collection]?.containsKey(id) ?? false;
    final state =
        hasOriginal ? VaultRecordState.dirty : VaultRecordState.localOnly;

    await _buffer.put(collection, id, _withState(data, state));
    _dirty.putIfAbsent(collection, () => {}).add(id);
  }

  @override
  Future<Map<String, dynamic>?> get(String collection, String id) async {
    // Буфер первым
    final buffered = await _fetchFromBuffer(collection, id);
    if (buffered != null) return buffered;

    // Remote → кэшировать в буфер как synced
    final remote = await _fetchFromRemote(collection, id);
    if (remote != null) {
      await _ensureLocal(collection);
      await _buffer.put(
          collection, id, _withState(remote, VaultRecordState.synced));
    }
    return remote;
  }

  @override
  Future<void> delete(String collection, String id) async {
    await _ensureLocal(collection);

    // Сохранить оригинал перед удалением если не менялась
    if (!isDirty(collection, id)) {
      final existing = await _fetchFromBuffer(collection, id) ??
          await _fetchFromRemote(collection, id);
      if (existing != null) {
        _originals.putIfAbsent(collection, () => {})[id] = _stripMeta(existing);
      }
    }

    // Пометить как dirty-deleted в буфере (храним маркер удаления)
    final marker =
        _withState({'id': id, '_deleted': true}, VaultRecordState.dirty);
    await _buffer.put(collection, id, marker);
    _dirty.putIfAbsent(collection, () => {}).add(id);
    // Уведомление придёт от buffer через watchChanges
  }

  @override
  Future<bool> exists(String collection, String id) async {
    if (await _buffer.exists(collection, id)) {
      final d = await _fetchFromBuffer(collection, id);
      if (d != null && d['_deleted'] == true) return false;
      return true;
    }
    return _remote.exists(collection, id);
  }

  @override
  Future<void> putAll(
      String collection, Map<String, Map<String, dynamic>> entries) async {
    for (final e in entries.entries) {
      await put(collection, e.key, e.value);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // VaultStorage — запросы (merge remote + local overrides)
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Future<List<Map<String, dynamic>>> query(
      String collection, VaultQuery q) async {
    // Получить из remote
    final remoteRows = await _remote.query(collection, q);

    // Перекрыть dirty ID из буфера
    final dirtySet = _dirty[collection] ?? {};
    if (dirtySet.isEmpty) {
      // Добавить _ls: synced ко всем remote результатам
      return remoteRows
          .map((r) => _withState(r, VaultRecordState.synced))
          .toList();
    }

    // Построить результирующий список
    final byId = <String, Map<String, dynamic>>{};
    for (final row in remoteRows) {
      final id = _idOf(row);
      if (id != null) byId[id] = _withState(row, VaultRecordState.synced);
    }

    // Перекрыть/добавить dirty записи из буфера
    for (final id in dirtySet) {
      final local = await _fetchFromBuffer(collection, id);
      if (local == null) continue;
      if (local['_deleted'] == true) {
        byId.remove(id); // удалённые локально убрать из результата
      } else {
        byId[id] = local; // _ls уже стоит dirty/localOnly
      }
    }

    // Применить сортировку/фильтр в памяти через VaultQuery
    // (remote уже отфильтровал, нам важно только применить к merged)
    final merged = byId.values.toList();
    return q.apply(merged.map(_stripMeta).toList()).map((r) {
      final id = _idOf(r);
      final local = id != null ? byId[id] : null;
      return local ?? _withState(r, VaultRecordState.synced);
    }).toList();
  }

  @override
  Future<PageResult<Map<String, dynamic>>> queryPage(
      String collection, VaultQuery q) async {
    final all = await query(collection, q);
    final total = all.length;
    final offset = q.offset ?? 0;
    final limit = q.limit ?? total;
    final page = all.skip(offset).take(limit).toList();
    return PageResult(items: page, total: total, offset: offset, limit: limit);
  }

  @override
  Future<int> count(String collection, VaultQuery q) async {
    final all = await query(collection, q);
    return all.length;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // VaultStorage — индексы, транзакции, реактивность
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Future<void> createIndex(String collection, VaultIndex index) async {
    await _buffer.createIndex(collection, index);
    await _remote.createIndex(collection, index);
  }

  @override
  Future<void> updateIndex(
      String collection, String id, Map<String, dynamic> indexData) async {
    await _buffer.updateIndex(collection, id, indexData);
    // remote — только при flush
  }

  @override
  Future<void> removeFromIndex(String collection, String id) async {
    await _buffer.removeFromIndex(collection, id);
  }

  @override
  Future<T> transaction<T>(Future<T> Function(VaultStorage tx) action) async {
    // В режиме буфера транзакция работает только на буфере.
    // flush() после транзакции отправит в remote.
    return action(this);
  }

  @override
  Stream<void> watchChanges(String collection) {
    // Слушаем только буфер — моментально без сети
    return _buffer.watchChanges(collection);
  }

  @override
  Future<void> clear(String collection) async {
    await _buffer.clear(collection);
    _dirty[collection]?.clear();
    _originals[collection]?.clear();
  }

  @override
  Future<void> dispose() async {
    await _buffer.dispose();
    _dirty.clear();
    _originals.clear();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Приватные хелперы
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _ensureLocal(String collection) async {
    await _buffer.ensureCollection(collection);
    _dirty.putIfAbsent(collection, () => {});
    _originals.putIfAbsent(collection, () => {});
  }

  Future<Map<String, dynamic>?> _fetchFromBuffer(
      String collection, String id) async {
    return _buffer.get(collection, id);
  }

  Future<Map<String, dynamic>?> _fetchFromRemote(
      String collection, String id) async {
    return _remote.get(collection, id);
  }

  /// Добавить _ls ключ к данным.
  Map<String, dynamic> _withState(
      Map<String, dynamic> data, VaultRecordState state) {
    return {...data, IBufferedStorage.kStateKey: state.name};
  }

  /// Убрать служебные ключи (_ls и _deleted) перед отправкой в remote.
  Map<String, dynamic> _stripMeta(Map<String, dynamic> data) {
    final result = Map<String, dynamic>.from(data);
    result.remove(IBufferedStorage.kStateKey);
    result.remove('_deleted');
    return result;
  }

  VaultRecordState? _stateFromMap(Map<String, dynamic> data) {
    final s = data[IBufferedStorage.kStateKey] as String?;
    if (s == null) return null;
    return VaultRecordState.values.firstWhere(
      (e) => e.name == s,
      orElse: () => VaultRecordState.synced,
    );
  }

  String? _idOf(Map<String, dynamic> data) {
    return data['id'] as String? ?? data['nodeId'] as String?;
  }
}
