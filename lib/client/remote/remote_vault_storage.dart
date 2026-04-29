import 'dart:async';
import 'dart:convert';

import 'package:aq_schema/aq_schema.dart';
import 'package:http/http.dart' as http;

import '../../exceptions/vault_exceptions.dart';
import 'remote_vault_schema.dart';

/// [VaultStorage] that forwards every operation to a remote Data Service
/// over HTTP (the dart_vault RPC protocol).
///
/// ## How it works
///
/// 1. On first use (or explicit [connect]), sends a handshake request to
///    the endpoint defined in [VaultApiContract.handshake].
/// 2. All storage operations are serialised as [VaultRpcRequest] POSTs to
///    the endpoint defined in [VaultApiContract.rpc].
/// 3. Reactive streams use SSE on the endpoint defined in [VaultApiContract.watch]
///    (TODO: full SSE). Until then, watchChanges returns a local broadcast
///    stream triggered only by in-process mutations.
///
/// ## Client package usage
///
/// ```dart
/// // dart_vault client — just provide the endpoint
/// final vault = Vault(
///   storage: RemoteVaultStorage(
///     endpoint: 'https://data-service.myapp.com',
///     tenantId: currentUser.id,
///     authToken: session.accessToken,
///   ),
///   tenantId: currentUser.id,
/// );
///
/// // Same API as local vault:
/// final blueprints = vault.versioned<Blueprint>(
///   collection: 'blueprints',
///   fromMap: Blueprint.fromMap,
/// );
/// ```
///
/// The client does NOT need to know about Supabase, Postgres, or any
/// backend technology — it only speaks the dart_vault RPC protocol.
///
/// ## Schema compatibility
///
/// On [connect], the server returns its [HandshakeResponse.serverVersion]
/// and the list of available collections with their modes.  If the protocol
/// versions are incompatible, an exception is thrown before any data is
/// accessed.  Domain models must be kept in sync via a shared schema package
/// (e.g. `aq_schema`) — bump the package version when adding fields and
/// update both server and client simultaneously.
final class RemoteVaultStorage implements VaultStorage, ProxyStorage {
  final String endpoint;
  final String tenantId;

  /// Bearer token injected into every request as `Authorization: Bearer ...`
  final String? authToken;

  final Duration timeout;

  /// API contract for route definitions
  final VaultApiContract _contract = const VaultApiContract();

  HandshakeResponse? _handshake;
  bool _connected = false;

  // Change notification — bridged from SSE in a future update
  final _controllers = <String, StreamController<void>>{};

  RemoteVaultStorage({
    required this.endpoint,
    required this.tenantId,
    this.authToken,
    this.timeout = const Duration(seconds: 15),
  });

  // ── Handshake ──────────────────────────────────────────────────────────────

  /// Connect and verify compatibility with the remote Data Service.
  /// Called automatically on first storage operation; you can also call it
  /// explicitly at app startup to fail fast on incompatibility.
  Future<HandshakeResponse> connect() async {
    final body = HandshakeRequest(
      clientVersion: '0.3.0',
      tenantId: tenantId,
    ).toMap();

    final url = _contract.buildUrl(endpoint, VaultApiContract.routeHandshake);
    final raw = await _httpPost(url, body);
    final response = HandshakeResponse.fromMap(raw as Map<String, dynamic>);

    if (!response.compatible) {
      throw VaultStorageException(
        'Remote Data Service is incompatible: '
        '${response.incompatibilityReason ?? "unknown reason"}. '
        'Server version: ${response.serverVersion}',
      );
    }

    _handshake = response;
    _connected = true;
    return response;
  }

  /// Returns the handshake response from the last successful [connect].
  HandshakeResponse? get handshake => _handshake;

  // ── Collections ────────────────────────────────────────────────────────────

  @override
  Future<void> ensureCollection(String collection) async {
    await _ensureConnected();
    // Remote: ensureCollection is a no-op — the Data Service manages its
    // own schema.  We only register the collection in the local controller map.
    _controllers.putIfAbsent(
        collection, () => StreamController<void>.broadcast());
  }

  // ── CRUD ───────────────────────────────────────────────────────────────────

