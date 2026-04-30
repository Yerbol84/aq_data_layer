import 'package:aq_schema/aq_schema.dart';

import 'direct_storage_schema.dart';
import 'i_storage_schema.dart';
import 'logged_storage_schema.dart';
import 'versioned_storage_schema.dart';

/// Storage mode — determines which repository type is used.
enum StorageMode { direct, versioned, logged, artifact, vector }

/// Describes a single domain collection registered in [VaultRegistry].
///
/// The registry uses [DomainRegistration]s to:
/// - Auto-deploy DB schema on startup via [SchemaDeployer]
/// - Route RPC calls to the correct repository type
/// - Tell clients (via handshake) which collections are available
///
/// ## Usage (Data Service startup)
///
/// ```dart
/// registry
///   ..register(DomainRegistration(
///       collection: 'blueprints',
///       mode: StorageMode.versioned,
///       fromMap: Blueprint.fromMap,
///       jsonSchema: Blueprint.kJsonSchema,
///       indexes: [VaultIndex(name: 'idx_name', field: 'name')],
///       schemaVersion: '1.0.0',
///   ))
///   ..register(DomainRegistration(
///       collection: 'runs',
///       mode: StorageMode.logged,
///       fromMap: WorkflowRun.fromMap,
///       jsonSchema: WorkflowRun.kJsonSchema,
///   ));
/// ```
final class DomainRegistration {
  /// Logical collection name (without tenant prefix).
  final String collection;

  /// How this collection is stored.
  final StorageMode mode;

  /// Deserialises a stored map back into the domain object.
  ///
  /// Declared as `dynamic` to enable type-erased generic dispatch.
  /// The registry guarantees the returned object implements [Storable].
  final dynamic Function(Map<String, dynamic>) fromMap;

  /// JSON Schema describing the domain structure.
  /// Used by [SchemaDeployer] to auto-create tables/collections.
  ///
  /// Required fields:
  /// - `type`: "object"
  /// - `properties`: map of field name → field schema
  /// - `required`: list of required field names
  ///
  /// Example:
  /// ```dart
  /// {
  ///   'type': 'object',
  ///   'properties': {
  ///     'id': {'type': 'string', 'format': 'uuid'},
  ///     'name': {'type': 'string'},
  ///   },
  ///   'required': ['id', 'name'],
  /// }
  /// ```
  final Map<String, dynamic> jsonSchema;

  /// Indexes to create on the collection.
  final List<VaultIndex> indexes;

  /// Semantic version of the domain model.
  /// Used by [SchemaDeployer] to detect when migrations are needed.
  final String schemaVersion;

  /// Опциональное имя Dart-класса для документации.
  /// Записывается в _vault_registry для читаемости.
  final String? dartClass;

  const DomainRegistration({
    required this.collection,
    required this.mode,
    required this.fromMap,
    required this.jsonSchema,
    this.indexes = const [],
    this.schemaVersion = '1.0.0',
    this.dartClass,
  });

  /// Схема хранения для этого домена.
  ///
  /// Единственный источник правды для структуры таблиц.
  /// Создаётся автоматически из [mode] и [collection].
  IStorageSchema get schema => switch (mode) {
        StorageMode.direct => DirectStorageSchema(collection),
        StorageMode.versioned => VersionedStorageSchema(collection),
        StorageMode.logged => LoggedStorageSchema(collection),
        _ => DirectStorageSchema(collection),
      };

  Map<String, dynamic> toInfo() => {
        'name': collection,
        'mode': mode.name,
        'schemaVersion': schemaVersion,
      };
}
