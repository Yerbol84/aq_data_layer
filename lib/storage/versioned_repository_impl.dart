import 'dart:async';
import 'package:aq_schema/aq_schema.dart';

import '../client/remote/remote_vault_storage.dart';
import '../storage/local_buffer_vault_storage.dart';
import '../exceptions/vault_exceptions.dart';

// ── Watch-stream race-condition fix (see direct_repository_impl.dart) ──────────
Stream<List<T>> _watchWithBuffer<T>(
  Stream<void> rawChanges,
  Future<List<T>> Function() load,
) async* {
  final buffer = StreamController<void>();
  final sub = rawChanges.listen((_) {
    if (!buffer.isClosed) buffer.add(null);
  });
  try {
    yield await load();
    await for (final _ in buffer.stream) {
      yield await load();
    }
  } finally {
    await sub.cancel();
    await buffer.close();
  }
}

/// Default implementation of [VersionedRepository].
///
/// Internal collections:
/// - `{col}__meta`  — entity metadata (ownerId, grants, currentNodeId)
/// - `{col}__nodes` — [VersionNode] records
///
/// Responsibility split:
/// - [_LifecycleOps]  — state transitions (publish, snapshot, delete)
/// - [_BranchOps]     — branching and merge
/// - [_AccessOps]     — grants / revoke / check
/// - [_QueryOps]      — listVersions, findNodes, etc.
final class VersionedRepositoryImpl<T extends VersionedStorable>
    implements VersionedRepository<T> {
  final VaultStorage _storage;
  final String _collection;
  final T Function(Map<String, dynamic>) _fromMap;

  late final String _metaCol;
  late final String _nodesCol;

  int _rngState = 0;

  VersionedRepositoryImpl({
    required VaultStorage storage,
    required String collection,
    required T Function(Map<String, dynamic>) fromMap,
  })  : _storage = storage,
        _collection = collection,
        _fromMap = fromMap {
    _metaCol = '${collection}__meta';
    _nodesCol = '${collection}__nodes';
  }

  // ── Setup ──────────────────────────────────────────────────────────────────

  Future<void> _ensureCollections() async {
    await _storage.ensureCollection(_metaCol);
    await _storage.ensureCollection(_nodesCol);
  }

  // ════════════════════════════════════════════════════════════════════════════
  // CREATE & EDIT
  // ════════════════════════════════════════════════════════════════════════════

  @override
  Future<VersionNode> createEntity(T model) async {
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
      isCurrent: false, // no current until published
      branch: 'main',
    );

    // ВАЖНО: Для ProxyStorage (remote) делаем ОДИН запрос к основной коллекции.
    // Сервер сам управляет внутренней структурой хранения (_versions, _current).
    // Для локального storage (InMemory) используем внутренние коллекции (__nodes, __meta).
    //
    // Проверяем базовый storage, т.к. он может быть обёрнут в LocalBufferVaultStorage.
    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    if (baseStorage is ProxyStorage) {
      // Remote: вызываем RPC операцию put, которая вернёт VersionNode
      // Сервер создаст VersionNode с правильным nodeId
      final result = await (baseStorage as dynamic).rpc(
        _collection,
        'put',
        {'data': model.toMap()},
      );

      if (result == null) {
        throw VaultStorageException('Server returned null for createEntity');
      }

      // Парсим VersionNode из ответа
      return VersionNode.fromMap(result as Map<String, dynamic>);
    } else {
      // Local: два запроса к внутренним коллекциям
      await _ensureCollections();
      await _storage.put(_nodesCol, nodeId, node.toMap());
      await _storage.put(_metaCol, model.id, {
        'entityId': model.id,
        'ownerId': model.ownerId,
        'currentNodeId': null,
        'sequenceCounter': 1,
      });
    }

    return node;
  }

  @override
  Future<VersionNode> createDraftFrom(String parentNodeId, T model) async {
    final parent = await _getNodeOrThrow(parentNodeId);

    if (parent.status == VersionStatus.deleted) {
      throw const VaultStateException('Cannot branch from a deleted node');
    }

    final meta = await _getMetaOrThrow(parent.entityId);
    final seq = (meta['sequenceCounter'] as int? ?? 1) + 1;
    final nodeId = _uuid();

    final node = VersionNode(
      nodeId: nodeId,
      entityId: parent.entityId,
      parentNodeId: parentNodeId,
      status: VersionStatus.draft,
      sequenceNumber: seq,
      createdBy: model.ownerId,
      createdAt: DateTime.now(),
      data: model.toMap(),
      isCurrent: false,
      branch: parent.branch,
    );

    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    if (baseStorage is ProxyStorage) {
      // Remote: типизированная команда
      await (baseStorage as RemoteVaultStorage).sendCommand(
        _collection,
        CreateDraftFromCommand(parentNodeId: parentNodeId, data: model.toMap()),
      );
    } else {
      // Local: работаем с внутренними коллекциями
      await _ensureCollections();
      await _storage.put(_nodesCol, nodeId, node.toMap());
      await _storage.put(_metaCol, parent.entityId, {
        ...meta,
        'sequenceCounter': seq,
      });
    }

    return node;
  }

  @override
  Future<void> updateDraft(String nodeId, T model) async {
    final node = await _getNodeOrThrow(nodeId);
    if (!node.status.isEditable) {
      throw VaultStateException(
        'Node $nodeId is ${node.status.name} — only DRAFT nodes can be edited',
      );
    }
    final updated = node.copyWith(data: model.toMap());

    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    if (baseStorage is ProxyStorage) {
      // Remote: типизированная команда
      await (baseStorage as RemoteVaultStorage).sendCommand(
        _collection,
        UpdateDraftCommand(nodeId: nodeId, data: model.toMap()),
      );
    } else {
      // Local: обновление в __nodes
      await _storage.put(_nodesCol, nodeId, updated.toMap());
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // LIFECYCLE: PUBLISH & ARCHIVE  (_LifecycleOps)
  // ════════════════════════════════════════════════════════════════════════════

  @override
  Future<VersionNode> publishDraft(
    String nodeId, {
    required IncrementType increment,
  }) async {
    final node = await _getNodeOrThrow(nodeId);
    if (!node.status.isDraft) {
      throw VaultStateException(
        'Only DRAFT nodes can be published. Node $nodeId is ${node.status.name}',
      );
    }

    final newVersion = await _nextVersion(node.entityId, increment);
    final published = node.copyWith(
      status: VersionStatus.published,
      version: newVersion,
      isCurrent: true,
    );

    // Mark previous current as no longer current
    await _clearCurrentFlag(node.entityId);

    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    if (baseStorage is ProxyStorage) {
      // Remote: типизированная команда
      await (baseStorage as RemoteVaultStorage).sendCommand(
        _collection,
        PublishDraftCommand(nodeId: nodeId, increment: increment),
      );
    } else {
      // Local: обновляем __nodes и __meta
      await _storage.put(_nodesCol, nodeId, published.toMap());
      await _storage.put(_metaCol, node.entityId, {
        ...(await _getMetaOrThrow(node.entityId)),
        'currentNodeId': nodeId,
      });
    }

    return published;
  }

  @override
  Future<VersionNode> snapshotVersion(String nodeId) async {
    final node = await _getNodeOrThrow(nodeId);
    if (!node.status.isPublished) {
      throw VaultStateException(
        'Only PUBLISHED nodes can be snapshotted. '
        'Node $nodeId is ${node.status.name}',
      );
    }
    final snapped = node.copyWith(status: VersionStatus.snapshot);

    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    if (baseStorage is ProxyStorage) {
      // Remote: обновление через базовую коллекцию
      await _storage.put(_collection, nodeId, snapped.toMap());
    } else {
      // Local: обновление в __nodes
      await _storage.put(_nodesCol, nodeId, snapped.toMap());
    }

    return snapped;
  }

  @override
  Future<void> deleteVersion(String nodeId) async {
    final node = await _getNodeOrThrow(nodeId);
    final deleted = node.copyWith(
      status: VersionStatus.deleted,
      isCurrent: false,
    );

    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    if (baseStorage is ProxyStorage) {
      // Remote: сервер сам обновит метаданные
      await _storage.put(_collection, nodeId, deleted.toMap());
    } else {
      // Local: обновляем __nodes и __meta
      await _storage.put(_nodesCol, nodeId, deleted.toMap());

      // If this was current, clear the currentNodeId in meta
      final meta = await _getMetaOrThrow(node.entityId);
      if (meta['currentNodeId'] == nodeId) {
        await _storage.put(_metaCol, node.entityId, {
          ...meta,
          'currentNodeId': null,
        });
      }
    }
  }

  @override
  Future<void> deleteEntity(String entityId) async {
    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    if (baseStorage is ProxyStorage) {
      // Remote: сервер сам удалит все связанные данные
      await _storage.delete(_collection, entityId);
    } else {
      // Local: удаляем все ноды и метаданные
      final nodes = await listVersions(entityId);
      for (final node in nodes) {
        await _storage.delete(_nodesCol, node.nodeId);
      }
      await _storage.delete(_metaCol, entityId);
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // BRANCHING  (_BranchOps)
  // ════════════════════════════════════════════════════════════════════════════

  @override
  Future<VersionNode> createBranch(
    String parentNodeId, {
    required String branchName,
    required T model,
  }) async {
    final parent = await _getNodeOrThrow(parentNodeId);
    if (parent.status == VersionStatus.deleted) {
      throw const VaultStateException('Cannot branch from a deleted node');
    }

    final meta = await _getMetaOrThrow(parent.entityId);
    final seq = (meta['sequenceCounter'] as int? ?? 1) + 1;
    final nodeId = _uuid();

    final node = VersionNode(
      nodeId: nodeId,
      entityId: parent.entityId,
      parentNodeId: parentNodeId,
      status: VersionStatus.draft,
      sequenceNumber: seq,
      createdBy: model.ownerId,
      createdAt: DateTime.now(),
      data: model.toMap(),
      isCurrent: false,
      branch: branchName,
    );

    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    if (baseStorage is ProxyStorage) {
      // Remote: типизированная команда
      await (baseStorage as RemoteVaultStorage).sendCommand(
        _collection,
        CreateBranchCommand(
          parentNodeId: parentNodeId,
          branchName: branchName,
          data: model.toMap(),
        ),
      );
    } else {
      // Local: работаем с внутренними коллекциями
      await _ensureCollections();
      await _storage.put(_nodesCol, nodeId, node.toMap());
      await _storage.put(_metaCol, parent.entityId, {
        ...meta,
        'sequenceCounter': seq,
      });
    }

    return node;
  }

  @override
  Future<VersionNode> mergeToMain(
    String entityId, {
    required String sourceBranch,
    required String requesterId,
    required T Function(Map<String, dynamic>) fromMap,
  }) async {
    await _checkAccess(entityId, requesterId, AccessLevel.write);

    // Find the latest node on the source branch
    final allNodes = await listVersions(entityId, branch: sourceBranch);
    final sourceNodes = allNodes.where((n) => !n.status.isDeleted).toList();
    if (sourceNodes.isEmpty) {
      throw VaultNotFoundException(
        'No nodes found on branch "$sourceBranch" for entity $entityId',
      );
    }
    sourceNodes.sort((a, b) => a.sequenceNumber.compareTo(b.sequenceNumber));
    final headNode = sourceNodes.last;

    // Create a new DRAFT on main from the source branch head
    final mergedModel = fromMap(headNode.data);
    final meta = await _getMetaOrThrow(entityId);
    final seq = (meta['sequenceCounter'] as int? ?? 1) + 1;
    final nodeId = _uuid();

    final mergedNode = VersionNode(
      nodeId: nodeId,
      entityId: entityId,
      parentNodeId: headNode.nodeId,
      status: VersionStatus.draft,
      sequenceNumber: seq,
      createdBy: requesterId,
      createdAt: DateTime.now(),
      data: mergedModel.toMap(),
      isCurrent: false,
      branch: 'main',
    );

    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    if (baseStorage is ProxyStorage) {
      // Remote: типизированная команда
      await (baseStorage as RemoteVaultStorage).sendCommand(
        _collection,
        MergeToMainCommand(
          entityId: entityId,
          sourceBranch: sourceBranch,
          requesterId: requesterId,
        ),
      );
    } else {
      // Local: работаем с внутренними коллекциями
      await _storage.put(_nodesCol, nodeId, mergedNode.toMap());
      await _storage.put(_metaCol, entityId, {
        ...meta,
        'sequenceCounter': seq,
      });
    }

    return mergedNode;
  }

  @override
  Future<List<String>> listBranches(String entityId) async {
    final nodes = await listVersions(entityId);
    return nodes.map((n) => n.branch).toSet().toList()..sort();
  }

  // ════════════════════════════════════════════════════════════════════════════
  // CURRENT VERSION
  // ════════════════════════════════════════════════════════════════════════════

  @override
  Future<void> setCurrentVersion(
    String entityId,
    String nodeId, {
    required String requesterId,
  }) async {
    await _checkAccess(entityId, requesterId, AccessLevel.write);
    final node = await _getNodeOrThrow(nodeId);

    if (!node.status.isPublished) {
      throw VaultInvalidTransitionException(
        'Only PUBLISHED nodes can be set as current. '
        'Node $nodeId is ${node.status.name}',
      );
    }

    await _clearCurrentFlag(entityId);
    final updated = node.copyWith(isCurrent: true);

    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    if (baseStorage is ProxyStorage) {
      // Remote: типизированная команда
      await (baseStorage as RemoteVaultStorage).sendCommand(
        _collection,
        SetCurrentVersionCommand(
          entityId: entityId,
          nodeId: nodeId,
          requesterId: requesterId,
        ),
      );
    } else {
      // Local: обновляем __nodes и __meta
      await _storage.put(_nodesCol, nodeId, updated.toMap());
      final meta = await _getMetaOrThrow(entityId);
      await _storage.put(_metaCol, entityId, {
        ...meta,
        'currentNodeId': nodeId,
      });
    }
  }

  @override
  Future<T?> getCurrent(String entityId) async {
    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    if (baseStorage is ProxyStorage) {
      // Remote: запрос через базовую коллекцию
      final data = await _storage.get(_collection, entityId);
      if (data == null) return null;
      // Сервер возвращает current version напрямую
      return _fromMap(data);
    } else {
      // Local: читаем из __meta
      final meta = await _storage.get(_metaCol, entityId);
      final currentNodeId = meta?['currentNodeId'] as String?;
      if (currentNodeId == null) return null;
      return getVersion(currentNodeId);
    }
  }

  @override
  Future<T?> getVersion(String nodeId) async {
    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    final node = baseStorage is ProxyStorage
        ? await _storage.get(_collection, nodeId)
        : await _storage.get(_nodesCol, nodeId);

    if (node == null) return null;
    final vn = VersionNode.fromMap(node);
    if (vn.status.isDeleted) return null;
    return _fromMap(vn.data);
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ACCESS CONTROL  (_AccessOps)
  // ════════════════════════════════════════════════════════════════════════════

  @override
  Future<void> grantAccess(
    String entityId, {
    required String actorId,
    required AccessLevel level,
    required String requesterId,
  }) async {
    // Получить security protocol
    final protocol = IVaultSecurityProtocol.instance;
    if (protocol == null) {
      // Security не инициализирован — проверяем только owner
      final meta = await _getMetaOrThrow(entityId);
      if (meta['ownerId'] != requesterId) {
        throw VaultAccessDeniedException(
          'Only owner can grant access (security protocol not initialized)',
        );
      }
      // Без security protocol не можем сохранить права
      return;
    }

    // 1. Извлечь claims из headers (если есть)
    // TODO(aq_security): Pass headers from client request context
    final claims = await protocol.extractClaims({});

    // 2. Проверить, может ли requester выдавать права
    final decision = await protocol.canGrant(
      claims: claims,
      collection: _collection,
      entityId: entityId,
      targetUserId: actorId,
      level: level,
    );

    if (!decision.allowed) {
      throw VaultAccessDeniedException(
        'Cannot grant access: ${decision.reason ?? "Access denied"}',
      );
    }

    // 3. Выдать право через resource permission service
    await protocol.resourcePermissions.grant(
      resourceId: entityId,
      userId: actorId,
      level: level,
      grantedBy: requesterId,
    );
  }

  @override
  Future<void> revokeAccess(
    String entityId, {
    required String actorId,
    required String requesterId,
  }) async {
    // Получить security protocol
    final protocol = IVaultSecurityProtocol.instance;
    if (protocol == null) {
      // Security не инициализирован — проверяем только owner
      final meta = await _getMetaOrThrow(entityId);
      if (meta['ownerId'] != requesterId) {
        throw VaultAccessDeniedException(
          'Only owner can revoke access (security protocol not initialized)',
        );
      }
      // Без security protocol не можем удалить права
      return;
    }

    // 1. Извлечь claims из headers (если есть)
    // TODO(aq_security): Pass headers from client request context
    final claims = await protocol.extractClaims({});

    // 2. Проверить, может ли requester отзывать права
    // Используем canGrant, так как право отзывать = право выдавать
    final decision = await protocol.canGrant(
      claims: claims,
      collection: _collection,
      entityId: entityId,
      targetUserId: actorId,
      level: AccessLevel.read, // Уровень не важен для проверки
    );

    if (!decision.allowed) {
      throw VaultAccessDeniedException(
        'Cannot revoke access: ${decision.reason ?? "Access denied"}',
      );
    }

    // 3. Отозвать право через resource permission service
    await protocol.resourcePermissions.revoke(
      resourceId: entityId,
      userId: actorId,
      revokedBy: requesterId,
    );
  }

  @override
  Future<bool> hasAccess(
    String entityId, {
    required String actorId,
    required AccessLevel minimumLevel,
  }) async {
    // Получить метаданные для проверки owner
    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    final meta = baseStorage is ProxyStorage
        ? await _storage.get(_collection, entityId)
        : await _storage.get(_metaCol, entityId);

    if (meta == null) return false;

    // Owner всегда имеет доступ
    if (meta['ownerId'] == actorId) return true;

    // Проверить через security protocol
    final protocol = IVaultSecurityProtocol.instance;
    if (protocol == null) {
      // Security не инициализирован — только owner имеет доступ
      return false;
    }

    // Проверить права через resource permission service
    return await protocol.resourcePermissions.hasAccess(
      resourceId: entityId,
      userId: actorId,
      minimumLevel: minimumLevel,
    );
  }

  @override
  Future<List<AqResourcePermission>> listGrants(String entityId) async {
    // Получить security protocol
    final protocol = IVaultSecurityProtocol.instance;
    if (protocol == null) {
      // Security не инициализирован — возвращаем пустой список
      return [];
    }

    // Получить список прав через resource permission service
    return await protocol.resourcePermissions.list(entityId);
  }

  // ════════════════════════════════════════════════════════════════════════════
  // QUERIES  (_QueryOps)
  // ════════════════════════════════════════════════════════════════════════════

  @override
  Future<List<VersionNode>> listVersions(
    String entityId, {
    VersionStatus? status,
    String? branch,
  }) async {
    var q = VaultQuery().where('entityId', VaultOperator.equals, entityId);
    if (status != null) {
      q = q.where('status', VaultOperator.equals, status.name);
    }
    if (branch != null) {
      q = q.where('branch', VaultOperator.equals, branch);
    }
    q = q.orderBy('sequenceNumber');

    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    final rows = baseStorage is ProxyStorage
        ? await _storage.query(_collection, q)
        : await _storage.query(_nodesCol, q);

    return rows.map(VersionNode.fromMap).toList();
  }

  @override
  Future<List<VersionNode>> findNodes({VaultQuery? query}) async {
    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    final rows = baseStorage is ProxyStorage
        ? await _storage.query(_collection, query ?? const VaultQuery())
        : await _storage.query(_nodesCol, query ?? const VaultQuery());

    return rows.map(VersionNode.fromMap).toList();
  }

  @override
  Future<PageResult<VersionNode>> findNodesPage(VaultQuery query) async {
    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    final page = baseStorage is ProxyStorage
        ? await _storage.queryPage(_collection, query)
        : await _storage.queryPage(_nodesCol, query);

    return page.map(VersionNode.fromMap);
  }

  @override
  Future<VersionNode?> getLatestPublished(String entityId) async {
    final published = await listVersions(
      entityId,
      status: VersionStatus.published,
    );
    if (published.isEmpty) return null;
    published.sort(
      (a, b) => (b.version ?? Semver.zero).compareTo(a.version ?? Semver.zero),
    );
    return published.first;
  }

  // ── Indexes ────────────────────────────────────────────────────────────────

  @override
  Future<void> registerIndex(VaultIndex index) {
    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    return baseStorage is ProxyStorage
        ? _storage.createIndex(_collection, index)
        : _storage.createIndex(_nodesCol, index);
  }

  // ── Streams ────────────────────────────────────────────────────────────────

  @override
  Stream<List<VersionNode>> watchVersions(String entityId) {
    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    final collection = baseStorage is ProxyStorage ? _collection : _nodesCol;

    return _watchWithBuffer<VersionNode>(
      _storage.watchChanges(collection),
      () => listVersions(entityId),
    );
  }

  @override
  Stream<List<VersionNode>> watchAllEntities({VaultQuery? query}) {
    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    final collection = baseStorage is ProxyStorage ? _collection : _nodesCol;

    return _watchWithBuffer<VersionNode>(
      _storage.watchChanges(collection),
      () => findNodes(query: query),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PRIVATE HELPERS
  // ════════════════════════════════════════════════════════════════════════════

  Future<VersionNode> _getNodeOrThrow(String nodeId) async {
    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    if (baseStorage is ProxyStorage) {
      // Remote: используем RPC операцию getVersionNode
      // ProxyStorage это маркер, нужен доступ к методу rpc
      // Используем dynamic cast для доступа к rpc методу
      final result = await (baseStorage as dynamic).rpc(
        _collection,
        'getVersionNode',
        {'nodeId': nodeId, 'entityId': ''},
      );

      if (result == null) {
        throw VaultNotFoundException('VersionNode $nodeId not found');
      }
      return VersionNode.fromMap(result as Map<String, dynamic>);
    } else {
      // Local: читаем из __nodes коллекции
      final data = await _storage.get(_nodesCol, nodeId);
      if (data == null) {
        throw VaultNotFoundException('VersionNode $nodeId not found');
      }
      return VersionNode.fromMap(data);
    }
  }

  Future<Map<String, dynamic>> _getMetaOrThrow(String entityId) async {
    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    final meta = baseStorage is ProxyStorage
        ? await _storage.get(_collection, entityId)
        : await _storage.get(_metaCol, entityId);

    if (meta == null) {
      throw VaultNotFoundException('Entity metadata $entityId not found');
    }
    return meta;
  }

  Future<void> _checkAccess(
    String entityId,
    String requesterId,
    AccessLevel required,
  ) async {
    final ok = await hasAccess(
      entityId,
      actorId: requesterId,
      minimumLevel: required,
    );
    if (!ok) {
      throw VaultAccessDeniedException(
        'Actor $requesterId does not have ${required.name} access to $entityId',
      );
    }
  }

  Future<Semver> _nextVersion(
    String entityId,
    IncrementType increment,
  ) async {
    final latest = await getLatestPublished(entityId);
    final current = latest?.version ?? Semver.zero;
    return switch (increment) {
      IncrementType.major => current.incrementMajor(),
      IncrementType.minor => current.incrementMinor(),
      IncrementType.patch => current.incrementPatch(),
    };
  }

  Future<void> _clearCurrentFlag(String entityId) async {
    final currentNodes = await listVersions(
      entityId,
      status: VersionStatus.published,
    );

    final baseStorage = _storage is LocalBufferVaultStorage
        ? (_storage as LocalBufferVaultStorage).remote
        : _storage;

    final collection = baseStorage is ProxyStorage ? _collection : _nodesCol;

    for (final n in currentNodes.where((n) => n.isCurrent)) {
      await _storage.put(
        collection,
        n.nodeId,
        n.copyWith(isCurrent: false).toMap(),
      );
    }
  }

  String _uuid() {
    final now = DateTime.now().microsecondsSinceEpoch;
    _rngState = (_rngState * 6364136223846793005 + 1442695040888963407) &
        0x7FFFFFFFFFFFFFFF;
    return '${now.toRadixString(16)}-v-${_rngState.toRadixString(16).padLeft(8, '0')}';
  }
}
