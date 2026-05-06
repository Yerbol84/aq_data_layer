// Versioned / S3: Rollback — режим Mock
//
// v1.0.0 → v1.1.0 → откат к v1.0.0 (создаём draft из старой версии)
//
// Запуск: dart run versioned/s3_rollback/mock.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:aq_schema/data_testing.dart';

void main() async {
  MockDataLayer.register(MockDataBackend.empty());
  final repo = IDataLayer.instance.versioned<TypedWorkflowGraph>(
    collection: TypedWorkflowGraph.kCollection,
    fromMap: TypedWorkflowGraph.fromMapRaw,
  );

  // Публикуем v1.0.0
  final n1 = await repo.createEntity(TypedWorkflowGraph.empty(
    id: 'graph-001', tenantId: 'tenant-a', projectId: 'proj-001', name: 'v1 Graph',
  ));
  final v1 = await repo.publishDraft(n1.nodeId, increment: IncrementType.major);
  print('Published: ${v1.version}');

  // Публикуем v1.1.0
  final n2 = await repo.createDraftFrom(
    v1.nodeId,
    TypedWorkflowGraph.empty(
      id: 'graph-001', tenantId: 'tenant-a', projectId: 'proj-001', name: 'v2 Graph',
    ),
  );
  final v2 = await repo.publishDraft(n2.nodeId, increment: IncrementType.minor);
  print('Published: ${v2.version}');

  // Текущая — v1.1.0
  final current = await repo.getCurrent('graph-001');
  assert(current?.name == 'v2 Graph');
  print('Current: ${current?.name}');

  // Rollback: создаём draft из v1.0.0 и публикуем как v1.1.1
  final v1Data = await repo.getVersion(v1.nodeId);
  final rollbackDraft = await repo.createDraftFrom(v1.nodeId, v1Data!);
  final rollback = await repo.publishDraft(rollbackDraft.nodeId, increment: IncrementType.patch);
  print('Rollback published: ${rollback.version}');

  final afterRollback = await repo.getCurrent('graph-001');
  assert(afterRollback?.name == 'v1 Graph');
  print('After rollback current: ${afterRollback?.name} ✓');

  print('✅ Versioned S3 Rollback (mock) — OK');
  await IDataLayer.disconnect();
}
