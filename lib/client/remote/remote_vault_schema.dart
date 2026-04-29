library remote_vault_schema;

import 'dart:convert';

/// Wire protocol for the dart_vault Remote Proxy.
///
/// ## Handshake
///
/// Client → Server:  POST /vault/handshake
/// ```json
/// { "clientVersion": "0.3.0", "tenantId": "alice" }
/// ```
///
/// Server → Client:
/// ```json
/// {
///   "serverVersion": "0.3.0",
///   "tenantId":      "alice",
///   "collections": [
///     { "name": "blueprints", "mode": "versioned" },
///     { "name": "runs",       "mode": "logged"    },
///     { "name": "settings",   "mode": "direct"    }
///   ],
///   "capabilities": ["direct", "versioned", "logged", "artifact", "vector"],
///   "compatible":   true
/// }
/// ```
///
/// If [compatible] is false the client MUST NOT proceed — the server is
/// running an incompatible schema version.
///
/// ## Operation wire format
///
/// Every repository call is serialised as a [VaultRpcRequest] and sent to
/// POST /vault/rpc.  The server dispatches to the correct repository and
/// returns a [VaultRpcResponse].
///
/// This design keeps the HTTP surface to a single endpoint, making the Data
/// Service trivially load-balanced and cacheable.

// ── Handshake ──────────────────────────────────────────────────────────────

final class HandshakeRequest {
  final String clientVersion;
  final String tenantId;
  const HandshakeRequest({required this.clientVersion, required this.tenantId});

  Map<String, dynamic> toMap() => {
        'clientVersion': clientVersion,
        'tenantId': tenantId,
      };
  factory HandshakeRequest.fromMap(Map<String, dynamic> m) => HandshakeRequest(
        clientVersion: m['clientVersion'] as String,
        tenantId: m['tenantId'] as String,
      );
}

final class CollectionInfo {
  final String name;
  final String
      mode; // 'direct' | 'versioned' | 'logged' | 'artifact' | 'vector'
  const CollectionInfo({required this.name, required this.mode});

  Map<String, dynamic> toMap() => {'name': name, 'mode': mode};
  factory CollectionInfo.fromMap(Map<String, dynamic> m) => CollectionInfo(
        name: m['name'] as String,
        mode: m['mode'] as String? ?? 'direct',
      );
}

final class HandshakeResponse {
  final String serverVersion;
  final String tenantId;
  final List<CollectionInfo> collections;
  final List<String> capabilities;
  final bool compatible;
  final String? incompatibilityReason;

  const HandshakeResponse({
    required this.serverVersion,
    required this.tenantId,
    required this.collections,
    required this.capabilities,
    required this.compatible,
    this.incompatibilityReason,
  });

  Map<String, dynamic> toMap() => {
        'serverVersion': serverVersion,
        'tenantId': tenantId,
        'collections': collections.map((c) => c.toMap()).toList(),
        'capabilities': capabilities,
        'compatible': compatible,
        if (incompatibilityReason != null)
          'incompatibilityReason': incompatibilityReason,
      };

  factory HandshakeResponse.fromMap(Map<String, dynamic> m) =>
      HandshakeResponse(
        serverVersion: m['serverVersion'] as String,
        tenantId: m['tenantId'] as String,
        collections: ((m['collections'] as List?) ?? [])
            .whereType<Map<String, dynamic>>()
            .map(CollectionInfo.fromMap)
            .toList(),
        capabilities: ((m['capabilities'] as List?) ?? []).cast<String>(),
        compatible: m['compatible'] as bool? ?? false,
        incompatibilityReason: m['incompatibilityReason'] as String?,
      );

  String toJson() => jsonEncode(toMap());
  factory HandshakeResponse.fromJson(String s) =>
      HandshakeResponse.fromMap(jsonDecode(s) as Map<String, dynamic>);
}

// ── RPC Request / Response ─────────────────────────────────────────────────

