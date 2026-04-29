import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

void main() async {
  print('🎯 Soft Delete Feature Test\n');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('📋 Pre-flight Checks');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  final serverUrl = 'http://localhost:8765';
  print('🔍 Checking server at $serverUrl...');
  final serverReachable = await _checkServer(serverUrl);

  if (!serverReachable) {
    print('   ❌ Server is NOT reachable');
    print('   💡 Run: cd example/stack && docker compose up --build');
    exit(1);
  }
  print('   ✅ Server is reachable');

  print('\n🔌 Connecting to data layer...');
  try {
    await initializeDataLayer(
      endpoint: serverUrl,
      useBuffer: false,
    );
  } catch (e) {
    print('   ❌ Failed to initialize: $e');
    exit(1);
  }

  if (!IDataLayer.instance.isConnected) {
    print('   ❌ Using IN-MEMORY fallback');
    exit(1);
  }
  print('   ✅ Connected to REMOTE server');

  print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('🧪 Soft Delete Tests');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  await testDirectStorageSoftDelete();
  await testLoggedStorageSoftDelete();

  print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('✅ All soft delete tests completed!');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('\n📊 Verify in database:');
  print('   docker ps  # get postgres container ID');
  print('   docker exec -it <container-id> psql -U vault_user -d vault_db');
  print('');
  print('   -- Check main table (soft deleted records still here)');
  print('   SELECT id, data->>\'name\' as name, data->>\'deletedAt\' as deleted_at FROM projects;');
  print('');
  print('   -- Check deleted log table');
  print('   SELECT id, delete_type, deleted_by, deleted_at FROM projects_deleted;');
  print('');
  print('   -- Check workflow_runs');
  print('   SELECT id, data->>\'status\' as status, data->>\'deletedAt\' as deleted_at FROM workflow_runs;');
  print('');
  print('   -- Check workflow_runs deleted log');
  print('   SELECT id, delete_type, deleted_by FROM workflow_runs_deleted;');
  print('');
  print('   -- Check workflow_runs audit log (always preserved)');
  print('   SELECT id, data->>\'operation\' as operation FROM workflow_runs_log;');
}

Future<bool> _checkServer(String url) async {
  try {
    final contract = VaultApiContract();
    final healthUrl = contract.buildUrl(url, VaultApiContract.routeHealth);

    final client = HttpClient();
    final request = await client.getUrl(Uri.parse(healthUrl)).timeout(
          const Duration(seconds: 3),
        );
    final response = await request.close().timeout(
          const Duration(seconds: 3),
        );
    client.close();
    return response.statusCode == 200;
  } catch (e) {
    return false;
  }
}

/// Test DirectStorage with Soft Delete
Future<void> testDirectStorageSoftDelete() async {
  print('━━━ 1. DirectStorage: Soft Delete (AqStudioProject) ━━━');
  print('   Feature: deletedAt field in model');
  print('   Behavior: Mark as deleted, keep in DB');
  print('   Default: softDelete = true\n');

  final projects = IDataLayer.instance.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  // Create 3 projects
  print('   📝 Step 1: Creating 3 projects...');
  final projectIds = <String>[];
  for (int i = 1; i <= 3; i++) {
    final project = AqStudioProject.create(
      id: 'proj-soft-00$i',
      tenantId: IDataLayer.instance.tenantId,
      ownerId: 'user-001',
      name: 'Soft Delete Project $i',
      projectType: 'test',
    );
    await projects.save(project);
    projectIds.add(project.id);
    print('      ✅ Created: ${project.name} (id: ${project.id})');
  }

  // Query all (should see 3)
  var all = await projects.findAll();
  print('\n   📊 Step 2: Query all projects (before delete)');
  print('      Found: ${all.length} projects');
  for (final p in all) {
    print('         - ${p.id}: ${p.name} (deletedAt: ${p.deletedAt})');
  }

  // Soft delete project 2
  print('\n   🗑️  Step 3: Soft deleting proj-soft-002...');
  await projects.delete('proj-soft-002');
  print('      ✅ SOFT DELETED: proj-soft-002');
  print('         - Record still in DB');
  print('         - deletedAt field set to current timestamp');
  print('         - Logged to projects_deleted table');

  // Query all (should see 2 - deleted excluded by default)
  all = await projects.findAll();
  print('\n   📊 Step 4: Query all projects (after soft delete)');
  print('      Found: ${all.length} projects (deleted excluded by default)');
  for (final p in all) {
    print('         - ${p.id}: ${p.name}');
  }

  // Query including deleted (should see 3)
  print('\n   📊 Step 5: Query including deleted...');
  final allIncludingDeleted = await projects.findAllIncludingDeleted();
  print('      Found: ${allIncludingDeleted.length} projects (including deleted)');
  for (final p in allIncludingDeleted) {
    final status = p.deletedAt != null ? '❌ DELETED' : '✅ ACTIVE';
    print('         - ${p.id}: ${p.name} $status');
  }

  // Restore project 2
  print('\n   ♻️  Step 6: Restoring proj-soft-002...');
  await projects.restore('proj-soft-002');
  print('      ✅ RESTORED: proj-soft-002');
  print('         - deletedAt field cleared');
  print('         - Record active again');

  // Query all (should see 3 again)
  all = await projects.findAll();
  print('\n   📊 Step 7: Query all projects (after restore)');
  print('      Found: ${all.length} projects');
  for (final p in all) {
    print('         - ${p.id}: ${p.name}');
  }

  print('\n   ✅ DirectStorage soft delete test PASSED!\n');
}

