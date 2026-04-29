// example/server_example.dart
/// Server Example - VaultRegistry Setup
///
/// This example shows how to set up VaultRegistry on the server side:
/// - Register domains from aq_schema (WorkflowGraph, AqStudioProject)
/// - Deploy schema (create tables)
/// - Use registry for RPC dispatch
///
/// Note: This example shows registry setup only.
/// For HTTP server, use your own transport layer (shelf, dart:io, etc.)
///
/// Run this example:
/// - dart run example/server_example.dart
library;

import 'package:dart_vault/server.dart';
import 'package:aq_schema/aq_schema.dart';

void main() async {
  print('🚀 Data Service Server Example\n');

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 1: Create VaultRegistry with storage factory
  // ═══════════════════════════════════════════════════════════════════════

  print('📦 Creating VaultRegistry...');

  // For this example, use InMemory storage (no database needed)
  // In production, use PostgresVaultStorage with real database
  final registry = VaultRegistry(
    storageFactory: (tenantId) => InMemoryVaultStorage(tenantId: tenantId),
    // In production:
    // storageFactory: (tenantId) => PostgresVaultStorage(
    //   pool: postgresPool,
    //   tenantId: tenantId,
    // ),
    // deployer: PostgresSchemaDeployer(pool: postgresPool),
  );

  print('✅ Registry created\n');

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 2: Register domains from aq_schema (SOURCE OF TRUTH!)
  // ═══════════════════════════════════════════════════════════════════════

  print('📝 Registering domains from aq_schema...');

  // Register WorkflowGraph (Versioned)
  registry.register(DomainRegistration(
    collection: WorkflowGraph.kCollection,
    mode: StorageMode.versioned,
    fromMap: WorkflowGraph.fromMap,
    jsonSchema: WorkflowGraph.kJsonSchema,
    indexes: [
      VaultIndex(name: 'idx_workflow_name', field: 'name'),
      VaultIndex(name: 'idx_workflow_owner', field: 'ownerId'),
    ],
  ));
  print('   ✅ WorkflowGraph (versioned)');

  // Register AqStudioProject (Direct)
  registry.register(DomainRegistration(
    collection: AqStudioProject.kCollection,
    mode: StorageMode.direct,
    fromMap: AqStudioProject.fromMap,
    jsonSchema: AqStudioProject.kJsonSchema,
    indexes: [
      VaultIndex(name: 'idx_project_name', field: 'name'),
      VaultIndex(name: 'idx_project_owner', field: 'ownerId'),
    ],
  ));
  print('   ✅ AqStudioProject (direct)');

  print('\n✅ Registered ${registry.registrations.length} domains\n');

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 3: Deploy schema (creates tables automatically!)
  // ═══════════════════════════════════════════════════════════════════════

  print('🔨 Deploying schema...');
  await registry.deploy();
  print('✅ Schema deployed (tables created)\n');

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 4: Test handshake and RPC dispatch
  // ═══════════════════════════════════════════════════════════════════════

  print('🤝 Testing handshake...');
  final handshake = registry.buildHandshake('demo-tenant');
  print('   Server version: ${handshake['serverVersion']}');
  print('   Collections: ${(handshake['collections'] as List).length}');
  print('   Capabilities: ${handshake['capabilities']}');

  print('\n📡 Testing RPC dispatch...');

  // Example: Create a project via RPC
  final createResult = await registry.dispatch(
    collection: AqStudioProject.kCollection,
    operation: 'save',
    args: {
      'entity': {
        'id': 'proj-server-1',
        'tenantId': 'demo-tenant',
        'ownerId': 'demo-tenant',
        'name': 'Server Example Project',
        'path': '/projects/server',
        'projectType': 'workflow',
        'lastOpened': DateTime.now().toIso8601String(),
      },
    },
    tenantId: 'demo-tenant',
  );
  print('   ✅ Created project via RPC');

  // Example: Find all projects via RPC
  final findResult = await registry.dispatch(
    collection: AqStudioProject.kCollection,
    operation: 'findAll',
    args: {},
    tenantId: 'demo-tenant',
  );
  print('   ✅ Found ${(findResult as List).length} projects via RPC');

  // ═══════════════════════════════════════════════════════════════════════
  // DONE!
  // ═══════════════════════════════════════════════════════════════════════

  print('\n🎉 Server example completed!\n');
  print('Key takeaways:');
  print('  ✅ VaultRegistry manages domain registrations');
  print('  ✅ Domains registered from aq_schema (source of truth)');
  print('  ✅ Schema deployed automatically');
  print('  ✅ Handshake provides client metadata');
  print('  ✅ RPC dispatch routes operations to repositories');
  print('\n💡 For HTTP server, wrap registry.dispatch() in your transport layer');
  print('   (shelf, dart:io HttpServer, or any other HTTP framework)');
}
