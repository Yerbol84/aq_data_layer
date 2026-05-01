import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:dart_vault/server.dart';
import 'package:aq_schema/aq_schema.dart';
import 'package:postgres/postgres.dart';

void main() async {
  final dbHost = Platform.environment['DB_HOST'] ?? 'localhost';
  final dbPort = int.parse(Platform.environment['DB_PORT'] ?? '5432');
  final dbName = Platform.environment['DB_NAME'] ?? 'vault_db';
  final dbUser = Platform.environment['DB_USER'] ?? 'vault_user';
  final dbPassword = Platform.environment['DB_PASSWORD'] ?? 'vault_pass';
  final serverPort = int.parse(Platform.environment['SERVER_PORT'] ?? '8765');

  // Security mode: 'mock' enables MockVaultSecurityProtocol (for testing)
  // Default: null (no security — all allowed)
  final securityMode = Platform.environment['SECURITY_MODE'];
  if (securityMode == 'mock') {
    IVaultSecurityProtocol.initialize(MockVaultSecurityProtocol());
    print('🔒 Security mode: MOCK (test tokens active)');
  } else {
    print('🔓 Security mode: DISABLED (all operations allowed)');
  }

  print('🚀 Starting Data Service Server...');
  print('📊 Database: $dbHost:$dbPort/$dbName');

  final pool = Pool.withEndpoints(
    [
      Endpoint(
        host: dbHost,
        port: dbPort,
        database: dbName,
        username: dbUser,
        password: dbPassword,
      ),
    ],
    settings: PoolSettings(
      maxConnectionCount: 10,
      sslMode: SslMode.disable,
    ),
  );

  // Artifact binary storage (optional — enabled via ARTIFACT_PATH env var)
  final artifactPath = Platform.environment['ARTIFACT_PATH'];
  if (artifactPath != null) {
    print('📦 Artifact storage: $artifactPath');
  }

  // Vector storage — pgvector backed, registered in global registry
  // VECTOR_DIM: 8 for mock, 768 for nomic-embed-text, 1024 for mxbai-embed-large
  final vectorDim = int.parse(Platform.environment['VECTOR_DIM'] ?? '768');
  final vectorEmbedderId = Platform.environment['VECTOR_EMBEDDER_ID'] ?? 'ollama-nomic-embed-text';
  final vectorStorage = PgVectorStorage(pool: pool);
  final vectorRegistry = VectorStoreRegistryImpl();
  vectorRegistry.register(
    VectorStoreDescriptor(
      id: 'pgvector-main',
      type: 'pgvector',
      embedderId: vectorEmbedderId,
      vectorDim: vectorDim,
    ),
    vectorStorage,
  );
  print('🔍 Vector storage: pgvector (store=pgvector-main dim=$vectorDim embedder=$vectorEmbedderId)');

  // Register ALL AQ platform domains from AqDomains.all (single source of truth)
  final registry = VaultRegistry(
    storageFactory: (tenantId) => PostgresVaultStorage(
      pool: pool,
      tenantId: tenantId,
    ),
    deployer: PostgresSchemaDeployer(pool: pool),
    artifactBackend: artifactPath != null ? LocalArtifactStorage(basePath: artifactPath) : null,
    vectorRegistry: vectorRegistry,
  );

  for (final domain in AqDomains.all) {
    registry.register(DomainRegistration(
      collection: domain.collection,
      mode: _toStorageMode(domain.kind),
      fromMap: domain.fromMap,
      indexes: domain.indexes,
      jsonSchema: const {'type': 'object'}, // schema managed by model itself
    ));
  }

  await registry.deploy();
  print('✅ Schemas deployed (${registry.registrations.length} domains)');
  for (final r in registry.registrations) {
    print('   • ${r.collection} [${r.mode.name}]');
  }

  final contract = VaultApiContract();
  final router = Router()
    ..post(contract.getFullRoute('handshake'), _handleHandshake(registry))
    ..post(contract.getFullRoute('rpc'), _handleRpc(registry))
    ..get(contract.getFullRoute('health'), _handleHealth);

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_corsHeaders())
      .addHandler(router);

  final server = await io.serve(handler, '0.0.0.0', serverPort);
  print('✅ Server running on http://${server.address.host}:${server.port}');
}

Handler _handleHandshake(VaultRegistry registry) {
  return (Request request) async {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final tenantId = json['tenantId'] as String;
      return Response.ok(
        jsonEncode(registry.buildHandshake(tenantId)),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  };
}

Handler _handleRpc(VaultRegistry registry) {
  return (Request request) async {
    try {
      final json = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final result = await registry.dispatch(
        collection: json['collection'] as String,
        operation: json['operation'] as String,
        args: json['args'] as Map<String, dynamic>,
        tenantId: json['tenantId'] as String,
        headers: Map<String, String>.fromEntries(
          request.headers.entries.map((e) => MapEntry(e.key, e.value)),
        ),
      );
      return Response.ok(
        jsonEncode({'success': true, 'data': result}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'success': false, 'error': e.toString(), 'errorCode': _errorCode(e)}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  };
}

Response _handleHealth(Request request) => Response.ok(
      jsonEncode({'status': 'healthy', 'timestamp': DateTime.now().toIso8601String()}),
      headers: {'Content-Type': 'application/json'},
    );

Middleware _corsHeaders() {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  };
  return (handler) => (request) async {
        if (request.method == 'OPTIONS') return Response.ok('', headers: headers);
        return (await handler(request)).change(headers: headers);
      };
}

String _errorCode(Object e) {
  final s = e.toString();
  if (s.contains('not found') || s.contains('NotFoundException')) return 'NOT_FOUND';
  if (s.contains('Access denied') || s.contains('VaultAccessDeniedException')) return 'ACCESS_DENIED';
  if (s.contains('state') || s.contains('StateException')) return 'STATE_ERROR';
  return 'STORAGE_ERROR';
}

StorageMode _toStorageMode(StorageKind kind) => switch (kind) {
      StorageKind.direct => StorageMode.direct,
      StorageKind.versioned => StorageMode.versioned,
      StorageKind.logged => StorageMode.logged,
    };