final class VaultRpcRequest {
  /// Target collection (already qualified with tenant prefix server-side).
  final String collection;

  /// Operation name, e.g. "save", "findById", "query", "publishDraft".
  final String operation;

  /// Operation arguments (must be JSON-serialisable).
  final Map<String, dynamic> args;

  /// Tenant ID for multi-tenancy support.
  final String? tenantId;

  /// Idempotency key — resend on network error without double-write risk.
  final String? idempotencyKey;

  const VaultRpcRequest({
    required this.collection,
    required this.operation,
    required this.args,
    this.tenantId,
    this.idempotencyKey,
  });

  Map<String, dynamic> toMap() => {
        'collection': collection,
        'operation': operation,
        'args': args,
        if (tenantId != null) 'tenantId': tenantId,
        if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
      };

  factory VaultRpcRequest.fromMap(Map<String, dynamic> m) => VaultRpcRequest(
        collection: m['collection'] as String,
        operation: m['operation'] as String,
        args: (m['args'] as Map<String, dynamic>?) ?? {},
        tenantId: m['tenantId'] as String?,
        idempotencyKey: m['idempotencyKey'] as String?,
      );

  String toJson() => jsonEncode(toMap());
  factory VaultRpcRequest.fromJson(String s) =>
      VaultRpcRequest.fromMap(jsonDecode(s) as Map<String, dynamic>);
}

final class VaultRpcResponse {
  final bool success;
  final dynamic data; // JSON-safe result
  final String? error; // error message when success=false
  final String? errorCode; // machine-readable error code

  const VaultRpcResponse({
    required this.success,
    this.data,
    this.error,
    this.errorCode,
  });

  factory VaultRpcResponse.ok(dynamic data) =>
      VaultRpcResponse(success: true, data: data);

  factory VaultRpcResponse.fail(String error, {String? code}) =>
      VaultRpcResponse(success: false, error: error, errorCode: code);

  Map<String, dynamic> toMap() => {
        'success': success,
        'data': data,
        if (error != null) 'error': error,
        if (errorCode != null) 'errorCode': errorCode,
      };

  factory VaultRpcResponse.fromMap(Map<String, dynamic> m) => VaultRpcResponse(
        success: m['success'] as bool? ?? false,
        data: m['data'],
        error: m['error'] as String?,
        errorCode: m['errorCode'] as String?,
      );

  String toJson() => jsonEncode(toMap());
  factory VaultRpcResponse.fromJson(String s) =>
      VaultRpcResponse.fromMap(jsonDecode(s) as Map<String, dynamic>);
}

// ── Server-Sent Events (watch streams) ────────────────────────────────────
//
// For reactive streams over HTTP, the remote proxy uses SSE:
//
//   GET /vault/watch?collection=blueprints__nodes&tenantId=alice
//   Accept: text/event-stream
//
// The server emits events whenever [VaultStorage.watchChanges] fires:
//
//   data: {"event":"change","collection":"alice__blueprints__nodes"}
//
// The [RemoteVaultStorage] subscribes and routes events to its local
// broadcast [StreamController]s, bridging the SSE stream to the
// dart_vault reactive API.
//
// TODO: implement SSE subscription in RemoteVaultStorage.watchChanges().
// For now, watchChanges() on the remote storage returns a never-ending
// empty stream (polling mode as fallback — see RemoteVaultStorage).

final class WatchEvent {
  final String event; // 'change' | 'heartbeat' | 'error'
  final String collection;
  final DateTime timestamp;

  const WatchEvent({
    required this.event,
    required this.collection,
    required this.timestamp,
  });

  factory WatchEvent.fromMap(Map<String, dynamic> m) => WatchEvent(
        event: m['event'] as String? ?? 'change',
        collection: m['collection'] as String? ?? '',
        timestamp: DateTime.tryParse(m['timestamp'] as String? ?? '') ??
            DateTime.now(),
      );
}
