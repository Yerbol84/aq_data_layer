// Logged / S3: Collection Log — режим Local DB
// Запуск: dart run logged/s3_collection_log/local_db.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/server.dart';

void main() async {
  final pool = Pool.withEndpoints([
    Endpoint(host: 'localhost', port: 5432, database: 'vault_db',
        username: 'postgres', password: 'postgres'),
  ]);
  final vault = Vault(storage: PostgresVaultStorage(pool: pool, tenantId: 'tenant-a'), tenantId: 'tenant-a');
  final repo = vault.logged<WorkflowRun>(collection: WorkflowRun.kCollection, fromMap: WorkflowRun.fromMap);

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

  print('✅ Logged S3 Collection Log (local_db) — OK');
  await pool.close();
}
