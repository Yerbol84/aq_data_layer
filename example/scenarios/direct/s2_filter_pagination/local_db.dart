// Direct / S2: Filter + Pagination — режим Local DB
//
// Запуск: dart run direct/s2_filter_pagination/local_db.dart

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
  final repo = vault.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  // Seed
  for (var i = 1; i <= 3; i++) {
    await repo.save(AqStudioProject.create(
      id: 'proj-$i', tenantId: 'tenant-a', ownerId: 'user-1',
      name: 'Coder Project $i', projectType: 'coder',
    ));
  }
  for (var i = 4; i <= 5; i++) {
    await repo.save(AqStudioProject.create(
      id: 'proj-$i', tenantId: 'tenant-a', ownerId: 'user-1',
      name: 'Designer Project $i', projectType: 'designer',
    ));
  }

  final coderProjects = await repo.findAll(
    query: VaultQuery().where('projectType', VaultOperator.equals, 'coder'),
  );
  print('Coder projects: ${coderProjects.length}');

  final page1 = await repo.findPage(VaultQuery().limit(2).offset(0));
  print('Page 1: ${page1.items.length} items, total: ${page1.total}');

  print('✅ Direct S2 Filter+Pagination (local_db) — OK');
  await pool.close();
}
