// example/client_example.dart
/// Client Example - Thin Client Pattern with IDataLayer
///
/// This example shows how to use IDataLayer to connect to a remote Data Service.
/// The client knows NOTHING about PostgreSQL, schemas, or migrations!
///
/// Prerequisites:
/// - Data Service running on http://localhost:8765
/// - Run server first: dart run example/server_example.dart
///
/// Then run this client:
/// - dart run example/client_example.dart
library;

import 'package:dart_vault/dart_vault.dart';
import 'package:aq_schema/aq_schema.dart';

void main() async {
  print('🚀 Client Example - Thin Client Pattern\n');

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 1: Initialize IDataLayer (ONE POINT!)
  // ═══════════════════════════════════════════════════════════════════════

  print('📡 Connecting to Data Service...');

  await IDataLayer.initialize(
    endpoint: 'http://localhost:8765',
    useBuffer: true, // Enable offline-first buffer
  );

  print('✅ Connected to Data Service');
  print('   Endpoint: ${IDataLayer.instance.endpoint}');
  print('   Tenant: ${IDataLayer.instance.tenantId}');
  print('   Connected: ${IDataLayer.instance.isConnected}');
  print('   Server version: ${IDataLayer.instance.serverVersion}\n');

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 2: Get repositories (domains from aq_schema!)
  // ═══════════════════════════════════════════════════════════════════════

  print('📦 Getting repositories...');

  final workflows = IDataLayer.instance.versioned<WorkflowGraph>(
    collection: WorkflowGraph.kCollection,
    fromMap: WorkflowGraph.fromMap,
  );

  final projects = IDataLayer.instance.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  print('✅ Repositories ready\n');

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 3: Work with Projects (Direct Repository)
  // ═══════════════════════════════════════════════════════════════════════

  print('📁 Creating project...');

  final project = AqStudioProject(
    id: 'proj-client-1',
    tenantId: IDataLayer.instance.tenantId,
    ownerId: IDataLayer.instance.tenantId,
    name: 'Client Example Project',
    path: '/projects/client-example',
    projectType: 'workflow',
    lastOpened: DateTime.now(),
  );

  await projects.save(project);
  print('✅ Project created: ${project.name}');

  final allProjects = await projects.findAll();
  print('📋 Total projects: ${allProjects.length}\n');

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 4: Work with Workflows (Versioned Repository)
  // ═══════════════════════════════════════════════════════════════════════

  print('📊 Creating workflow...');

  final workflow = WorkflowGraph(
    id: 'wf-client-1',
    tenantId: IDataLayer.instance.tenantId,
    ownerId: IDataLayer.instance.tenantId,
    name: 'Client Workflow',
    nodes: const {},
    edges: const {},
  );

  final node = await workflows.createEntity(workflow);
  print('✅ Workflow created: ${node.nodeId}');
  print('   Status: ${node.status}');
  print('   Version: ${node.version}');

  // Publish
  print('\n📤 Publishing workflow...');
  await workflows.publishDraft(node.nodeId, increment: IncrementType.minor);
  print('✅ Published');

  // Set as current
  await workflows.setCurrentVersion(
    workflow.id,
    node.nodeId,
    requesterId: IDataLayer.instance.tenantId,
  );
  print('✅ Set as current version');

  // Get current
  final current = await workflows.getCurrent(workflow.id);
  print('\n📌 Current version:');
  print('   Name: ${current?.name}');
  print('   ID: ${current?.id}');

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 5: Buffer Management (Offline-First)
  // ═══════════════════════════════════════════════════════════════════════

  print('\n💾 Buffer management...');

  final buffer = IDataLayer.instance.buffer;
  if (buffer != null) {
    final isDirty = buffer.isDirty(
      WorkflowGraph.kCollection,
      workflow.id,
    );
    print('   Has unsaved changes: $isDirty');

    if (isDirty) {
      await buffer.flush(
        WorkflowGraph.kCollection,
        id: workflow.id,
      );
      print('   ✅ Flushed to server');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // DONE! Client knows NOTHING about PostgreSQL, schemas, migrations
  // ═══════════════════════════════════════════════════════════════════════

  print('\n🎉 Client example completed!\n');
  print('Key takeaways:');
  print('  ✅ Used IDataLayer.initialize() - one point initialization');
  print('  ✅ Used IDataLayer.instance - one point access');
  print('  ✅ Worked with aq_schema domains (WorkflowGraph, AqStudioProject)');
  print('  ✅ Client has ZERO knowledge of storage/database');
  print('  ✅ Thin client pattern - no business logic here');
}
