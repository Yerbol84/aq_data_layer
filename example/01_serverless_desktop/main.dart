// example/01_serverless_desktop.dart
/// Serverless Desktop Example - No HTTP, No Docker
///
/// This example shows the SIMPLEST usage of dart_vault:
/// - Single Dart application
/// - InMemory storage (no database needed)
/// - No HTTP server
/// - Just run: dart run example/01_serverless_desktop.dart
///
/// Perfect for:
/// - Learning the API
/// - Quick prototyping
/// - Desktop applications
/// - Testing
library;

import 'package:dart_vault/server.dart';
import 'package:aq_schema/aq_schema.dart';

void main() async {
  print('🚀 Serverless Desktop Example\n');

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 1: Initialize IDataLayer with InMemory storage
  // ═══════════════════════════════════════════════════════════════════════

  print('📦 Initializing IDataLayer with InMemory storage...');

  // For serverless mode, we create Vault with InMemory storage directly
  // This is a special case - normally you'd use IDataLayer.initialize() with remote endpoint
  final vault = Vault(
    storage: InMemoryVaultStorage(tenantId: 'demo-user'),
    tenantId: 'demo-user',
  );

  print('✅ IDataLayer initialized\n');

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 2: Work with Direct Repository (AqStudioProject)
  // ═══════════════════════════════════════════════════════════════════════

  print('📁 Working with Direct Repository (AqStudioProject)...\n');

  final projects = vault.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  // Create projects
  final project1 = AqStudioProject(
    id: 'proj-1',
    tenantId: 'demo-user',
    ownerId: 'demo-user',
    name: 'My First Project',
    path: '/projects/first',
    projectType: 'workflow',
    lastOpened: DateTime.now(),
  );

  await projects.save(project1);
  print('✅ Created project: ${project1.name}');

  final project2 = AqStudioProject(
    id: 'proj-2',
    tenantId: 'demo-user',
    ownerId: 'demo-user',
    name: 'Production App',
    path: '/projects/production',
    projectType: 'workflow',
    lastOpened: DateTime.now(),
  );

  await projects.save(project2);
  print('✅ Created project: ${project2.name}');

  // List all projects
  final allProjects = await projects.findAll();
  print('\n📋 All projects (${allProjects.length}):');
  for (final p in allProjects) {
    print('   - ${p.name}: ${p.path}');
  }

  // Find by ID
  final found = await projects.findById('proj-1');
  print('\n🔍 Found by ID: ${found?.name}');

  // Update
  final updated = AqStudioProject(
    id: project1.id,
    tenantId: project1.tenantId,
    ownerId: project1.ownerId,
    name: 'My First Project (Updated)',
    path: project1.path,
    projectType: project1.projectType,
    lastOpened: DateTime.now(),
  );
  await projects.save(updated);
  print('✅ Updated project name');

  // Count
  final count = await projects.count();
  print('📊 Total projects: $count\n');

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 3: Work with Versioned Repository (WorkflowGraph)
  // ═══════════════════════════════════════════════════════════════════════

  print('📊 Working with Versioned Repository (WorkflowGraph)...\n');

  final workflows = vault.versioned<WorkflowGraph>(
    collection: WorkflowGraph.kCollection,
    fromMap: WorkflowGraph.fromMap,
  );

  // Create workflow (starts as DRAFT)
  final workflow = WorkflowGraph(
    id: 'wf-1',
    tenantId: 'demo-user',
    ownerId: 'demo-user',
    name: 'Data Processing Pipeline',
    nodes: const {},
    edges: const {},
  );

  final node = await workflows.createEntity(workflow);
  print('✅ Created workflow: ${workflow.name}');
  print('   Node ID: ${node.nodeId}');
  print('   Status: ${node.status}');
  print('   Version: ${node.version}');

  // Update draft
  final updated2 = WorkflowGraph(
    id: workflow.id,
    tenantId: workflow.tenantId,
    ownerId: workflow.ownerId,
    name: 'Data Processing Pipeline v2',
    nodes: const {},
    edges: const {},
  );
  await workflows.updateDraft(node.nodeId, updated2);
  print('✅ Updated draft');

  // Publish (creates v1.0.0)
  final published = await workflows.publishDraft(
    node.nodeId,
    increment: IncrementType.minor,
  );
  print('✅ Published as version: ${published.version}');
  print('   Status: ${published.status}');

  // Set as current version
  await workflows.setCurrentVersion(
    workflow.id,
    published.nodeId,
    requesterId: 'demo-user',
  );
  print('✅ Set as current version');

  // Get current version
  final current = await workflows.getCurrent(workflow.id);
  print('\n📌 Current version:');
  print('   Name: ${current?.name}');
  print('   ID: ${current?.id}');

  // List all versions
  final allVersions = await workflows.listVersions(workflow.id);
  print('\n📜 Version history (${allVersions.length} versions):');
  for (final v in allVersions) {
    print('   - ${v.version} (${v.status}) - ${v.data['name']}');
  }

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 4: Demonstrate multi-tenancy
  // ═══════════════════════════════════════════════════════════════════════

  print('\n🏢 Multi-tenancy demonstration...\n');

  // Create another tenant's vault
  final vault2 = Vault(
    storage: InMemoryVaultStorage(tenantId: 'other-user'),
    tenantId: 'other-user',
  );

  final projects2 = vault2.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  final otherProject = AqStudioProject(
    id: 'proj-100',
    tenantId: 'other-user',
    ownerId: 'other-user',
    name: 'Other User Project',
    path: '/projects/other',
    projectType: 'workflow',
    lastOpened: DateTime.now(),
  );

  await projects2.save(otherProject);

  final demoCount = await projects.count();
  final otherCount = await projects2.count();

  print('📊 Tenant isolation:');
  print('   demo-user projects: $demoCount');
  print('   other-user projects: $otherCount');
  print('   ✅ Data is isolated by tenant!\n');

  // ═══════════════════════════════════════════════════════════════════════
  // DONE!
  // ═══════════════════════════════════════════════════════════════════════

  print('🎉 Serverless example completed!\n');
  print('Key takeaways:');
  print('  ✅ No HTTP server needed');
  print('  ✅ No database setup needed');
  print('  ✅ Works with real aq_schema domains');
  print('  ✅ Direct, Versioned, and Logged repositories');
  print('  ✅ Multi-tenancy built-in');
  print('  ✅ Perfect for desktop apps and prototyping');

  await vault.dispose();
}
