// dart_vault_package/lib/client/data_layer_impl.dart
//
// Implementation of IDataLayer protocol from aq_schema.
// Bridges aq_schema interface to dart_vault Vault implementation.

import 'package:aq_schema/aq_schema.dart';
import 'vault.dart';
import 'remote/remote_vault_storage.dart';
import '../storage/in_memory_vault_storage.dart';
import '../storage/local_buffer_vault_storage.dart';

/// Implementation of [IDataLayer] that wraps [Vault].
///
/// This bridges the aq_schema protocol to dart_vault implementation.
/// Client code should use [IDataLayer.initialize()] and [IDataLayer.instance],
/// not this class directly.
final class DataLayerImpl implements IDataLayer {
  final Vault _vault;
  final String _endpoint;

  DataLayerImpl._({
    required Vault vault,
    required String endpoint,
  })  : _vault = vault,
        _endpoint = endpoint;

  // ══════════════════════════════════════════════════════════════════════════
  // Repository Factories
  // ══════════════════════════════════════════════════════════════════════════

  @override
  DirectRepository<T> direct<T extends DirectStorable>({
    required String collection,
    required T Function(Map<String, dynamic>) fromMap,
    List<VaultIndex> indexes = const [],
  }) {
    return _vault.direct<T>(
      collection: collection,
      fromMap: fromMap,
      indexes: indexes,
    );
  }

  @override
  VersionedRepository<T> versioned<T extends VersionedStorable>({
    required String collection,
    required T Function(Map<String, dynamic>) fromMap,
    List<VaultIndex> indexes = const [],
  }) {
    return _vault.versioned<T>(
      collection: collection,
      fromMap: fromMap,
      indexes: indexes,
    );
  }

  @override
  LoggedRepository<T> logged<T extends LoggedStorable>({
    required String collection,
    required T Function(Map<String, dynamic>) fromMap,
    List<VaultIndex> indexes = const [],
    bool captureFullSnapshot = false,
  }) {
    return _vault.logged<T>(
      collection: collection,
      fromMap: fromMap,
      indexes: indexes,
      captureFullSnapshot: captureFullSnapshot,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Buffer Management
  // ══════════════════════════════════════════════════════════════════════════

  @override
  IBufferedStorage? get buffer => _vault.buffer;

  // ══════════════════════════════════════════════════════════════════════════
  // Connection Info
  // ══════════════════════════════════════════════════════════════════════════

  @override
  String get tenantId => _vault.tenantId;

  @override
  String get endpoint => _endpoint;

  @override
  String? get serverVersion {
    final storage = _vault.storage;
    // Check if storage has handshake info (RemoteVaultStorage)
    if (storage is RemoteVaultStorage) {
      return storage.handshake?.serverVersion;
    }
    return null;
  }

  @override
  bool get isConnected {
    final storage = _vault.storage;

    // Unwrap buffer if present
    final actualStorage = storage is LocalBufferVaultStorage
        ? storage.remote
        : storage;

    // Only RemoteVaultStorage with successful handshake is truly "connected"
    if (actualStorage is RemoteVaultStorage) {
      return actualStorage.handshake != null;
    }

    // InMemoryVaultStorage is NOT connected (it's a fallback)
    return false;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Lifecycle
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Future<void> dispose() => _vault.dispose();

  // ══════════════════════════════════════════════════════════════════════════
  // Factory (public API for creating implementation)
  // ══════════════════════════════════════════════════════════════════════════

  /// Create DataLayerImpl with connection details.
  ///
  /// **This is the implementation-level factory.**
  /// It knows about endpoints, buffers, and connection logic.
  ///
  /// **Usage:**
  /// ```dart
  /// import 'package:dart_vault/dart_vault.dart';
  ///
  /// // Create implementation with details
  /// final impl = await DataLayerImpl.connect(
  ///   endpoint: 'http://localhost:8765',
  ///   useBuffer: false,
  /// );
  ///
  /// // Register with protocol
  /// IDataLayer.register(impl);
  ///
  /// // Or use convenience function:
  /// await initializeDataLayer(endpoint: 'http://localhost:8765');
  /// ```
  static Future<DataLayerImpl> connect({
    required String endpoint,
    String tenantId = 'system',
    bool useBuffer = true,
  }) async {
    final vault = await Vault.remote(
      endpoint: endpoint,
      tenantId: tenantId,
      useBuffer: useBuffer,
    );

    return DataLayerImpl._(
      vault: vault,
      endpoint: endpoint,
    );
  }
}
