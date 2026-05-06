// Versioned / S2: Branching — режим Remote
//
// Запуск: dart run versioned/s2_branching/remote.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

void main() async {
  await initializeDataLayer(endpoint: 'http://localhost:8765', tenantId: 'tenant-a');
  final repo = IDataLayer.instance.versioned<TypedWorkflowGraph>(
    collection: TypedWorkflowGraph.kCollection,
    fromMap: TypedWorkflowGraph.fromMapRaw,
  );

  final graph = TypedWorkflowGraph.empty(
    id: 'graph-001', tenantId: 'tenant-a', projectId: 'proj-001', name: 'Main',
  );
  final node = await repo.createEntity(graph);
  final published = await repo.publishDraft(node.nodeId, increment: IncrementType.major);
  print('Main v1.0.0: ${published.version}');

  final branchNode = await repo.createBranch(
    published.nodeId,
    branchName: 'feature',
    model: TypedWorkflowGraph.empty(
      id: 'graph-001', tenantId: 'tenant-a', projectId: 'proj-001', name: 'Feature Work',
    ),
  );
  print('Branch: ${branchNode.branch}');

  final merged = await repo.mergeToMain(
    'graph-001', sourceBranch: 'feature', requesterId: 'user-1',
    fromMap: TypedWorkflowGraph.fromMapRaw,
  );
  print('Merged to main: ${merged.branch} ✓');

  print('✅ Versioned S2 Branching (remote) — OK');
  await IDataLayer.disconnect();
}
