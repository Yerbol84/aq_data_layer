// Direct / S1: CRUD — режим Mock
//
// Демонстрирует базовый CRUD для DirectStorable без сервера и БД.
// Используется в unit-тестах и CI.
//
// Запуск: dart run direct/s1_crud/mock.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:aq_schema/data_testing.dart';

void main() async {
  // 1. Инициализация — MockDataLayer без сервера
  MockDataLayer.register(MockDataBackend.empty());
  final repo = IDataLayer.instance.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  // 2. Create
  final project = AqStudioProject.create(
    id: 'proj-001',
    tenantId: 'tenant-a',
    ownerId: 'user-1',
    name: 'My Project',
    projectType: 'coder',
  );
  await repo.save(project);
  print('Created: ${project.name}');

  // 3. Read
  final found = await repo.findById('proj-001');
  assert(found != null && found.name == 'My Project');
  print('Found: ${found!.name}');

  // 4. Update
  final updated = found.copyWith(name: 'My Project (updated)');
  await repo.save(updated);
  final afterUpdate = await repo.findById('proj-001');
  assert(afterUpdate!.name == 'My Project (updated)');
  print('Updated: ${afterUpdate!.name}');

  // 5. Delete
  await repo.delete('proj-001');
  final afterDelete = await repo.findById('proj-001');
  assert(afterDelete == null);
  print('Deleted: ${afterDelete == null ? 'confirmed' : 'ERROR'}');

  print('✅ Direct S1 CRUD (mock) — OK');
  await IDataLayer.disconnect();
}
