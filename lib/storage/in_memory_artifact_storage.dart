import 'dart:async';
import 'package:aq_schema/aq_schema.dart';
import 'package:meta/meta.dart';

/// In-memory [ArtifactStorage] for tests and demos.
///
/// Stores byte arrays in a plain Dart Map.
/// Data is lost when the process exits.
@internal
final class InMemoryArtifactStorage implements ArtifactStorage {
  final _store = <String, List<int>>{};

  @override
  Future<void> put(String key, List<int> bytes, {String? contentType}) async {
    _store[key] = List<int>.from(bytes);
  }

  @override
  Future<List<int>?> get(String key) async => _store[key];

  @override
  Future<bool> exists(String key) async => _store.containsKey(key);

  @override
  Future<int?> size(String key) async => _store[key]?.length;

  @override
  Stream<List<int>> stream(String key) async* {
    final bytes = _store[key];
    if (bytes != null) yield bytes;
  }

  @override
  Future<void> delete(String key) async => _store.remove(key);

  @override
  Future<void> deleteByPrefix(String prefix) async {
    _store.removeWhere((k, _) => k.startsWith(prefix));
  }

  @override
  Future<List<String>> list(String prefix) async =>
      _store.keys.where((k) => k.startsWith(prefix)).toList();

  @override
  Future<void> dispose() async => _store.clear();
}
