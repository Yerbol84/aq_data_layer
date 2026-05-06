// Logged / S1: Audit Trail — режим Remote
//
// Запуск: dart run logged/s1_audit_trail/remote.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

void main() async {
  await initializeDataLayer(endpoint: 'http://localhost:8765', tenantId: 'tenant-a');
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
  print('Created: ${run.status.value}');

  await repo.save(run.copyWith(status: WorkflowRunStatus.completed), actorId: 'system');
  print('Updated: completed');

  final history = await repo.getHistory('run-001');
  print('History entries: ${history.length}');

  print('✅ Logged S1 Audit Trail (remote) — OK');
  await IDataLayer.disconnect();
}
