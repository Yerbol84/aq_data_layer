// Logged / S3: Collection Log — режим Mock
// Запуск: dart run logged/s3_collection_log/mock.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:aq_schema/data_testing.dart';

void main() async {
  MockDataLayer.register(MockDataBackend.empty());
  final repo = IDataLayer.instance.logged<WorkflowRun>(
    collection: WorkflowRun.kCollection,
    fromMap: WorkflowRun.fromMap,
  );

  final now = DateTime.now();
  for (var i = 1; i <= 3; i++) {
    final run = WorkflowRun(
      id: 'run-00$i', projectId: 'proj-001', projectPath: '/p',
      blueprintId: 'graph-001', graphSnapshot: const {},
      status: WorkflowRunStatus.running, logsJson: '[]', createdAt: now,
    );
    await repo.save(run, actorId: 'system');
    await repo.save(run.copyWith(status: WorkflowRunStatus.completed), actorId: 'system');
  }

  final log = await repo.getCollectionLog();
  print('Total log entries: ${log.length}');
  final byOp = <String, int>{};
  for (final e in log) byOp[e.operation.name] = (byOp[e.operation.name] ?? 0) + 1;
  print('By operation: $byOp');

  print('✅ Logged S3 Collection Log (mock) — OK');
  await IDataLayer.disconnect();
}
