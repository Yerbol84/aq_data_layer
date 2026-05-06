// Artifact / S1: Upload + Download — режим Mock
// Запуск: dart run artifact/s1_upload_download/mock.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:aq_schema/data_testing.dart';

void main() async {
  MockDataLayer.register(MockDataBackend.empty());
  final repo = IDataLayer.instance.artifacts<StoredArtifact>(
    collection: StoredArtifact.kCollection,
    fromMap: StoredArtifact.fromMap,
  );

  final bytes = [72, 101, 108, 108, 111]; // "Hello"
  final artifact = StoredArtifact(
    id: 'file-001',
    tenantId: 'tenant-a',
    ownerId: 'user-1',
    storageKey: 'tenant-a/artifacts/file-001/hello.txt',
    fileName: 'hello.txt',
    contentType: 'text/plain',
    sizeBytes: bytes.length,
    checksum: 'abc123',
    createdAt: DateTime.now(),
  );

  // Upload
  await repo.save(artifact, bytes);
  print('Uploaded: ${artifact.fileName} (${artifact.sizeBytes} bytes)');

  // Download bytes
  final downloaded = await repo.loadBytes('file-001');
  assert(downloaded != null && downloaded.length == bytes.length);
  print('Downloaded: ${downloaded!.length} bytes ✓');

  // Metadata only
  final meta = await repo.findById('file-001');
  assert(meta?.fileName == 'hello.txt');
  print('Metadata: ${meta?.fileName}, ${meta?.contentType} ✓');

  print('✅ Artifact S1 Upload+Download (mock) — OK');
  await IDataLayer.disconnect();
}
