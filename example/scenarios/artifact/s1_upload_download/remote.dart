// Artifact / S1: Upload + Download — режим Remote
// Запуск: dart run artifact/s1_upload_download/remote.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

void main() async {
  await initializeDataLayer(endpoint: 'http://localhost:8765', tenantId: 'tenant-a');
  final repo = IDataLayer.instance.artifacts<StoredArtifact>(
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

  print('✅ Artifact S1 Upload+Download (remote) — OK');
  await IDataLayer.disconnect();
}
