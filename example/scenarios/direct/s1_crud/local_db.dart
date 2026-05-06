// Direct / S1: CRUD — режим Local DB
//
// Тот же сценарий, но с реальным PostgreSQL напрямую (без HTTP сервера).
// Используется для интеграционных тестов и серверного кода.
//
// Требует: PostgreSQL на localhost:5432
// Запуск: dart run direct/s1_crud/local_db.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/server.dart';

void main() async {
  // 1. Инициализация — PostgreSQL напрямую
  final pool = Pool.withEndpoints([
    Endpoint(
      host: 'localhost',
      port: 5432,
      database: 'vault_db',
      username: 'postgres',
      password: 'postgres',
    ),
  ]);

  final storage = PostgresVaultStorage(pool: pool, tenantId: 'tenant-a');
  final vault = Vault(storage: storage, tenantId: 'tenant-a');
  final repo = vault.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  // 2. Create
  final project = AqStudioProject.create(
    id: 'proj-001',
    tenantId: 'tenant-a',
    ownerId: 'user-1',
    name: 'My Project',
    projectType: 'coder',
  );
  await repo.save(project);
  print('Created: ${project.name}');

  // 3. Read
  final found = await repo.findById('proj-001');
  assert(found != null && found.name == 'My Project');
  print('Found: ${found!.name}');

  // 4. Update
  final updated = found.copyWith(name: 'My Project (updated)');
  await repo.save(updated);
  final afterUpdate = await repo.findById('proj-001');
  assert(afterUpdate!.name == 'My Project (updated)');
  print('Updated: ${afterUpdate!.name}');

  // 5. Delete
  await repo.delete('proj-001');
  final afterDelete = await repo.findById('proj-001');
  assert(afterDelete == null);
  print('Deleted: ${afterDelete == null ? 'confirmed' : 'ERROR'}');

  print('✅ Direct S1 CRUD (local_db) — OK');
  await pool.close();
}
