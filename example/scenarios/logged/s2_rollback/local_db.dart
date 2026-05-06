// Logged / S2: Rollback — режим Local DB
//
// Запуск: dart run logged/s2_rollback/local_db.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/server.dart';

void main() async {
  final pool = Pool.withEndpoints([
    Endpoint(host: 'localhost', port: 5432, database: 'vault_db',
        username: 'postgres', password: 'postgres'),
  ]);
  final vault = Vault(
    storage: PostgresVaultStorage(pool: pool, tenantId: 'tenant-a'),
    tenantId: 'tenant-a',
  );
  final repo = vault.logged<WorkflowRun>(
    collection: WorkflowRun.kCollection,
    fromMap: WorkflowRun.fromMap,
    captureFullSnapshot: true,
  );

  final run = WorkflowRun(
    id: 'run-001', projectId: 'proj-001', projectPath: '/projects/my-project',
    blueprintId: 'graph-001', graphSnapshot: const {},
    status: WorkflowRunStatus.running, logsJson: '[]', createdAt: DateTime.now(),
  );

  await repo.save(run, actorId: 'system');
  final history = await repo.getHistory('run-001');
  final firstEntryId = history.first.entryId;

  await repo.save(run.copyWith(status: WorkflowRunStatus.failed), actorId: 'system');
  print('Status: failed');

  await repo.rollbackTo('run-001', firstEntryId, actorId: 'admin');
  final afterRollback = await repo.findById('run-001');
  print('After rollback: ${afterRollback?.status.value} ✓');

  print('✅ Logged S2 Rollback (local_db) — OK');
  await pool.close();
}
