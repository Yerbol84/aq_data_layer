// Versioned / S1: Lifecycle — режим Remote
//
// Запуск: dart run versioned/s1_lifecycle/remote.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

void main() async {
  await initializeDataLayer(endpoint: 'http://localhost:8765', tenantId: 'tenant-a');
  final repo = IDataLayer.instance.versioned<TypedWorkflowGraph>(
    collection: TypedWorkflowGraph.kCollection,
    fromMap: TypedWorkflowGraph.fromMapRaw,
  );

  final graph = TypedWorkflowGraph.empty(
    id: 'graph-001', tenantId: 'tenant-a',
    projectId: 'proj-001', name: 'My Workflow',
  );

  final node = await repo.createEntity(graph);
  print('Draft: ${node.nodeId}, status: ${node.status.name}');

  final published = await repo.publishDraft(node.nodeId, increment: IncrementType.major);
  print('Published: ${published.version}');

  final current = await repo.getCurrent('graph-001');
  print('Current: ${current?.name} ✓');

  print('✅ Versioned S1 Lifecycle (remote) — OK');
  await IDataLayer.disconnect();
}