  @override
  Future<void> put(
      String collection, String id, Map<String, dynamic> data) async {
    // Проверяем, есть ли специальная операция в data (для versioned storage)
    final operation = data['operation'] as String?;
    print('🔍 RemoteVaultStorage.put: collection=$collection, id=$id, operation=$operation');

    if (operation != null && operation != 'put') {
      // Для специальных операций (publish, createBranch и т.д.)
      // удаляем 'operation' из data и используем его как имя операции
      final cleanData = Map<String, dynamic>.from(data)..remove('operation');
      print('  → Calling RPC with operation=$operation');
      await _rpc(collection, operation, cleanData);
    } else {
      // Обычная операция put
      print('  → Calling RPC with operation=put');
      await _rpc(collection, 'put', {'id': id, 'data': data});
    }
    _notify(collection);
  }

  @override
  Future<Map<String, dynamic>?> get(String collection, String id) async {
    final res = await _rpc(collection, 'get', {'id': id});
    if (res == null) return null;
    return Map<String, dynamic>.from(res as Map);
  }

  @override
  Future<void> delete(String collection, String id) async {
    await _rpc(collection, 'delete', {'id': id});
    _notify(collection);
  }

  @override
  Future<bool> exists(String collection, String id) async {
    final res = await _rpc(collection, 'exists', {'id': id});
    return res as bool? ?? false;
  }

  @override
  Future<void> putAll(
      String collection, Map<String, Map<String, dynamic>> entries) async {
    await _rpc(collection, 'putAll', {
      'entries': entries.map((k, v) => MapEntry(k, v)),
    });
    _notify(collection);
  }

  // ── Queries ────────────────────────────────────────────────────────────────

  @override
  Future<List<Map<String, dynamic>>> query(
      String collection, VaultQuery q) async {
    final res = await _rpc(collection, 'query', {'query': _serializeQuery(q)});
    final list = res as List? ?? [];
    return list.map((r) => Map<String, dynamic>.from(r as Map)).toList();
  }

  @override
  Future<PageResult<Map<String, dynamic>>> queryPage(
      String collection, VaultQuery q) async {
    final res =
        await _rpc(collection, 'queryPage', {'query': _serializeQuery(q)});
    final m = res as Map<String, dynamic>? ?? {};
    final items = ((m['items'] as List?) ?? [])
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    return PageResult(
      items: items,
      total: m['total'] as int? ?? items.length,
      offset: m['offset'] as int? ?? 0,
      limit: m['limit'] as int? ?? items.length,
    );
  }

  @override
  Future<int> count(String collection, VaultQuery q) async {
    final res = await _rpc(collection, 'count', {'query': _serializeQuery(q)});
    return res as int? ?? 0;
  }

  // ── Indexes ────────────────────────────────────────────────────────────────

  @override
  Future<void> createIndex(String collection, VaultIndex index) async {
    await _rpc(collection, 'createIndex', {
      'name': index.name,
      'field': index.field,
      'unique': index.unique,
    });
  }

  @override
  Future<void> updateIndex(
      String collection, String id, Map<String, dynamic> indexData) async {
    // Managed server-side.
  }

  @override
  Future<void> removeFromIndex(String collection, String id) async {
    // Managed server-side.
  }

  // ── Transactions ───────────────────────────────────────────────────────────

  @override
  Future<T> transaction<T>(Future<T> Function(VaultStorage tx) action) async {
    // Remote transactions: best-effort (see TODO in SupabaseVaultStorage).
    return action(this);
  }

  // ── Reactivity ─────────────────────────────────────────────────────────────

