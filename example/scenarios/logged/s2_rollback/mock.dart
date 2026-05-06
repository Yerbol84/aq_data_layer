// Logged / S2: Rollback — режим Mock
//
// running → failed → rollback к running
//
// Запуск: dart run logged/s2_rollback/mock.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:aq_schema/data_testing.dart';

void main() async {
  MockDataLayer.register(MockDataBackend.empty());
  final repo = IDataLayer.instance.logged<WorkflowRun>(
    collection: WorkflowRun.kCollection,
    fromMap: WorkflowRun.fromMap,
  );

  final run = WorkflowRun(
    id: 'run-001', projectId: 'proj-001', projectPath: '/projects/my-project',
    blueprintId: 'graph-001', graphSnapshot: const {},
    status: WorkflowRunStatus.running, logsJson: '[]', createdAt: DateTime.now(),
  );

  await repo.save(run, actorId: 'system');
  final history1 = await repo.getHistory('run-001');
  final firstEntryId = history1.first.entryId;

  // Обновить → failed
  await repo.save(run.copyWith(status: WorkflowRunStatus.failed), actorId: 'system');
  final current = await repo.findById('run-001');
  assert(current?.status == WorkflowRunStatus.failed);
  print('Status: ${current?.status.value}');

  // Rollback к первой записи (running)
  await repo.rollbackTo('run-001', firstEntryId, actorId: 'admin');
  final afterRollback = await repo.findById('run-001');
  assert(afterRollback?.status == WorkflowRunStatus.running);
  print('After rollback: ${afterRollback?.status.value} ✓');

  // История не удаляется — rollback записывается как новая запись
  final history2 = await repo.getHistory('run-001');
  assert(history2.length == 3); // create + update + rollback
  print('History entries: ${history2.length} ✓');

  print('✅ Logged S2 Rollback (mock) — OK');
  await IDataLayer.disconnect();
}
