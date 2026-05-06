// Direct / S2: Filter + Pagination — режим Mock
//
// Запуск: dart run direct/s2_filter_pagination/mock.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:aq_schema/data_testing.dart';

void main() async {
  // Предзагружаем 5 проектов разных типов
  final projects = [
    for (var i = 1; i <= 3; i++)
      AqStudioProject.create(
        id: 'proj-$i',
        tenantId: 'tenant-a',
        ownerId: 'user-1',
        name: 'Coder Project $i',
        projectType: 'coder',
      ),
    for (var i = 4; i <= 5; i++)
      AqStudioProject.create(
        id: 'proj-$i',
        tenantId: 'tenant-a',
        ownerId: 'user-1',
        name: 'Designer Project $i',
        projectType: 'designer',
      ),
  ];

  MockDataLayer.register(MockDataBackend.withData(
    collection: AqStudioProject.kCollection,
    entities: projects,
  ));

  final repo = IDataLayer.instance.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  // Фильтрация по типу
  final coderProjects = await repo.findAll(
    query: VaultQuery().where('projectType', VaultOperator.equals, 'coder'),
  );
  assert(coderProjects.length == 3, 'Expected 3 coder projects');
  print('Coder projects: ${coderProjects.length}');

  // Пагинация — страница 1 (2 элемента)
  final page1 = await repo.findPage(
    VaultQuery().limit(2).offset(0),
  );
  assert(page1.items.length == 2);
  assert(page1.total == 5);
  print('Page 1: ${page1.items.length} items, total: ${page1.total}');

  // Пагинация — страница 2
  final page2 = await repo.findPage(
    VaultQuery().limit(2).offset(2),
  );
  assert(page2.items.length == 2);
  print('Page 2: ${page2.items.length} items');

  print('✅ Direct S2 Filter+Pagination (mock) — OK');
  await IDataLayer.disconnect();
}
