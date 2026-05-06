// Direct / S2: Filter + Pagination — режим Remote
//
// Запуск: dart run direct/s2_filter_pagination/remote.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

void main() async {
  await initializeDataLayer(endpoint: 'http://localhost:8765', tenantId: 'tenant-a');
  final repo = IDataLayer.instance.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  // Seed
  for (var i = 1; i <= 3; i++) {
    await repo.save(AqStudioProject.create(
      id: 'proj-$i', tenantId: 'tenant-a', ownerId: 'user-1',
      name: 'Coder Project $i', projectType: 'coder',
    ));
  }
  for (var i = 4; i <= 5; i++) {
    await repo.save(AqStudioProject.create(
      id: 'proj-$i', tenantId: 'tenant-a', ownerId: 'user-1',
      name: 'Designer Project $i', projectType: 'designer',
    ));
  }

  final coderProjects = await repo.findAll(
    query: VaultQuery().where('projectType', VaultOperator.equals, 'coder'),
  );
  print('Coder projects: ${coderProjects.length}');

  final page1 = await repo.findPage(VaultQuery().limit(2).offset(0));
  print('Page 1: ${page1.items.length} items, total: ${page1.total}');

  print('✅ Direct S2 Filter+Pagination (remote) — OK');
  await IDataLayer.disconnect();
}
