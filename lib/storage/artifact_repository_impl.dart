import 'dart:async';
import 'package:aq_schema/aq_schema.dart';
import 'package:meta/meta.dart';

import '../repositories/artifact_repository.dart';

import '../storage/direct_repository_impl.dart' show watchWithBuffer;

/// Default implementation of [ArtifactRepository].
///
/// Uses two backends:
/// - [_binaryStore]  ([ArtifactStorage]) — raw file bytes
/// - [_metaStorage]  ([VaultStorage])    — [ArtifactEntry] JSON metadata
///
/// The binary storage key is built as:
///   `{tenantPrefix}/{collection}/{id}/{fileName}`
///
/// ## Encryption note
/// Encryption is NOT the responsibility of this package.
/// Encrypt the bytes before calling [save] and decrypt after [loadBytes].
/// The repository stores and returns whatever bytes it receives.
@internal
final class ArtifactRepositoryImpl<T extends ArtifactEntry>
    implements ArtifactRepository<T> {
  final ArtifactStorage _binaryStore;
  final VaultStorage _metaStorage;
  final String _collection;
  final String _tenantPrefix;
  final T Function(Map<String, dynamic>) _fromMap;

  ArtifactRepositoryImpl({
    required ArtifactStorage binaryStore,
    required VaultStorage metaStorage,
    required String collection,
    required T Function(Map<String, dynamic>) fromMap,
    String tenantPrefix = '',
  })  : _binaryStore = binaryStore,
        _metaStorage = metaStorage,
        _collection = collection,
        _tenantPrefix = tenantPrefix,
        _fromMap = fromMap;

  // ── Write ──────────────────────────────────────────────────────────────────

  @override
  Future<void> save(T entry, List<int> bytes) async {
    await _metaStorage.ensureCollection(_collection);
    final key = _buildKey(entry.id, entry.fileName);

    // Store binary content first
    await _binaryStore.put(key, bytes, contentType: entry.contentType);

    // Persist metadata with actual size + lightweight checksum
    final map = {
      ...entry.toMap(),
      'storageKey': key,
      'sizeBytes': bytes.length,
      'checksum': _checksum(bytes),
    };
    await _metaStorage.put(_collection, entry.id, map);
  }

  @override
  Future<void> delete(String id) async {
    final meta = await findById(id);
    if (meta != null) {
      await _binaryStore.delete(meta.storageKey);
    }
    await _metaStorage.delete(_collection, id);
  }

  // ── Read ───────────────────────────────────────────────────────────────────

  @override
  Future<List<int>?> loadBytes(String id) async {
    final meta = await findById(id);
    if (meta == null) return null;
    return _binaryStore.get(meta.storageKey);
  }

  @override
  Stream<List<int>> streamBytes(String id) async* {
    final meta = await findById(id);
    if (meta == null) return;
    yield* _binaryStore.stream(meta.storageKey);
  }

  @override
  Future<T?> findById(String id) async {
    final data = await _metaStorage.get(_collection, id);
    return data != null ? _fromMap(data) : null;
  }

  @override
  Future<List<T>> findAll({VaultQuery? query}) async {
    await _metaStorage.ensureCollection(_collection);
    final rows =
        await _metaStorage.query(_collection, query ?? const VaultQuery());
    return rows.map(_fromMap).toList();
  }

  @override
  Future<PageResult<T>> findPage(VaultQuery query) async {
    await _metaStorage.ensureCollection(_collection);
    final page = await _metaStorage.queryPage(_collection, query);
    return page.map(_fromMap);
  }

  @override
  Future<bool> exists(String id) => _metaStorage.exists(_collection, id);

  // ── Watch ──────────────────────────────────────────────────────────────────

  @override
  Stream<List<T>> watchAll({VaultQuery? query}) => watchWithBuffer<T>(
        _metaStorage.watchChanges(_collection),
        () => findAll(query: query),
      );

  // ── Private ────────────────────────────────────────────────────────────────

  String _buildKey(String id, String fileName) {
    final prefix = _tenantPrefix.isEmpty ? '' : '$_tenantPrefix/';
    return '${prefix}$_collection/$id/$fileName';
  }

  /// Zero-dependency lightweight checksum.
  /// For a real SHA-256, inject via a constructor parameter or middleware.
  String _checksum(List<int> bytes) {
    if (bytes.isEmpty) return 'empty';
    var h = 0x811c9dc5; // FNV-1a 32-bit offset basis
    for (final b in bytes) {
      h ^= b;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return 'fnv1a-${h.toRadixString(16).padLeft(8, '0')}';
  }
}
