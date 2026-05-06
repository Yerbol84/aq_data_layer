// Versioned / S2: Branching — режим Mock
//
// Создать ветку от published → обновить → смержить в main
//
// Запуск: dart run versioned/s2_branching/mock.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:aq_schema/data_testing.dart';

void main() async {
  MockDataLayer.register(MockDataBackend.empty());
  final repo = IDataLayer.instance.versioned<TypedWorkflowGraph>(
    collection: TypedWorkflowGraph.kCollection,
    fromMap: TypedWorkflowGraph.fromMapRaw,
  );

  final graph = TypedWorkflowGraph.empty(
    id: 'graph-001', tenantId: 'tenant-a', projectId: 'proj-001', name: 'Main',
  );

  // Создать и опубликовать v1.0.0 на main
  final node = await repo.createEntity(graph);
  final published = await repo.publishDraft(node.nodeId, increment: IncrementType.major);
  print('Main v1.0.0: ${published.version}');

  // Создать ветку feature от published
  final featureGraph = TypedWorkflowGraph.empty(
    id: 'graph-001', tenantId: 'tenant-a', projectId: 'proj-001', name: 'Feature Work',
  );
  final branchNode = await repo.createBranch(
    published.nodeId,
    branchName: 'feature',
    model: featureGraph,
  );
  assert(branchNode.branch == 'feature');
  print('Branch created: ${branchNode.branch}');

  // Список веток
  final branches = await repo.listBranches('graph-001');
  assert(branches.contains('feature') && branches.contains('main'));
  print('Branches: $branches');

  // Смержить feature → main
  final merged = await repo.mergeToMain(
    'graph-001',
    sourceBranch: 'feature',
    requesterId: 'user-1',
    fromMap: TypedWorkflowGraph.fromMapRaw,
  );
  assert(merged.branch == 'main');
  print('Merged to main: ${merged.branch} ✓');

  print('✅ Versioned S2 Branching (mock) — OK');
  await IDataLayer.disconnect();
}
