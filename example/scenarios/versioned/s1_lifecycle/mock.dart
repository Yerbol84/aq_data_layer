// Versioned / S1: Lifecycle — режим Mock
//
// draft → publishDraft(v1.0.0) → getCurrent
//
// Запуск: dart run versioned/s1_lifecycle/mock.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:aq_schema/data_testing.dart';

void main() async {
  MockDataLayer.register(MockDataBackend.empty());
  final repo = IDataLayer.instance.versioned<TypedWorkflowGraph>(
    collection: TypedWorkflowGraph.kCollection,
    fromMap: TypedWorkflowGraph.fromMapRaw,
  );

  final graph = TypedWorkflowGraph.empty(
    id: 'graph-001',
    tenantId: 'tenant-a',
    projectId: 'proj-001',
    name: 'My Workflow',
  );

  // 1. Создать draft
  final node = await repo.createEntity(graph);
  assert(node.status == VersionStatus.draft);
  print('Draft created: ${node.nodeId}, status: ${node.status.name}');

  // 2. Опубликовать как v1.0.0
  final published = await repo.publishDraft(
    node.nodeId,
    increment: IncrementType.major,
  );
  assert(published.status == VersionStatus.published);
  assert(published.version.toString() == 'v1.0.0');
  print('Published: ${published.version}');

  // 3. Получить текущую версию
  final current = await repo.getCurrent('graph-001');
  assert(current != null && current.name == 'My Workflow');
  print('Current: ${current!.name} ✓');

  print('✅ Versioned S1 Lifecycle (mock) — OK');
  await IDataLayer.disconnect();
}
