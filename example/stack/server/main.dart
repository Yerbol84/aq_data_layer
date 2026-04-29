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

  print('🚀 Starting Data Service Server...');
  print('📊 Database: $dbHost:$dbPort/$dbName');

  // Create PostgreSQL connection pool
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

  // Initialize VaultRegistry with PostgreSQL
  final registry = VaultRegistry(
    storageFactory: (tenantId) => PostgresVaultStorage(
      pool: pool,
      tenantId: tenantId,
    ),
    deployer: PostgresSchemaDeployer(pool: pool),
  );

  // Register domains
  registry.register(DomainRegistration(
    collection: AqStudioProject.kCollection,
    mode: StorageMode.direct,
    fromMap: AqStudioProject.fromMap,
    jsonSchema: AqStudioProject.kJsonSchema,
    schemaVersion: AqStudioProject.kSchemaVersion,
  ));

  registry.register(DomainRegistration(
    collection: WorkflowRun.kCollection,
    mode: StorageMode.logged,
    fromMap: WorkflowRun.fromMap,
    jsonSchema: WorkflowRun.kJsonSchema,
  ));

  registry.register(DomainRegistration(
    collection: TestDocumentV1.kCollection,
    mode: StorageMode.direct,
    fromMap: TestDocumentV1.fromMap,
    jsonSchema: const {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'tenantId': {'type': 'string'},
        'title': {'type': 'string'},
        'content': {'type': 'string'},
      },
      'required': ['id', 'tenantId', 'title', 'content'],
    },
  ));

  // Deploy schemas
  await registry.deploy();
  print('✅ Schemas deployed');

  // Setup HTTP routes using VaultApiContract
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
  print('📋 API Version: ${contract.apiVersion}');
  print('📋 Routes:');
  print('   ${contract.getFullRoute('handshake')}');
  print('   ${contract.getFullRoute('rpc')}');
  print('   ${contract.getFullRoute('health')}');
}

Handler _handleHandshake(VaultRegistry registry) {
  return (Request request) async {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final tenantId = json['tenantId'] as String;
      final response = registry.buildHandshake(tenantId);

      return Response.ok(
        jsonEncode(response),
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
      final body = await request.readAsString();
      print('📥 RPC Request received:');
      print('   Body length: ${body.length} bytes');
      print('   Body: ${body.substring(0, body.length > 500 ? 500 : body.length)}');

      final json = jsonDecode(body) as Map<String, dynamic>;

      final collection = json['collection'] as String;
      final operation = json['operation'] as String;
      final args = json['args'] as Map<String, dynamic>;
      final tenantId = json['tenantId'] as String;

      print('   Collection: $collection');
      print('   Operation: $operation');
      print('   TenantId: $tenantId');
      print('   Args keys: ${args.keys.join(", ")}');

      final response = await registry.dispatch(
        collection: collection,
        operation: operation,
        args: args,
        tenantId: tenantId,
      );

      print('📤 RPC Response:');
      print('   Response type: ${response.runtimeType}');
      print('   Response: $response');

      // Wrap response in VaultRpcResponse format
      final responseData = {
        'success': true,
        'data': response,
      };

      final responseJson = jsonEncode(responseData);
      print('   JSON length: ${responseJson.length} bytes');
      print('   JSON: ${responseJson.substring(0, responseJson.length > 500 ? 500 : responseJson.length)}');

      return Response.ok(
        responseJson,
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e, stack) {
      print('❌ RPC Error: $e');
      print('   Stack: $stack');

      // Wrap error in VaultRpcResponse format
      final errorResponse = {
        'success': false,
        'error': e.toString(),
        'errorCode': _getErrorCode(e),
      };

      return Response.internalServerError(
        body: jsonEncode(errorResponse),
        headers: {'Content-Type': 'application/json'},
      );
    }
  };
}

Response _handleHealth(Request request) {
  return Response.ok(
    jsonEncode({'status': 'healthy', 'timestamp': DateTime.now().toIso8601String()}),
    headers: {'Content-Type': 'application/json'},
  );
}

Middleware _corsHeaders() {
  return (Handler handler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: _corsHeadersMap);
      }
      final response = await handler(request);
      return response.change(headers: _corsHeadersMap);
    };
  };
}

final _corsHeadersMap = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

String _getErrorCode(Object error) {
  final errorStr = error.toString();
  if (errorStr.contains('not found') || errorStr.contains('NotFoundException')) {
    return 'NOT_FOUND';
  }
  if (errorStr.contains('access denied') || errorStr.contains('AccessDeniedException')) {
    return 'ACCESS_DENIED';
  }
  if (errorStr.contains('state') || errorStr.contains('StateException')) {
    return 'STATE_ERROR';
  }
  return 'STORAGE_ERROR';
}
