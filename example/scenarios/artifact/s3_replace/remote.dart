// Artifact / S3: Replace — режим Remote
// Запуск: dart run artifact/s3_replace/remote.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

void main() async {
  await initializeDataLayer(endpoint: 'http://localhost:8765', tenantId: 'tenant-a');
  final repo = IDataLayer.instance.artifacts<StoredArtifact>(
    collection: StoredArtifact.kCollection, fromMap: StoredArtifact.fromMap,
  );

  final v1 = StoredArtifact(
    id: 'file-001', tenantId: 'tenant-a', ownerId: 'user-1',
    storageKey: 'tenant-a/file-001/doc.pdf', fileName: 'doc.pdf',
    contentType: 'application/pdf', sizeBytes: 3, checksum: 'v1', createdAt: DateTime.now(),
  );
  await repo.save(v1, [1, 2, 3]);
  print('v1: ${v1.checksum}');

  final v2 = StoredArtifact(
    id: 'file-001', tenantId: 'tenant-a', ownerId: 'user-1',
    storageKey: 'tenant-a/file-001/doc.pdf', fileName: 'doc.pdf',
    contentType: 'application/pdf', sizeBytes: 4, checksum: 'v2', createdAt: DateTime.now(),
  );
  await repo.save(v2, [10, 20, 30, 40]);
  final meta = await repo.findById('file-001');
  print('v2 replaced: checksum=${meta?.checksum} ✓');

  print('✅ Artifact S3 Replace (remote) — OK');
  await IDataLayer.disconnect();
}
