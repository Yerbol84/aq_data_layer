// Artifact / S3: Replace — режим Mock
// Запуск: dart run artifact/s3_replace/mock.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:aq_schema/data_testing.dart';

void main() async {
  MockDataLayer.register(MockDataBackend.empty());
  final repo = IDataLayer.instance.artifacts<StoredArtifact>(
    collection: StoredArtifact.kCollection, fromMap: StoredArtifact.fromMap,
  );

  final v1bytes = [1, 2, 3];
  final artifact = StoredArtifact(
    id: 'file-001', tenantId: 'tenant-a', ownerId: 'user-1',
    storageKey: 'tenant-a/file-001/doc.pdf', fileName: 'doc.pdf',
    contentType: 'application/pdf', sizeBytes: v1bytes.length,
    checksum: 'v1-checksum', createdAt: DateTime.now(),
  );
  await repo.save(artifact, v1bytes);
  print('v1 uploaded: ${artifact.sizeBytes} bytes, checksum: ${artifact.checksum}');

  // Replace — сохраняем тот же id с новыми байтами
  final v2bytes = [10, 20, 30, 40];
  final v2 = StoredArtifact(
    id: 'file-001', tenantId: 'tenant-a', ownerId: 'user-1',
    storageKey: 'tenant-a/file-001/doc.pdf', fileName: 'doc.pdf',
    contentType: 'application/pdf', sizeBytes: v2bytes.length,
    checksum: 'v2-checksum', createdAt: DateTime.now(),
  );
  await repo.save(v2, v2bytes);

  final downloaded = await repo.loadBytes('file-001');
  assert(downloaded?.length == v2bytes.length);
  final meta = await repo.findById('file-001');
  assert(meta?.checksum == 'v2-checksum');
  print('v2 replaced: ${meta?.sizeBytes} bytes, checksum: ${meta?.checksum} ✓');

  print('✅ Artifact S3 Replace (mock) — OK');
  await IDataLayer.disconnect();
}
