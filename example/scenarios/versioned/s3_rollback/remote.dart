// Versioned / S3: Rollback — режим Remote
//
// Запуск: dart run versioned/s3_rollback/remote.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

void main() async {
  await initializeDataLayer(endpoint: 'http://localhost:8765', tenantId: 'tenant-a');
  final repo = IDataLayer.instance.versioned<TypedWorkflowGraph>(
    collection: TypedWorkflowGraph.kCollection,
    fromMap: TypedWorkflowGraph.fromMapRaw,
  );

  final n1 = await repo.createEntity(TypedWorkflowGraph.empty(
    id: 'graph-001', tenantId: 'tenant-a', projectId: 'proj-001', name: 'v1 Graph',
  ));
  final v1 = await repo.publishDraft(n1.nodeId, increment: IncrementType.major);
  print('v1: ${v1.version}');

  final n2 = await repo.createDraftFrom(v1.nodeId, TypedWorkflowGraph.empty(
    id: 'graph-001', tenantId: 'tenant-a', projectId: 'proj-001', name: 'v2 Graph',
  ));
  final v2 = await repo.publishDraft(n2.nodeId, increment: IncrementType.minor);
  print('v2: ${v2.version}');

  final v1Data = await repo.getVersion(v1.nodeId);
  final rollbackDraft = await repo.createDraftFrom(v1.nodeId, v1Data!);
  final rollback = await repo.publishDraft(rollbackDraft.nodeId, increment: IncrementType.patch);
  print('Rollback: ${rollback.version}');

  final afterRollback = await repo.getCurrent('graph-001');
  print('After rollback: ${afterRollback?.name} ✓');

  print('✅ Versioned S3 Rollback (remote) — OK');
  await IDataLayer.disconnect();
}
