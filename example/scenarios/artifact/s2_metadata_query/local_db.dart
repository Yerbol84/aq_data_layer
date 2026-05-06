// Artifact / S2: Metadata Query — режим Local DB
// Запуск: dart run artifact/s2_metadata_query/local_db.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/server.dart';

StoredArtifact _make(String id, String type) => StoredArtifact(
  id: id, tenantId: 'tenant-a', ownerId: 'user-1',
  storageKey: 'tenant-a/$id', fileName: '$id.file',
  contentType: type, sizeBytes: 100, checksum: 'x', createdAt: DateTime.now(),
);

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
    collection: StoredArtifact.kCollection, fromMap: StoredArtifact.fromMap,
  );

  for (final a in [_make('f1', 'application/pdf'), _make('f2', 'application/pdf'), _make('f3', 'image/png')]) {
    await repo.save(a, []);
  }

  final pdfs = await repo.findAll(
    query: VaultQuery().where('contentType', VaultOperator.equals, 'application/pdf'),
  );
  print('PDFs found: ${pdfs.length} ✓');

  print('✅ Artifact S2 Metadata Query (local_db) — OK');
  await artVault.dispose();
  await pool.close();
}
