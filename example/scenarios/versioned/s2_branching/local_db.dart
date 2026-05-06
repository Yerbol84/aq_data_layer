// Versioned / S2: Branching — режим Local DB
//
// Запуск: dart run versioned/s2_branching/local_db.dart

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
    id: 'graph-001', tenantId: 'tenant-a', projectId: 'proj-001', name: 'Main',
  );
  final node = await repo.createEntity(graph);
  final published = await repo.publishDraft(node.nodeId, increment: IncrementType.major);
  print('Main v1.0.0: ${published.version}');

  final branchNode = await repo.createBranch(
    published.nodeId,
    branchName: 'feature',
    model: TypedWorkflowGraph.empty(
      id: 'graph-001', tenantId: 'tenant-a', projectId: 'proj-001', name: 'Feature Work',
    ),
  );
  print('Branch: ${branchNode.branch}');

  final merged = await repo.mergeToMain(
    'graph-001', sourceBranch: 'feature', requesterId: 'user-1',
    fromMap: TypedWorkflowGraph.fromMapRaw,
  );
  print('Merged to main: ${merged.branch} ✓');

  print('✅ Versioned S2 Branching (local_db) — OK');
  await pool.close();
}
