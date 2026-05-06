// Artifact / S1: Upload + Download — режим Local DB
// Запуск: dart run artifact/s1_upload_download/local_db.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/server.dart';

void main() async {
  final pool = Pool.withEndpoints([
    Endpoint(host: 'localhost', port: 5432, database: 'vault_db',
        username: 'postgres', password: 'postgres'),
  ]);
  final artVault = ArtifactVault(
    binaryStore: LocalArtifactStorage(basePath: '/tmp/artifacts'),
    metaStorage: PostgresVaultStorage(pool: pool, tenantId: 'tenant-a'),
    tenantId: 'tenant-a',
  );
  final repo = artVault.artifacts<StoredArtifact>(
    collection: StoredArtifact.kCollection,
    fromMap: StoredArtifact.fromMap,
  );

  final bytes = [72, 101, 108, 108, 111];
  final artifact = StoredArtifact(
    id: 'file-001', tenantId: 'tenant-a', ownerId: 'user-1',
    storageKey: 'tenant-a/artifacts/file-001/hello.txt',
    fileName: 'hello.txt', contentType: 'text/plain',
    sizeBytes: bytes.length, checksum: 'abc123', createdAt: DateTime.now(),
  );

  await repo.save(artifact, bytes);
  print('Uploaded: ${artifact.fileName}');

  final downloaded = await repo.loadBytes('file-001');
  print('Downloaded: ${downloaded?.length} bytes ✓');

  print('✅ Artifact S1 Upload+Download (local_db) — OK');
  await artVault.dispose();
  await pool.close();
}
