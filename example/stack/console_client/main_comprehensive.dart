import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

void main() async {
  print('🎯 Comprehensive Storage Mode Demo\n');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('📋 Pre-flight Checks');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  final serverUrl = 'http://localhost:8765';
  print('🔍 Checking server at $serverUrl...');
  final serverReachable = await _checkServer(serverUrl);

  if (!serverReachable) {
    print('   ❌ Server is NOT reachable');
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
  print('📚 Storage Mode Comparison');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  await testDirectStorage();
  await testLoggedStorage();
  await testDirectStorageWithMigrations();

  print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('✅ All tests completed!');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('\n📊 Database state:');
  print(
      '   docker exec -it <postgres-container> psql -U vault_user -d vault_db');
  print('   \\dt  -- list all tables');
  print('   SELECT id, data->\'name\' as name FROM projects;');
  print('   SELECT id, data->\'title\' as title FROM test_documents;');
  print('   SELECT id FROM workflow_runs;');
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

/// DirectStorage: Simple CRUD with HARD DELETE
/// - Physical removal from database
/// - No history, no versions
/// - Optional soft delete if model implements it
Future<void> testDirectStorage() async {
  print('━━━ 1. DirectStorage: AqStudioProject ━━━');
  print('   Mode: Simple CRUD');
  print('   Delete: HARD (physical removal)');
  print('   History: None');
  print('   Use case: Settings, metadata, simple entities\n');

  final projects = IDataLayer.instance.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  // Create 5 projects
  print('   📝 Creating 5 projects...');
  for (int i = 1; i <= 5; i++) {
    final project = AqStudioProject.create(
      id: 'proj-direct-00$i',
      tenantId: IDataLayer.instance.tenantId,
      ownerId: 'user-001',
      name: 'Direct Project $i',
      projectType: 'console',
    );
    await projects.save(project);
    print('      ✅ Created: ${project.name} (id: ${project.id})');
  }

  // Update one
  final toUpdate = await projects.findById('proj-direct-003');
  if (toUpdate != null) {
    final updated = toUpdate.copyWith(name: 'UPDATED Direct Project 3');
    await projects.save(updated);
    print('   ✅ Updated: proj-direct-003 → ${updated.name}');
  }

  // Delete 2 projects (hard delete)
  print('   🗑️  Hard deleting 2 projects...');
  await projects.delete('proj-direct-002');
  print('      ✅ DELETED: proj-direct-002 (physically removed from DB)');

  await projects.delete('proj-direct-004');
  print('      ✅ DELETED: proj-direct-004 (physically removed from DB)');

  // Show what remains in DB
  final remaining = await projects.findAll();
  print('   📊 REMAINING IN DB: ${remaining.length} projects');
  for (final p in remaining) {
    print('      - ${p.id}: ${p.name}');
  }
  print('   💾 These records are in PostgreSQL table: projects\n');
}

/// VersionedStorage: Version control with SOFT DELETE
/// - Multiple versions per entity (draft, published, snapshot)
/// - Branches support (main, feature branches)
/// - Soft delete via state flag (state: deleted)
/// - NO hard delete - versions are permanent
Future<void> testDirectStorageWithMigrations() async {
  print('━━━ 2. DirectStorage with Migrations: TestDocument ━━━');
  print('   Mode: Simple CRUD with schema versioning');
  print('   Delete: HARD (physical removal)');
  print('   History: None');
  print('   Use case: Documents with schema migrations\n');

  final docs = IDataLayer.instance.direct<TestDocumentV1>(
    collection: TestDocumentV1.kCollection,
    fromMap: TestDocumentV1.fromMap,
  );

  // Create 4 documents
  print('   📝 Creating 4 test documents...');
  for (int i = 1; i <= 4; i++) {
    final doc = TestDocumentV1(
      id: 'doc-test-00$i',
      tenantId: IDataLayer.instance.tenantId,
      title: 'Test Document $i',
      content: 'Content for document $i with some text.',
    );
    await docs.save(doc);
    print('      ✅ Created: ${doc.title} (id: ${doc.id})');
  }

  // Update one
  final toUpdate = await docs.findById('doc-test-002');
  if (toUpdate != null) {
    final updated = TestDocumentV1(
      id: toUpdate.id,
      tenantId: toUpdate.tenantId,
      title: 'UPDATED Test Document 2',
      content: 'This content was updated.',
    );
    await docs.save(updated);
    print('   ✅ Updated: doc-test-002 → ${updated.title}');
  }

  // Delete 1 document
  print('   🗑️  Hard deleting 1 document...');
  await docs.delete('doc-test-003');
  print('      ✅ DELETED: doc-test-003 (physically removed from DB)');

  // Show remaining
  final remaining = await docs.findAll();
  print('   📊 REMAINING IN DB: ${remaining.length} documents');
  for (final d in remaining) {
    print('      - ${d.id}: ${d.title}');
  }
  print('   💾 These records are in PostgreSQL table: test_documents\n');
}

/// LoggedStorage: Audit trail with HARD DELETE
/// - Every change logged to {collection}_log table
/// - Audit trail persists even after hard delete
/// - Full diff tracking
Future<void> testLoggedStorage() async {
  print('━━━ 3. LoggedStorage: WorkflowRun ━━━');
  print('   Mode: Audit trail');
  print('   Delete: HARD (but audit trail persists)');
  print('   History: Full audit log in {collection}_log table');
  print('   Use case: Sessions, runs, auditable operations\n');

  final runs = IDataLayer.instance.logged<WorkflowRun>(
    collection: WorkflowRun.kCollection,
    fromMap: WorkflowRun.fromMap,
  );

  // Create 4 runs
  print('   📝 Creating 4 workflow runs...');
  final runIds = <String>[];
  for (int i = 1; i <= 4; i++) {
    final run = WorkflowRun(
      id: 'run-logged-00$i',
      projectId: 'proj-001',
      blueprintId: 'blueprint-001',
      graphSnapshot: <String, dynamic>{},
      status: WorkflowRunStatus.running,
      logsJson: '[]',
      contextJson: '{}',
      createdAt: DateTime.now(),
    );

    await runs.save(run, actorId: 'user-001');
    runIds.add(run.id);
    print('      ✅ Created: ${run.id} (status: ${run.status.value})');

    // Update status for first 3
    if (i <= 3) {
      final completed = run.copyWith(status: WorkflowRunStatus.completed);
      await runs.save(completed, actorId: 'user-001');
      print('         Updated: status → completed');
    }
  }

  // Hard delete 2 runs
  print('   🗑️  Hard deleting 2 runs...');
  await runs.delete('run-logged-002', actorId: 'system');
  print('      ✅ DELETED: run-logged-002 (removed from workflow_runs table)');

  await runs.delete('run-logged-004', actorId: 'system');
  print('      ✅ DELETED: run-logged-004 (removed from workflow_runs table)');

  // Show remaining in main table
  final remaining = await runs.findAll();
  print('   📊 REMAINING IN workflow_runs TABLE: ${remaining.length} runs');
  for (final r in remaining) {
    print('      - ${r.id}: ${r.status.value}');
  }

  // Show audit logs for ALL runs (including deleted)
  print('   📊 AUDIT LOGS (including deleted runs):');
  for (final runId in runIds) {
    final logs = await runs.getHistory(runId);
    print('      $runId: ${logs.length} log entries');
    for (final log in logs) {
      print('         - ${log.operation} by ${log.changedBy}');
    }
  }
  print('   💾 Main records: workflow_runs table');
  print('   💾 Audit logs: workflow_runs_log table (persists forever)\n');
}
