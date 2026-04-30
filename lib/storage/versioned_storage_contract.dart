/// Unified contract for all Versioned Storage implementations.
///
/// @Deprecated Используйте [VersionedStorageSchema] из `lib/deploy/versioned_storage_schema.dart`.
/// Все константы полей и имена таблиц перенесены туда.
/// Этот класс будет удалён в следующей версии.
@Deprecated('Use VersionedStorageSchema instead. '
    'All field constants and table names have been moved to VersionedStorageSchema.')
abstract final class VersionedStorageContract {
  // ── Table/Collection Names ─────────────────────────────────────────────────

  /// PostgreSQL: versions table name
  static String versionsTable(String collection) => '${collection}_versions';

  /// PostgreSQL: current version pointer table name
  static String currentTable(String collection) => '${collection}_current';

  /// InMemory/IndexedDB: nodes collection name
  static String nodesCollection(String collection) => '${collection}__nodes';

  /// InMemory/IndexedDB: metadata collection name
  static String metaCollection(String collection) => '${collection}__meta';

  // ── VersionNode Field Names ────────────────────────────────────────────────

  static const String kNodeId = 'node_id';
  static const String kEntityId = 'entity_id';
  static const String kParentNodeId = 'parent_node_id';
  static const String kTenantId = 'tenant_id';
  static const String kVersion = 'version';
  static const String kStatus = 'status';
  static const String kBranch = 'branch';
  static const String kData = 'data';
  static const String kCreatedAt = 'created_at';
  static const String kCreatedBy = 'created_by';
  static const String kSequenceNumber = 'sequence_number';
  static const String kIsCurrent = 'is_current';

  // ── Entity Metadata Field Names (for __meta collection) ───────────────────

  static const String kOwnerId = 'owner_id';
  static const String kCurrentNodeId = 'current_node_id';
  static const String kGrants = 'grants';
  static const String kSequenceCounter = 'sequence_counter';

  // ── Current Pointer Field Names (for _current table) ──────────────────────

  static const String kUpdatedAt = 'updated_at';

  // ── Data Validation ────────────────────────────────────────────────────────

  /// Validate that a VersionNode map has all required fields.
  static void validateVersionNode(Map<String, dynamic> data) {
    final required = [kNodeId, kEntityId, kStatus, kBranch, kData, kCreatedAt];
    for (final field in required) {
      if (!data.containsKey(field)) {
        throw ArgumentError('VersionNode missing required field: $field');
      }
    }
  }

  /// Validate that entity metadata has all required fields.
  static void validateMetadata(Map<String, dynamic> data) {
    final required = [kEntityId, kOwnerId];
    for (final field in required) {
      if (!data.containsKey(field)) {
        throw ArgumentError('Entity metadata missing required field: $field');
      }
    }
  }

  // ── Field Mapping Helpers ──────────────────────────────────────────────────

  /// Convert VersionNode to PostgreSQL _versions table format.
  static Map<String, dynamic> toPostgresVersionsRow(Map<String, dynamic> node) {
    return {
      kNodeId: node['nodeId'],
      kEntityId: node['entityId'],
      kParentNodeId: node['parentNodeId'],
      kTenantId: node['tenantId'] ?? 'system',
      kVersion: node['version'],
      kStatus: node['status'],
      kBranch: node['branch'] ?? 'main',
      kData: node['data'],
      kCreatedAt: node['createdAt'],
      kCreatedBy: node['createdBy'] ?? '',
      kSequenceNumber: node['sequenceNumber'] ?? 1,
    };
  }

  /// Convert PostgreSQL _versions row to VersionNode format.
  static Map<String, dynamic> fromPostgresVersionsRow(Map<String, dynamic> row) {
    return {
      'nodeId': row[kNodeId],
      'entityId': row[kEntityId],
      'parentNodeId': row[kParentNodeId],
      'tenantId': row[kTenantId],
      'version': row[kVersion],
      'status': row[kStatus],
      'branch': row[kBranch] ?? 'main',
      'data': row[kData],
      'createdAt': row[kCreatedAt],
      'createdBy': row[kCreatedBy] ?? '',
      'sequenceNumber': row[kSequenceNumber] ?? 1,
      'isCurrent': row[kIsCurrent] ?? false,
    };
  }

  /// Convert entity metadata to __meta collection format.
  static Map<String, dynamic> toMetaDocument(
    String entityId,
    String ownerId,
    String? currentNodeId,
    List<Map<String, dynamic>> grants,
    int sequenceCounter,
  ) {
    return {
      kEntityId: entityId,
      kOwnerId: ownerId,
      kCurrentNodeId: currentNodeId,
      kGrants: grants,
      kSequenceCounter: sequenceCounter,
    };
  }
}