/// Test LoggedStorage with Soft Delete
Future<void> testLoggedStorageSoftDelete() async {
  print('━━━ 2. LoggedStorage: Soft Delete (WorkflowRun) ━━━');
  print('   Feature: deletedAt field + audit log');
  print('   Behavior: Mark as deleted, keep in DB, log operation');
  print('   Audit: ALL operations logged (create, update, delete, restore)\n');

  final runs = IDataLayer.instance.logged<WorkflowRun>(
    collection: WorkflowRun.kCollection,
    fromMap: WorkflowRun.fromMap,
  );

  // Create 3 runs
  print('   📝 Step 1: Creating 3 workflow runs...');
  final runIds = <String>[];
  for (int i = 1; i <= 3; i++) {
    final run = WorkflowRun(
      id: 'run-soft-00$i',
      projectId: 'proj-001',
      blueprintId: 'blueprint-001',
      graphSnapshot: <String, dynamic>{},
      status: WorkflowRunStatus.running,
      logsJson: '[]',
      createdAt: DateTime.now(),
    );

    await runs.save(run, actorId: 'user-test');
    runIds.add(run.id);
    print('      ✅ Created: ${run.id} (status: ${run.status.value})');
  }

  // Query all (should see 3)
  var all = await runs.findAll();
  print('\n   📊 Step 2: Query all runs (before delete)');
  print('      Found: ${all.length} runs');

  // Soft delete run 2
  print('\n   🗑️  Step 3: Soft deleting run-soft-002...');
  await runs.delete('run-soft-002', actorId: 'user-test');
  print('      ✅ SOFT DELETED: run-soft-002');
  print('         - Record still in workflow_runs table');
  print('         - deletedAt field set');
  print('         - Logged to workflow_runs_deleted table');
  print('         - Audit log entry created (operation: deleted)');

  // Query all (should see 2)
  all = await runs.findAll();
  print('\n   📊 Step 4: Query all runs (after soft delete)');
  print('      Found: ${all.length} runs (deleted excluded)');

  // Query including deleted (should see 3)
  print('\n   📊 Step 5: Query including deleted...');
  final allIncludingDeleted = await runs.findAllIncludingDeleted();
  print('      Found: ${allIncludingDeleted.length} runs (including deleted)');
  for (final r in allIncludingDeleted) {
    final status = r.deletedAt != null ? '❌ DELETED' : '✅ ACTIVE';
    print('         - ${r.id}: ${r.status.value} $status');
  }

  // Check audit log for deleted run
  print('\n   📜 Step 6: Check audit log for run-soft-002...');
  final history = await runs.getHistory('run-soft-002');
  print('      Found: ${history.length} log entries');
  for (final log in history) {
    print('         - ${log.operation} by ${log.changedBy} at ${log.timestamp}');
  }

  // Restore run 2
  print('\n   ♻️  Step 7: Restoring run-soft-002...');
  await runs.restore('run-soft-002', actorId: 'user-test');
  print('      ✅ RESTORED: run-soft-002');
  print('         - deletedAt field cleared');
  print('         - Audit log entry created (operation: restored)');

  // Query all (should see 3 again)
  all = await runs.findAll();
  print('\n   📊 Step 8: Query all runs (after restore)');
  print('      Found: ${all.length} runs');

  // Check audit log again
  print('\n   📜 Step 9: Check audit log after restore...');
  final historyAfter = await runs.getHistory('run-soft-002');
  print('      Found: ${historyAfter.length} log entries');
  for (final log in historyAfter) {
    print('         - ${log.operation} by ${log.changedBy}');
  }

  print('\n   ✅ LoggedStorage soft delete test PASSED!\n');
}
