import 'dart:async';
import 'dart:io';

import 'package:aq_schema/aq_schema.dart';

/// [ArtifactStorage] backed by the local filesystem (`dart:io`).
///
/// Files are stored under [basePath] with the key used as the relative path.
/// Forward-slashes in keys become OS path separators automatically.
///
/// Example:
///   key = `"user_alice__docs/abc-123/report.pdf"`
///   file = `"<basePath>/user_alice__docs/abc-123/report.pdf"`
///
/// Suitable for:
/// - Desktop applications (AQ Studio current version)
/// - Server-side Data Service running on a VPS / Docker volume
///
/// For cloud deployments implement [ArtifactStorage] over HTTP using
/// Supabase Storage or S3 — the [ArtifactRepository] only depends on
/// this interface, so swapping is a one-line change.
///
/// **Requires `dart:io`** — not available on Flutter Web.
final class LocalArtifactStorage implements ArtifactStorage {
  final String basePath;

  LocalArtifactStorage({required this.basePath});

  // ── Write ──────────────────────────────────────────────────────────────────

  @override
  Future<void> put(
    String key,
    List<int> bytes, {
    String? contentType,
  }) async {
    final file = _file(key);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  // ── Read ───────────────────────────────────────────────────────────────────

  @override
  Future<List<int>?> get(String key) async {
    final file = _file(key);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<bool> exists(String key) => _file(key).exists();

  @override
  Future<int?> size(String key) async {
    final file = _file(key);
    if (!await file.exists()) return null;
    return (await file.stat()).size;
  }

  // ── Stream ─────────────────────────────────────────────────────────────────

  @override
  Stream<List<int>> stream(String key) {
    final file = _file(key);
    return file.openRead();
  }

  // ── Delete ─────────────────────────────────────────────────────────────────

  @override
  Future<void> delete(String key) async {
    final file = _file(key);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> deleteByPrefix(String prefix) async {
    final dir = Directory(_resolve(prefix));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  // ── List ───────────────────────────────────────────────────────────────────

  @override
  Future<List<String>> list(String prefix) async {
    final dir = Directory(_resolve(prefix));
    if (!await dir.exists()) return [];
    final entities =
        await dir.list(recursive: true).where((e) => e is File).toList();
    return entities.map((e) => _toKey(e.path)).toList();
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {}

  // ── Private ────────────────────────────────────────────────────────────────

  File _file(String key) => File(_resolve(key));

  String _resolve(String key) =>
      '$basePath/${key.replaceAll('/', Platform.pathSeparator)}';

  String _toKey(String absolutePath) {
    final relative = absolutePath.substring(basePath.length);
    return relative
        .replaceAll(Platform.pathSeparator, '/')
        .replaceAll(RegExp(r'^/'), '');
  }
}
