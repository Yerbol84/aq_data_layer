import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

void main() async {
  print('🎯 Console Client - Testing All Storage Modes\n');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('📋 Pre-flight Checks');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  // Check 1: Server reachability
  final serverUrl = Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';
  print('🔍 Checking server at $serverUrl...');
  final serverReachable = await _checkServer(serverUrl);

  if (serverReachable) {
    print('   ✅ Server is reachable');
  } else {
    print('   ❌ Server is NOT reachable');
    print('   ⚠️  Make sure Docker stack is running:');
    print('   💡 cd pkgs && docker compose -f dart_vault_package/example/stack/docker-compose.yml up\n');
    print('❌ ABORTING: Cannot proceed without server connection');
    exit(1);
  }

  // Check 2: Initialize data layer
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

  // Check 3: Verify actual connection
  final isConnected = IDataLayer.instance.isConnected;
  final endpoint = IDataLayer.instance.endpoint;
  final tenantId = IDataLayer.instance.tenantId;
  final serverVersion = IDataLayer.instance.serverVersion;

  print('   Endpoint: $endpoint');
  print('   Tenant: $tenantId');
  print('   Server Version: ${serverVersion ?? 'unknown'}');

  if (isConnected) {
    print('   ✅ Connected to REMOTE server (data will persist in PostgreSQL)');
  } else {
    print('   ❌ Using IN-MEMORY fallback (data will NOT persist!)');
    print('   ⚠️  This means the server is not responding properly');
    print('\n❌ ABORTING: Cannot proceed with in-memory storage');
    exit(1);
  }

  print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('✅ All checks passed - Starting tests');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  // Test Direct Storage (AqStudioProject)
  await testDirectStorage();

  // Test Logged Storage (WorkflowRun)
  await testLoggedStorage();

  // Test Direct Storage with migrations (TestDocument)
  await testMigrations();

  print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('✅ All tests completed successfully!');
  print('💾 Data is persisted in PostgreSQL database');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('\n📊 To view data in database:');
  print('   docker exec -it <postgres-container-id> psql -U vault_user -d vault_db');
  print('   SELECT * FROM projects;');
  print('   SELECT * FROM workflow_runs;');
  print('   SELECT * FROM workflow_runs_log;');
}

/// Check if server is reachable
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

/// Test DirectRepository with AqStudioProject
Future<void> testDirectStorage() async {
  print('━━━ Direct Storage: AqStudioProject ━━━');

  final projects = IDataLayer.instance.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  // Create
  final project = AqStudioProject.create(
    id: 'proj-001',
    tenantId: IDataLayer.instance.tenantId,
    ownerId: 'user-001',
    name: 'My Console Project',
    projectType: 'console',
  );

  await projects.save(project);
  print('✅ Created: ${project.name}');

  // Read
  final loaded = await projects.findById(project.id);
  if (loaded != null && loaded.name == project.name) {
    print('✅ Loaded: ${loaded.name}');
  } else {
    print('❌ Failed to load project');
    exit(1);
  }

  // Update
  final updated = project.copyWith(name: 'Updated Console Project');
  await projects.save(updated);
  final reloaded = await projects.findById(project.id);
  if (reloaded?.name == 'Updated Console Project') {
    print('✅ Updated: ${updated.name}');
  } else {
    print('❌ Failed to update project');
    exit(1);
  }

  // List
  final all = await projects.findAll();
  if (all.isNotEmpty) {
    print('✅ Total projects: ${all.length}');
  } else {
    print('❌ Failed to list projects');
    exit(1);
  }

  // Delete (soft delete — record stays with deletedAt set)
  await projects.delete(project.id);
  final deleted = await projects.findById(project.id);
  if (deleted == null) {
    print('✅ Deleted (hard): ${project.id}\n');
  } else if (deleted.toMap()['deletedAt'] != null) {
    print('✅ Soft deleted: ${project.id}\n');
  } else {
    print('❌ Failed to delete project');
    exit(1);
  }
}

/// Test LoggedRepository with WorkflowRun
Future<void> testLoggedStorage() async {
  print('━━━ Logged Storage: WorkflowRun ━━━');

  final runs = IDataLayer.instance.logged<WorkflowRun>(
    collection: WorkflowRun.kCollection,
    fromMap: WorkflowRun.fromMap,
  );

  // Create
  final run = WorkflowRun(
    id: 'run-001',
    projectId: 'proj-001',
    blueprintId: 'blueprint-001',
    graphSnapshot: <String, dynamic>{},
    status: WorkflowRunStatus.running,
    logsJson: '[]',
    contextJson: '{}',
    createdAt: DateTime.now(),
  );

  await runs.save(run, actorId: 'user-001');
  final created = await runs.findById(run.id);
  if (created != null) {
    print('✅ Created run: ${run.id}');
  } else {
    print('❌ Failed to create run');
    exit(1);
  }

  // Update status (logged)
  final running = run.copyWith(status: WorkflowRunStatus.running);
  await runs.save(running, actorId: 'user-001');
  print('✅ Status: ${running.status.value}');

  final completed = running.copyWith(status: WorkflowRunStatus.completed);
  await runs.save(completed, actorId: 'user-001');
  final updated = await runs.findById(run.id);
  if (updated?.status == WorkflowRunStatus.completed) {
    print('✅ Status: ${completed.status.value}');
  } else {
    print('❌ Failed to update status');
    exit(1);
  }

  // Get audit log
  final logs = await runs.getHistory(run.id);
  if (logs.length >= 3) {
    print('✅ Audit log entries: ${logs.length}');
    for (final log in logs) {
      print('   - ${log.operation} at ${log.changedAt}');
    }
  } else {
    print('❌ Audit log incomplete (expected >= 3, got ${logs.length})');
    exit(1);
  }

  // Delete
  await runs.delete(run.id, actorId: 'user-001');
  final deleted = await runs.findById(run.id);
  if (deleted == null || deleted.toMap()['deletedAt'] != null) {
    print('✅ Deleted: ${run.id}\n');
  } else {
    print('❌ Failed to delete run');
    exit(1);
  }
}

/// Test migrations with TestDocument
Future<void> testMigrations() async {
  print('━━━ Direct Storage with Migrations: TestDocument ━━━');

  final docs = IDataLayer.instance.direct<TestDocumentV1>(
    collection: TestDocumentV1.kCollection,
    fromMap: TestDocumentV1.fromMap,
  );

  // Create
  final doc = TestDocumentV1(
    id: 'doc-001',
    tenantId: IDataLayer.instance.tenantId,
    title: 'Test Document',
    content: 'This is a test document with some content for migration testing.',
  );

  await docs.save(doc);
  print('✅ Created: ${doc.title}');

  // Read
  final loaded = await docs.findById(doc.id);
  if (loaded != null && loaded.title == doc.title && loaded.content == doc.content) {
    print('✅ Loaded: ${loaded.title}');
    print('   Content: ${loaded.content}');
  } else {
    print('❌ Failed to load document or content mismatch');
    exit(1);
  }

  // List
  final all = await docs.findAll();
  if (all.isNotEmpty) {
    print('✅ Total documents: ${all.length}');
  } else {
    print('❌ Failed to list documents');
    exit(1);
  }

  // Delete
  await docs.delete(doc.id);
  final deleted = await docs.findById(doc.id);
  if (deleted == null || deleted.toMap()['deletedAt'] != null) {
    print('✅ Deleted: ${doc.id}\n');
  } else {
    print('❌ Failed to delete document');
    exit(1);
  }
}
