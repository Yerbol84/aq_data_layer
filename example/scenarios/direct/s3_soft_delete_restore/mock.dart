// Direct / S3: Soft Delete + Restore — режим Mock
//
// Запуск: dart run direct/s3_soft_delete_restore/mock.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:aq_schema/data_testing.dart';

void main() async {
  MockDataLayer.register(MockDataBackend.empty());
  final repo = IDataLayer.instance.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  final project = AqStudioProject.create(
    id: 'proj-001', tenantId: 'tenant-a', ownerId: 'user-1',
    name: 'My Project', projectType: 'coder',
  );
  await repo.save(project);

  // Soft delete — запись остаётся в БД, но скрыта
  await repo.delete('proj-001');
  final afterDelete = await repo.findById('proj-001');
  assert(afterDelete == null, 'Should be hidden after soft delete');
  print('After delete: hidden ✓');

  // findAllIncludingDeleted — видим удалённые
  final withDeleted = await repo.findAllIncludingDeleted();
  assert(withDeleted.length == 1);
  print('Including deleted: ${withDeleted.length} record(s) ✓');

  // Restore
  await repo.restore('proj-001');
  final afterRestore = await repo.findById('proj-001');
  assert(afterRestore != null && afterRestore.name == 'My Project');
  print('After restore: ${afterRestore!.name} ✓');

  print('✅ Direct S3 Soft Delete + Restore (mock) — OK');
  await IDataLayer.disconnect();
}
