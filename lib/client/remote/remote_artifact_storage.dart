import 'dart:convert';
import 'package:aq_schema/aq_schema.dart';
import 'remote_vault_storage.dart';

/// [ArtifactStorage] implementation that delegates to a remote vault server via RPC.
///
/// Binary content is base64-encoded for transport.
/// Use for client-server mode; for local/serverless use [LocalArtifactStorage].
final class RemoteArtifactStorage implements ArtifactStorage {
  final RemoteVaultStorage _remote;

  RemoteArtifactStorage({required RemoteVaultStorage remote})
      : _remote = remote;

  @override
  Future<void> put(String key, List<int> bytes, {String? contentType}) async {
    await _remote.rpc(
      StoredArtifact.kCollection,
      'uploadBytes',
      {
        'key': key,
        'bytes': base64Encode(bytes),
        if (contentType != null) 'contentType': contentType,
      },
    );
  }

  @override
  Future<List<int>?> get(String key) async {
    final result = await _remote.rpc(
      StoredArtifact.kCollection,
      'downloadBytes',
      {'key': key},
    );
    if (result == null) return null;
    final map = result as Map<String, dynamic>;
    return base64Decode(map['bytes'] as String);
  }

  @override
  Future<bool> exists(String key) async {
    final bytes = await get(key);
    return bytes != null;
  }

  @override
  Future<int?> size(String key) async {
    final bytes = await get(key);
    return bytes?.length;
  }

  @override
  Stream<List<int>> stream(String key) async* {
    final bytes = await get(key);
    if (bytes != null) yield bytes;
  }

  @override
  Future<void> delete(String key) async {
    await _remote.rpc(StoredArtifact.kCollection, 'deleteBytes', {'key': key});
  }

  @override
  Future<void> deleteByPrefix(String prefix) async {
    await _remote.rpc(StoredArtifact.kCollection, 'deleteBytesPrefix', {'prefix': prefix});
  }

  @override
  Future<List<String>> list(String prefix) async {
    final result = await _remote.rpc(StoredArtifact.kCollection, 'listBytes', {'prefix': prefix});
    return (result as List<dynamic>).cast<String>();
  }

  @override
  Future<void> dispose() async {}
}
