// Logged / S3: Collection Log — режим Remote
// Запуск: dart run logged/s3_collection_log/remote.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

void main() async {
  await initializeDataLayer(endpoint: 'http://localhost:8765', tenantId: 'tenant-a');
  final repo = IDataLayer.instance.logged<WorkflowRun>(
    collection: WorkflowRun.kCollection, fromMap: WorkflowRun.fromMap,
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

  print('✅ Logged S3 Collection Log (remote) — OK');
  await IDataLayer.disconnect();
}
