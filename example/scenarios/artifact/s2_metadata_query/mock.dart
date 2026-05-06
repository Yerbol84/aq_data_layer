// Artifact / S2: Metadata Query — режим Mock
// Запуск: dart run artifact/s2_metadata_query/mock.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:aq_schema/data_testing.dart';

StoredArtifact _make(String id, String type) => StoredArtifact(
  id: id, tenantId: 'tenant-a', ownerId: 'user-1',
  storageKey: 'tenant-a/$id', fileName: '$id.file',
  contentType: type, sizeBytes: 100, checksum: 'x',
  createdAt: DateTime.now(),
);

void main() async {
  final artifacts = [
    _make('f1', 'application/pdf'),
    _make('f2', 'application/pdf'),
    _make('f3', 'image/png'),
  ];
  MockDataLayer.register(MockDataBackend.withData(
    collection: StoredArtifact.kCollection, entities: artifacts,
  ));
  final repo = IDataLayer.instance.artifacts<StoredArtifact>(
    collection: StoredArtifact.kCollection, fromMap: StoredArtifact.fromMap,
  );

  // Найти все PDF
  final pdfs = await repo.findAll(
    query: VaultQuery().where('contentType', VaultOperator.equals, 'application/pdf'),
  );
  assert(pdfs.length == 2);
  print('PDFs found: ${pdfs.length} ✓');

  // Пагинация
  final page = await repo.findPage(VaultQuery().limit(2).offset(0));
  print('Page: ${page.items.length} items, total: ${page.total} ✓');

  print('✅ Artifact S2 Metadata Query (mock) — OK');
  await IDataLayer.disconnect();
}