  @override
  Stream<void> watchChanges(String collection) {
    // TODO: upgrade to SSE — subscribe to GET /vault/watch?collection=...
    // and pipe events into the controller below.
    //
    // For now: local-only notifications (works within a single Dart process,
    // e.g. Data Service calling its own storage).  Multi-client realtime
    // requires the SSE transport layer.
    _controllers.putIfAbsent(
        collection, () => StreamController<void>.broadcast());
    return _controllers[collection]!.stream;
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> clear(String collection) async {
    await _rpc(collection, 'clear', {});
    _notify(collection);
  }

  @override
  Future<void> dispose() async {
    for (final c in _controllers.values) {
      await c.close();
    }
    _controllers.clear();
    _connected = false;
  }

  // ── RPC ────────────────────────────────────────────────────────────────────

  /// Direct RPC call to the Data Service.
  /// Used by RemoteLoggedRepository and other specialized remote repositories.
  Future<dynamic> rpc(
    String collection,
    String operation,
    Map<String, dynamic> args,
  ) async {
    await _ensureConnected();
    final req = VaultRpcRequest(
      collection: collection,
      operation: operation,
      args: args,
      tenantId: tenantId,
    );
    final url = _contract.buildUrl(endpoint, VaultApiContract.routeRpc);
    print('🔍 RemoteVaultStorage.rpc: endpoint=$endpoint collection=$collection operation=$operation');
    final raw = await _httpPost(url, req.toMap());

    if (raw == null) {
      throw VaultStorageException(
        'RPC call returned null response. '
        'Check server logs for errors. '
        'URL: $url, Operation: $operation, Collection: $collection',
      );
    }

    final resp = VaultRpcResponse.fromMap(raw as Map<String, dynamic>);

    if (!resp.success) {
      final code = resp.errorCode;
      final msg = resp.error ?? 'Remote operation failed';
      switch (code) {
        case 'NOT_FOUND':
          throw VaultNotFoundException(msg);
        case 'ACCESS_DENIED':
          throw VaultAccessDeniedException(msg);
        case 'STATE_ERROR':
          throw VaultStateException(msg);
        default:
          throw VaultStorageException(msg);
      }
    }

    return resp.data;
  }

  // ── Private ────────────────────────────────────────────────────────────────

  Future<void> _ensureConnected() async {
    if (!_connected) await connect();
  }

  Future<dynamic> _rpc(
    String collection,
    String operation,
    Map<String, dynamic> args,
  ) async {
    // Delegate to public rpc() method
    return rpc(collection, operation, args);
  }

  Future<dynamic> _httpPost(String url, Map<String, dynamic> body) async {
    final bodyJson = jsonEncode(body);
    print('📤 HTTP POST: $url');
    print('   Request body: ${bodyJson.length > 200 ? bodyJson.substring(0, 200) + "..." : bodyJson}');

    try {
      final response = await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              if (authToken != null) 'Authorization': 'Bearer $authToken',
            },
            body: bodyJson,
          )
          .timeout(timeout);

      final raw = response.body;

      print('📥 HTTP Response:');
      print('   Status: ${response.statusCode}');
      print('   Body length: ${raw.length} bytes');
      print('   Body: ${raw.isEmpty ? "(empty)" : (raw.length > 200 ? raw.substring(0, 200) + "..." : raw)}');

      if (response.statusCode >= 400) {
        Map<String, dynamic> errMap = {};
        try {
          errMap = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {}
        throw VaultStorageException(
          errMap['error'] as String? ?? 'HTTP ${response.statusCode}: $raw',
          cause: response.statusCode,
        );
      }

      if (raw.isEmpty) {
        throw VaultStorageException(
          'Server returned empty response (status ${response.statusCode}). URL: $url',
        );
      }

      try {
        final decoded = jsonDecode(raw);
        print('   Decoded type: ${decoded.runtimeType}');
        return decoded;
      } catch (e) {
        throw VaultStorageException(
          'Failed to decode JSON response: $e. '
          'Raw response: ${raw.length > 200 ? raw.substring(0, 200) + "..." : raw}',
        );
      }
    } catch (e) {
      if (e is VaultException) rethrow;
      throw VaultStorageException('Network error: $url', cause: e);
    }
  }

  Map<String, dynamic> _serializeQuery(VaultQuery q) => {
        'filters': q.filters
            .map((f) => {
                  'field': f.field,
                  'operator': f.operator.name,
                  'value': f.value,
                })
            .toList(),
        'sortField': q.sort?.field,
        'sortDescending': q.sort?.descending ?? false,
        'limit': q.limit,
        'offset': q.offset,
      };

  void _notify(String collection) {
    _controllers[collection]?.add(null);
  }
}
