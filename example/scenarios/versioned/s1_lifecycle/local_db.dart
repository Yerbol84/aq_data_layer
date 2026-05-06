// Versioned / S1: Lifecycle — режим Local DB
//
// Запуск: dart run versioned/s1_lifecycle/local_db.dart

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
  final repo = vault.versioned<TypedWorkflowGraph>(
    collection: TypedWorkflowGraph.kCollection,
    fromMap: TypedWorkflowGraph.fromMapRaw,
  );

  final graph = TypedWorkflowGraph.empty(
    id: 'graph-001', tenantId: 'tenant-a',
    projectId: 'proj-001', name: 'My Workflow',
  );

  final node = await repo.createEntity(graph);
  print('Draft: ${node.nodeId}, status: ${node.status.name}');

  final published = await repo.publishDraft(node.nodeId, increment: IncrementType.major);
  print('Published: ${published.version}');

  final current = await repo.getCurrent('graph-001');
  print('Current: ${current?.name} ✓');

  print('✅ Versioned S1 Lifecycle (local_db) — OK');
  await pool.close();
}
