// Artifact / S2: Metadata Query — режим Remote
// Запуск: dart run artifact/s2_metadata_query/remote.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

StoredArtifact _make(String id, String type) => StoredArtifact(
  id: id, tenantId: 'tenant-a', ownerId: 'user-1',
  storageKey: 'tenant-a/$id', fileName: '$id.file',
  contentType: type, sizeBytes: 100, checksum: 'x', createdAt: DateTime.now(),
);

void main() async {
  await initializeDataLayer(endpoint: 'http://localhost:8765', tenantId: 'tenant-a');
  final repo = IDataLayer.instance.artifacts<StoredArtifact>(
    collection: StoredArtifact.kCollection, fromMap: StoredArtifact.fromMap,
  );

  for (final a in [_make('f1', 'application/pdf'), _make('f2', 'application/pdf'), _make('f3', 'image/png')]) {
    await repo.save(a, []);
  }

  final pdfs = await repo.findAll(
    query: VaultQuery().where('contentType', VaultOperator.equals, 'application/pdf'),
  );
  print('PDFs found: ${pdfs.length} ✓');

  print('✅ Artifact S2 Metadata Query (remote) — OK');
  await IDataLayer.disconnect();
}
