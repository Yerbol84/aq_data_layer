import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

void main() async {
  print('🎯 Console Client - Testing WITHOUT Cleanup\n');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('📋 Pre-flight Checks');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  final serverUrl = 'http://localhost:8765';
  print('🔍 Checking server at $serverUrl...');
  final serverReachable = await _checkServer(serverUrl);

  if (serverReachable) {
    print('   ✅ Server is reachable');
  } else {
    print('   ❌ Server is NOT reachable');
    exit(1);
  }

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

  final isConnected = IDataLayer.instance.isConnected;
  if (isConnected) {
    print('   ✅ Connected to REMOTE server');
  } else {
    print('   ❌ Using IN-MEMORY fallback');
    exit(1);
  }

  print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('✅ Starting tests (data will persist in DB)');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  await testDirectStorage();
  await testLoggedStorage();
  await testMigrations();

  print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('✅ All tests completed - Data persisted in PostgreSQL!');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('\n📊 Check database:');
  print('   docker exec -it <postgres-container> psql -U vault_user -d vault_db');
  print('   SELECT * FROM projects;');
  print('   SELECT * FROM workflow_runs;');
  print('   SELECT * FROM test_documents;');
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

Future<void> testDirectStorage() async {
  print('━━━ Direct Storage: AqStudioProject ━━━');

  final projects = IDataLayer.instance.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  final project = AqStudioProject.create(
    id: 'proj-persist-001',
    tenantId: IDataLayer.instance.tenantId,
    ownerId: 'user-001',
    name: 'Persistent Console Project',
    projectType: 'console',
  );

  await projects.save(project);
  print('✅ Created: ${project.name}');

  final loaded = await projects.findById(project.id);
  if (loaded != null && loaded.name == project.name) {
    print('✅ Loaded: ${loaded.name}');
  } else {
    print('❌ Failed to load project');
    exit(1);
  }

  final updated = project.copyWith(name: 'Updated Persistent Project');
  await projects.save(updated);
  final reloaded = await projects.findById(project.id);
  if (reloaded?.name == 'Updated Persistent Project') {
    print('✅ Updated: ${updated.name}');
  } else {
    print('❌ Failed to update project');
    exit(1);
  }

  print('✅ Project persisted (NOT deleted)\n');
}

Future<void> testLoggedStorage() async {
  print('━━━ Logged Storage: WorkflowRun ━━━');

  final runs = IDataLayer.instance.logged<WorkflowRun>(
    collection: WorkflowRun.kCollection,
    fromMap: WorkflowRun.fromMap,
  );

  final run = WorkflowRun(
    id: 'run-persist-001',
    projectId: 'proj-persist-001',
    blueprintId: 'blueprint-001',
    graphSnapshot: <String, dynamic>{},
    status: WorkflowRunStatus.running,
    logsJson: '[]',
    contextJson: '{}',
    createdAt: DateTime.now(),
  );

  await runs.save(run, actorId: 'user-001');
  print('✅ Created run: ${run.id}');

  final running = run.copyWith(status: WorkflowRunStatus.running);
  await runs.save(running, actorId: 'user-001');
  print('✅ Status: ${running.status.value}');

  final completed = running.copyWith(status: WorkflowRunStatus.completed);
  await runs.save(completed, actorId: 'user-001');
  print('✅ Status: ${completed.status.value}');

  final logs = await runs.getHistory(run.id);
  print('✅ Audit log entries: ${logs.length}');

  print('✅ Run persisted (NOT deleted)\n');
}

Future<void> testMigrations() async {
  print('━━━ Direct Storage: TestDocument ━━━');

  final docs = IDataLayer.instance.direct<TestDocumentV1>(
    collection: TestDocumentV1.kCollection,
    fromMap: TestDocumentV1.fromMap,
  );

  final doc = TestDocumentV1(
    id: 'doc-persist-001',
    tenantId: IDataLayer.instance.tenantId,
    title: 'Persistent Test Document',
    content: 'This document will remain in the database.',
  );

  await docs.save(doc);
  print('✅ Created: ${doc.title}');

  final loaded = await docs.findById(doc.id);
  if (loaded != null && loaded.title == doc.title) {
    print('✅ Loaded: ${loaded.title}');
  } else {
    print('❌ Failed to load document');
    exit(1);
  }

  print('✅ Document persisted (NOT deleted)\n');
}
