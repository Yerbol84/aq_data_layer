// Logged / S1: Audit Trail — режим Local DB
//
// Запуск: dart run logged/s1_audit_trail/local_db.dart

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

  print('✅ Logged S1 Audit Trail (local_db) — OK');
  await pool.close();
}
