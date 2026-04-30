import 'package:postgres/postgres.dart';
import 'package:aq_schema/aq_schema.dart';

import '../../exceptions/vault_exceptions.dart';
import '../../deploy/versioned_storage_schema.dart';

/// PostgreSQL-optimized implementation of [VersionedRepository].
///
/// Uses PostgreSQL-specific tables:
/// - `{collection}_versions` — all version nodes
/// - `{collection}_current` — current version pointer per entity
///
/// All field names use constants from [VersionedStorageSchema].
final class PostgresVersionedRepository<T extends VersionedStorable>
    implements VersionedRepository<T> {
  final Pool<Object?> _pool;
  final String _tenantId;
  final T Function(Map<String, dynamic>) _fromMap;

  late final String _versionsTable;
  late final String _currentTable;

  PostgresVersionedRepository({
    required Pool<Object?> pool,
    required String collection,
    required String tenantId,
    required T Function(Map<String, dynamic>) fromMap,
  })  : _pool = pool,
        _tenantId = tenantId,
        _fromMap = fromMap {
    final tableNames = VersionedStorageSchema(collection).tableNames;
    _versionsTable = tableNames.versions!;
    _currentTable = tableNames.current!;
  }

  /// Доступ к пулу соединений.
  Pool<Object?> get pool => _pool;

  /// Устанавливает tenant-контекст для текущей сессии.
  /// RLS политики используют current_setting('app.current_tenant').
  Future<void> _setTenantContext(Session session) async {
    final escapedTenantId = _tenantId.replaceAll("'", "''");
    print('[RLS-Versioned] Setting tenant context: $escapedTenantId');
    // Используем SET вместо SET LOCAL, так как Pool.run() может не создавать транзакцию
    await session.execute("SET app.current_tenant = '$escapedTenantId'");

    // Проверяем, что значение установлено
    final result = await session.execute(
        "SELECT current_setting('app.current_tenant', true) as tenant");
    final actualTenant = result.isNotEmpty ? result.first[0] : 'NULL';
    print('[RLS-Versioned] Verified tenant context: $actualTenant');

    if (actualTenant != _tenantId) {
      throw Exception(
          'RLS context mismatch: expected $_tenantId, got $actualTenant');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CREATE & EDIT
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Future<VersionNode> createEntity(T model) async {
    return await _pool.run((Session connection) async {
      await _setTenantContext(connection);

      final nodeId = _uuid();
      final now = DateTime.now();

      final node = VersionNode(
        nodeId: nodeId,
        entityId: model.id,
        status: VersionStatus.draft,
        sequenceNumber: 1,
        createdBy: model.ownerId,
        createdAt: now,
        data: model.toMap(),
        isCurrent: false,
        branch: 'main',
      );

      await connection.execute(
        '''
        INSERT INTO $_versionsTable (
          ${VersionedStorageSchema.kNodeId},
          ${VersionedStorageSchema.kEntityId},
          ${VersionedStorageSchema.kTenantId},
          ${VersionedStorageSchema.kStatus},
          ${VersionedStorageSchema.kBranch},
          ${VersionedStorageSchema.kSequenceNumber},
          ${VersionedStorageSchema.kCreatedBy},
          ${VersionedStorageSchema.kCreatedAt},
          ${VersionedStorageSchema.kData}
        ) VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9)
        ''',
        parameters: [
          nodeId,
          model.id,
          _tenantId,
          VersionStatus.draft.name,
          'main',
          1,
          model.ownerId,
          now,
          model.toMap(),
        ],
      );

      return node;
    });
  }

  @override
  Future<VersionNode> createDraftFrom(String parentNodeId, T model) async {
    return await _pool.run((Session connection) async {
      await _setTenantContext(connection);

      // Get parent node to inherit sequence number
      final parent = await getNodeById(parentNodeId);
      if (parent == null) {
        throw VaultNotFoundException('Parent node not found: $parentNodeId');
      }

      final nodeId = _uuid();
      final now = DateTime.now();

      final node = VersionNode(
        nodeId: nodeId,
        entityId: model.id,
        parentNodeId: parentNodeId,
        status: VersionStatus.draft,
        sequenceNumber: parent.sequenceNumber + 1,
        createdBy: model.ownerId,
        createdAt: now,
        data: model.toMap(),
        isCurrent: false,
        branch: parent.branch,
      );

      await connection.execute(
        '''
        INSERT INTO $_versionsTable (
          ${VersionedStorageSchema.kNodeId},
          ${VersionedStorageSchema.kEntityId},
          ${VersionedStorageSchema.kParentNodeId},
          ${VersionedStorageSchema.kTenantId},
          ${VersionedStorageSchema.kStatus},
          ${VersionedStorageSchema.kBranch},
          ${VersionedStorageSchema.kSequenceNumber},
          ${VersionedStorageSchema.kCreatedBy},
          ${VersionedStorageSchema.kCreatedAt},
          ${VersionedStorageSchema.kData}
        ) VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10)
        ''',
        parameters: [
          nodeId,
          model.id,
          parentNodeId,
          _tenantId,
          VersionStatus.draft.name,
          parent.branch,
          node.sequenceNumber,
          model.ownerId,
          now,
          model.toMap(),
        ],
      );

      return node;
    });
  }

  @override
  Future<void> updateDraft(String nodeId, T model) async {
    await _pool.run((connection) async {
      await connection.execute(
        '''
        UPDATE $_versionsTable
        SET ${VersionedStorageSchema.kData} = \$1
        WHERE ${VersionedStorageSchema.kNodeId} = \$2
          AND ${VersionedStorageSchema.kTenantId} = \$3
          AND ${VersionedStorageSchema.kStatus} = \$4
        ''',
        parameters: [
          model.toMap(),
          nodeId,
          _tenantId,
          VersionStatus.draft.name
        ],
      );
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PUBLISH & ARCHIVE
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Future<VersionNode> publishDraft(
    String nodeId, {
    required IncrementType increment,
  }) async {
    return await _pool.run((Session connection) async {
      await _setTenantContext(connection);

      final node = await getNodeById(nodeId);
      if (node == null) {
        throw VaultNotFoundException('Node not found: $nodeId');
      }

      if (node.status != VersionStatus.draft) {
        throw VaultStorageException('Only DRAFT nodes can be published');
      }

      // Calculate new version
      final currentVersion = await _getLatestVersion(node.entityId);
      final newVersion = currentVersion == null
          ? Semver(1, 0, 0)
          : switch (increment) {
              IncrementType.major => currentVersion.incrementMajor(),
              IncrementType.minor => currentVersion.incrementMinor(),
              IncrementType.patch => currentVersion.incrementPatch(),
            };

      // Update node to published
      await connection.execute(
        '''
        UPDATE $_versionsTable
        SET ${VersionedStorageSchema.kStatus} = \$1,
            ${VersionedStorageSchema.kVersion} = \$2
        WHERE ${VersionedStorageSchema.kNodeId} = \$3
          AND ${VersionedStorageSchema.kTenantId} = \$4
        ''',
        parameters: [
          VersionStatus.published.name,
          newVersion.toString(),
          nodeId,
          _tenantId
        ],
      );

      // Set as current version
      await _setCurrentVersion(node.entityId, nodeId);

      return node.copyWith(
        status: VersionStatus.published,
        version: newVersion,
        isCurrent: true,
      );
    });
  }

  @override
  Future<VersionNode> snapshotVersion(String nodeId) async {
    return await _pool.run((Session connection) async {
      await _setTenantContext(connection);

      final node = await getNodeById(nodeId);
      if (node == null) {
        throw VaultNotFoundException('Node not found: $nodeId');
      }

      await connection.execute(
        '''
        UPDATE $_versionsTable
        SET ${VersionedStorageSchema.kStatus} = \$1
        WHERE ${VersionedStorageSchema.kNodeId} = \$2
          AND ${VersionedStorageSchema.kTenantId} = \$3
        ''',
        parameters: [VersionStatus.snapshot.name, nodeId, _tenantId],
      );

      return node.copyWith(status: VersionStatus.snapshot);
    });
  }

  @override
  Future<void> deleteVersion(String nodeId) async {
    await _pool.run((connection) async {
      await connection.execute(
        '''
        DELETE FROM $_versionsTable
        WHERE ${VersionedStorageSchema.kNodeId} = \$1
          AND ${VersionedStorageSchema.kTenantId} = \$2
        ''',
        parameters: [nodeId, _tenantId],
      );
    });
  }

  @override
  Future<void> deleteEntity(String entityId) async {
    await _pool.run((connection) async {
      // Delete all versions
      await connection.execute(
        '''
        DELETE FROM $_versionsTable
        WHERE ${VersionedStorageSchema.kEntityId} = \$1
          AND ${VersionedStorageSchema.kTenantId} = \$2
        ''',
        parameters: [entityId, _tenantId],
      );

      // Delete current pointer
      await connection.execute(
        '''
        DELETE FROM $_currentTable
        WHERE ${VersionedStorageSchema.kEntityId} = \$1
          AND ${VersionedStorageSchema.kTenantId} = \$2
        ''',
        parameters: [entityId, _tenantId],
      );
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BRANCHING
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Future<VersionNode> createBranch(
    String parentNodeId, {
    required String branchName,
    required T model,
  }) async {
    return await _pool.run((Session connection) async {
      await _setTenantContext(connection);

      final parent = await getNodeById(parentNodeId);
      if (parent == null) {
        throw VaultNotFoundException('Parent node not found: $parentNodeId');
      }

      final nodeId = _uuid();
      final now = DateTime.now();

      final node = VersionNode(
        nodeId: nodeId,
        entityId: model.id,
        parentNodeId: parentNodeId,
        status: VersionStatus.draft,
        sequenceNumber: parent.sequenceNumber + 1,
        createdBy: model.ownerId,
        createdAt: now,
        data: model.toMap(),
        isCurrent: false,
        branch: branchName,
      );

      await connection.execute(
        '''
        INSERT INTO $_versionsTable (
          ${VersionedStorageSchema.kNodeId},
          ${VersionedStorageSchema.kEntityId},
          ${VersionedStorageSchema.kParentNodeId},
          ${VersionedStorageSchema.kTenantId},
          ${VersionedStorageSchema.kStatus},
          ${VersionedStorageSchema.kBranch},
          ${VersionedStorageSchema.kSequenceNumber},
          ${VersionedStorageSchema.kCreatedBy},
          ${VersionedStorageSchema.kCreatedAt},
          ${VersionedStorageSchema.kData}
        ) VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10)
        ''',
        parameters: [
          nodeId,
          model.id,
          parentNodeId,
          _tenantId,
          VersionStatus.draft.name,
          branchName,
          node.sequenceNumber,
          model.ownerId,
          now,
          model.toMap(),
        ],
      );

      return node;
    });
  }

  @override
  Future<VersionNode> mergeToMain(
    String entityId, {
    required String sourceBranch,
    required String requesterId,
    required T Function(Map<String, dynamic>) fromMap,
  }) async {
    return await _pool.run((Session connection) async {
      await _setTenantContext(connection);

      // Get latest node from source branch
      final result = await connection.execute(
        '''
        SELECT * FROM $_versionsTable
        WHERE ${VersionedStorageSchema.kEntityId} = \$1
          AND ${VersionedStorageSchema.kTenantId} = \$2
          AND ${VersionedStorageSchema.kBranch} = \$3
        ORDER BY ${VersionedStorageSchema.kSequenceNumber} DESC
        LIMIT 1
        ''',
        parameters: [entityId, _tenantId, sourceBranch],
      );

      if (result.isEmpty) {
        throw VaultNotFoundException('No nodes found in branch: $sourceBranch');
      }

      final sourceNode = _rowToVersionNode(result.first);
      // Create new draft on main branch
      final nodeId = _uuid();
      final now = DateTime.now();

      await connection.execute(
        '''
        INSERT INTO $_versionsTable (
          ${VersionedStorageSchema.kNodeId},
          ${VersionedStorageSchema.kEntityId},
          ${VersionedStorageSchema.kParentNodeId},
          ${VersionedStorageSchema.kTenantId},
          ${VersionedStorageSchema.kStatus},
          ${VersionedStorageSchema.kBranch},
          ${VersionedStorageSchema.kSequenceNumber},
          ${VersionedStorageSchema.kCreatedBy},
          ${VersionedStorageSchema.kCreatedAt},
          ${VersionedStorageSchema.kData}
        ) VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10)
        ''',
        parameters: [
          nodeId,
          entityId,
          sourceNode.nodeId,
          _tenantId,
          VersionStatus.draft.name,
          'main',
          sourceNode.sequenceNumber + 1,
          requesterId,
          now,
          sourceNode.data,
        ],
      );

      return VersionNode(
        nodeId: nodeId,
        entityId: entityId,
        parentNodeId: sourceNode.nodeId,
        status: VersionStatus.draft,
        sequenceNumber: sourceNode.sequenceNumber + 1,
        createdBy: requesterId,
        createdAt: now,
        data: sourceNode.data,
        isCurrent: false,
        branch: 'main',
      );
    });
  }

  @override
  Future<List<String>> listBranches(String entityId) async {
    return await _pool.run((Session connection) async {
      await _setTenantContext(connection);

      final result = await connection.execute(
        '''
        SELECT DISTINCT ${VersionedStorageSchema.kBranch}
        FROM $_versionsTable
        WHERE ${VersionedStorageSchema.kEntityId} = \$1
          AND ${VersionedStorageSchema.kTenantId} = \$2
        ''',
        parameters: [entityId, _tenantId],
      );

      return result.map((row) => row[0] as String).toList();
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CURRENT VERSION
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Future<void> setCurrentVersion(
    String entityId,
    String nodeId, {
    required String requesterId,
  }) async {
    await _setCurrentVersion(entityId, nodeId);
  }

  @override
  Future<T?> getCurrent(String entityId) async {
    return await _pool.run((Session connection) async {
      await _setTenantContext(connection);

      final result = await connection.execute(
        '''
        SELECT v.* FROM $_versionsTable v
        INNER JOIN $_currentTable c
          ON v.${VersionedStorageSchema.kNodeId} = c.${VersionedStorageSchema.kNodeId}
        WHERE c.${VersionedStorageSchema.kEntityId} = \$1
          AND c.${VersionedStorageSchema.kTenantId} = \$2
        ''',
        parameters: [entityId, _tenantId],
      );

      if (result.isEmpty) return null;

      final node = _rowToVersionNode(result.first);
      return _fromMap(node.data);
    });
  }

  @override
  Future<T?> getVersion(String nodeId) async {
    final node = await getNodeById(nodeId);
    if (node == null) return null;
    return _fromMap(node.data);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ACCESS CONTROL (Simplified - full implementation needed)
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Future<void> grantAccess(
    String entityId, {
    required String actorId,
    required AccessLevel level,
    required String requesterId,
  }) async {
    // TODO: Implement access control in separate table
    throw UnimplementedError('Access control not yet implemented');
  }

  @override
  Future<void> revokeAccess(
    String entityId, {
    required String actorId,
    required String requesterId,
  }) async {
    throw UnimplementedError('Access control not yet implemented');
  }

  @override
  Future<bool> hasAccess(
    String entityId, {
    required String actorId,
    required AccessLevel minimumLevel,
  }) async {
    // For now, allow all access
    return true;
  }

  @override
  Future<List<AqResourcePermission>> listGrants(String entityId) async {
    return [];
  }

  // ══════════════════════════════════════════════════════════════════════════
  // QUERIES
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Future<List<VersionNode>> listVersions(
    String entityId, {
    VersionStatus? status,
    String? branch,
  }) async {
    return await _pool.run((Session connection) async {
      await _setTenantContext(connection);

      final conditions = <String>[
        '${VersionedStorageSchema.kEntityId} = \$1',
        '${VersionedStorageSchema.kTenantId} = \$2',
      ];
      final params = <dynamic>[entityId, _tenantId];

      if (status != null) {
        conditions.add(
            '${VersionedStorageSchema.kStatus} = \$${params.length + 1}');
        params.add(status.name);
      }

      if (branch != null) {
        conditions.add(
            '${VersionedStorageSchema.kBranch} = \$${params.length + 1}');
        params.add(branch);
      }

      final result = await connection.execute(
        '''
        SELECT * FROM $_versionsTable
        WHERE ${conditions.join(' AND ')}
        ORDER BY ${VersionedStorageSchema.kSequenceNumber} DESC
        ''',
        parameters: params,
      );

      return result.map(_rowToVersionNode).toList();
    });
  }

  @override
  Future<List<VersionNode>> findNodes({VaultQuery? query}) async {
    return await _pool.run((Session connection) async {
      await _setTenantContext(connection);

      // Simplified implementation
      final result = await connection.execute(
        '''
        SELECT * FROM $_versionsTable
        WHERE ${VersionedStorageSchema.kTenantId} = \$1
        ORDER BY ${VersionedStorageSchema.kCreatedAt} DESC
        ''',
        parameters: [_tenantId],
      );

      return result.map(_rowToVersionNode).toList();
    });
  }

  @override
  Future<PageResult<VersionNode>> findNodesPage(VaultQuery query) async {
    final nodes = await findNodes(query: query);
    return PageResult(
      items: nodes,
      total: nodes.length,
      offset: query.offset ?? 0,
      limit: query.limit ?? nodes.length,
    );
  }

  @override
  Future<VersionNode?> getLatestPublished(String entityId) async {
    return await _pool.run((Session connection) async {
      await _setTenantContext(connection);

      final result = await connection.execute(
        '''
        SELECT * FROM $_versionsTable
        WHERE ${VersionedStorageSchema.kEntityId} = \$1
          AND ${VersionedStorageSchema.kTenantId} = \$2
          AND ${VersionedStorageSchema.kStatus} = \$3
        ORDER BY ${VersionedStorageSchema.kSequenceNumber} DESC
        LIMIT 1
        ''',
        parameters: [entityId, _tenantId, VersionStatus.published.name],
      );

      if (result.isEmpty) return null;
      return _rowToVersionNode(result.first);
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // INDEXES & STREAMS
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Future<void> registerIndex(VaultIndex index) async {
    // Indexes are managed by PostgresSchemaDeployer
  }

  @override
  Stream<List<VersionNode>> watchVersions(String entityId) {
    // TODO: Implement using PostgreSQL LISTEN/NOTIFY
    return Stream.empty();
  }

  @override
  Stream<List<VersionNode>> watchAllEntities({VaultQuery? query}) {
    // TODO: Implement using PostgreSQL LISTEN/NOTIFY
    return Stream.empty();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // HELPER METHODS
  // ══════════════════════════════════════════════════════════════════════════

  Future<VersionNode?> getNodeById(String nodeId) async {
    return await _pool.run((Session connection) async {
      await _setTenantContext(connection);

      final result = await connection.execute(
        '''
        SELECT * FROM $_versionsTable
        WHERE ${VersionedStorageSchema.kNodeId} = \$1
          AND ${VersionedStorageSchema.kTenantId} = \$2
        ''',
        parameters: [nodeId, _tenantId],
      );

      if (result.isEmpty) return null;
      return _rowToVersionNode(result.first);
    });
  }

  Future<void> _setCurrentVersion(String entityId, String nodeId) async {
    await _pool.run((connection) async {
      await connection.execute(
        '''
        INSERT INTO $_currentTable (
          ${VersionedStorageSchema.kEntityId},
          ${VersionedStorageSchema.kTenantId},
          ${VersionedStorageSchema.kNodeId},
          ${VersionedStorageSchema.kUpdatedAt}
        ) VALUES (\$1, \$2, \$3, NOW())
        ON CONFLICT (${VersionedStorageSchema.kEntityId}, ${VersionedStorageSchema.kTenantId})
        DO UPDATE SET
          ${VersionedStorageSchema.kNodeId} = EXCLUDED.${VersionedStorageSchema.kNodeId},
          ${VersionedStorageSchema.kUpdatedAt} = NOW()
        ''',
        parameters: [entityId, _tenantId, nodeId],
      );
    });
  }

  Future<Semver?> _getLatestVersion(String entityId) async {
    return await _pool.run((Session connection) async {
      await _setTenantContext(connection);

      final result = await connection.execute(
        '''
        SELECT ${VersionedStorageSchema.kVersion}
        FROM $_versionsTable
        WHERE ${VersionedStorageSchema.kEntityId} = \$1
          AND ${VersionedStorageSchema.kTenantId} = \$2
          AND ${VersionedStorageSchema.kVersion} IS NOT NULL
        ORDER BY ${VersionedStorageSchema.kSequenceNumber} DESC
        LIMIT 1
        ''',
        parameters: [entityId, _tenantId],
      );

      if (result.isEmpty) return null;
      final versionStr = result.first[0] as String?;
      return versionStr != null ? Semver.parse(versionStr) : null;
    });
  }

  VersionNode _rowToVersionNode(ResultRow row) {
    final cols = row.toColumnMap();
    return VersionNode(
      nodeId: cols[VersionedStorageSchema.kNodeId] as String,
      entityId: cols[VersionedStorageSchema.kEntityId] as String,
      parentNodeId: cols[VersionedStorageSchema.kParentNodeId] as String?,
      status: VersionStatus.fromString(
          cols[VersionedStorageSchema.kStatus] as String),
      version: cols[VersionedStorageSchema.kVersion] != null
          ? Semver.parse(cols[VersionedStorageSchema.kVersion] as String)
          : null,
      sequenceNumber: cols[VersionedStorageSchema.kSequenceNumber] as int,
      createdBy: cols[VersionedStorageSchema.kCreatedBy] as String,
      createdAt: cols[VersionedStorageSchema.kCreatedAt] as DateTime,
      data: cols[VersionedStorageSchema.kData] as Map<String, dynamic>,
      isCurrent: false, // Will be set by getCurrent if needed
      branch: cols[VersionedStorageSchema.kBranch] as String,
    );
  }

  String _uuid() {
    // Simple UUID v4 generator
    final random = DateTime.now().millisecondsSinceEpoch;
    return 'node_${random}_${_tenantId.hashCode.abs()}';
  }
}
