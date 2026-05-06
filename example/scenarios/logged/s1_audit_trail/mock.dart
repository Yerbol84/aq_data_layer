// Logged / S1: Audit Trail — режим Mock
//
// Создать run → обновить статус → получить историю изменений
//
// Запуск: dart run logged/s1_audit_trail/mock.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:aq_schema/data_testing.dart';

void main() async {
  MockDataLayer.register(MockDataBackend.empty());
  final repo = IDataLayer.instance.logged<WorkflowRun>(
    collection: WorkflowRun.kCollection,
    fromMap: WorkflowRun.fromMap,
  );

  final run = WorkflowRun(
    id: 'run-001',
    projectId: 'proj-001',
    projectPath: '/projects/my-project',
    blueprintId: 'graph-001',
    graphSnapshot: const {},
    status: WorkflowRunStatus.running,
    logsJson: '[]',
    createdAt: DateTime.now(),
  );

  // Создать
  await repo.save(run, actorId: 'system');
  print('Created: ${run.status.value}');

  // Обновить статус → completed
  final completed = run.copyWith(status: WorkflowRunStatus.completed);
  await repo.save(completed, actorId: 'system');
  print('Updated: ${completed.status.value}');

  // Получить историю
  final history = await repo.getHistory('run-001');
  assert(history.length == 2);
  print('History entries: ${history.length}');
  for (final entry in history) {
    print('  ${entry.operation.name} by ${entry.changedBy} at ${entry.changedAt}');
  }

  print('✅ Logged S1 Audit Trail (mock) — OK');
  await IDataLayer.disconnect();
}
