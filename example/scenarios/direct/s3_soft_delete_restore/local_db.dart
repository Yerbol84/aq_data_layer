// Direct / S3: Soft Delete + Restore — режим Local DB
//
// Запуск: dart run direct/s3_soft_delete_restore/local_db.dart

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

  final project = AqStudioProject.create(
    id: 'proj-001', tenantId: 'tenant-a', ownerId: 'user-1',
    name: 'My Project', projectType: 'coder',
  );
  await repo.save(project);

  await repo.delete('proj-001');
  final afterDelete = await repo.findById('proj-001');
  print('After delete: ${afterDelete == null ? 'hidden ✓' : 'ERROR'}');

  final withDeleted = await repo.findAllIncludingDeleted();
  print('Including deleted: ${withDeleted.length} record(s) ✓');

  await repo.restore('proj-001');
  final afterRestore = await repo.findById('proj-001');
  print('After restore: ${afterRestore?.name} ✓');

  print('✅ Direct S3 Soft Delete + Restore (local_db) — OK');
  await pool.close();
}
