import 'dart:async';

import 'package:aq_schema/aq_schema.dart';

import '../client/vault.dart';
import '../exceptions/vault_exceptions.dart';
import '../storage/postgres/postgres_vault_storage.dart';
import '../storage/postgres/postgres_schema_deployer.dart';
import '../storage/postgres/postgres_versioned_repository.dart';
import 'domain_registration.dart';
import 'schema_deployer.dart';

/// Central registry for domain collections in a dart_vault Data Service.
///
/// ## Responsibilities
///
/// 1. **Registration** — holds [DomainRegistration]s with `fromMap` factories
/// 2. **Schema** — delegates to [SchemaDeployer] to auto-create tables on startup
/// 3. **RPC dispatch** — routes `{collection, operation, args}` to the correct
///    repository method (used by the HTTP RPC handler)
/// 4. **Handshake** — generates the collections manifest for [RemoteVaultStorage]
///    clients
///
/// ## Setup
///
/// ```dart
/// // In Data Service startup:
/// final registry = VaultRegistry(
///   storageFactory: (tenantId) => PostgresVaultStorage(pool: pg, tenantId: tenantId),
///   deployer: PostgresSchemaDeployer(pool: pg),
/// );
///
/// registry
///   ..register(DomainRegistration(
///       collection: 'blueprints',
///       mode: StorageMode.versioned,
///       fromMap: Blueprint.fromMap,
///   ))
///   ..register(DomainRegistration(
///       collection: 'runs',
///       mode: StorageMode.logged,
///       fromMap: WorkflowRun.fromMap,
///   ));
///
/// await registry.deploy(); // creates tables if needed
/// ```
final class VaultRegistry {
  final VaultStorage Function(String tenantId) _storageFactory;
  final SchemaDeployer _deployer;
  final _domains = <String, DomainRegistration>{};

  VaultRegistry({
    required VaultStorage Function(String tenantId) storageFactory,
    SchemaDeployer? deployer,
  })  : _storageFactory = storageFactory,
        _deployer = deployer ?? InMemorySchemaDeployer();

  /// Проверяет, зарегистрирована ли коллекция в registry.
  bool isRegistered(String collection) => _domains.containsKey(collection);

  // ── Registration ──────────────────────────────────────────────────────────

  /// Register a domain collection.
  VaultRegistry register(DomainRegistration domain) {
    _domains[domain.collection] = domain;
    return this;
  }

  /// All registered domain registrations.
  List<DomainRegistration> get registrations =>
      List.unmodifiable(_domains.values);

  // ── Schema deployment ─────────────────────────────────────────────────────

  /// Ensure the storage schema exists for all registered domains.
  /// Call once on Data Service startup.
  Future<void> deploy() => _deployer.ensureSchema(registrations);

  /// Возвращает все записи из _vault_registry в БД.
  /// Полезно для диагностики и мониторинга.
  Future<List<Map<String, dynamic>>> getDbRegistry() async {
    if (_deployer is! PostgresSchemaDeployer) return [];
    return (_deployer as PostgresSchemaDeployer).getRegistryEntries();
  }

  // ── Handshake manifest ────────────────────────────────────────────────────

  /// Build the handshake response payload (collections + capabilities).
  Map<String, dynamic> buildHandshake(String tenantId) => {
        'serverVersion': '0.4.0',
        'tenantId': tenantId,
        'collections': _domains.values.map((d) => d.toInfo()).toList(),
        'capabilities': ['direct', 'versioned', 'logged', 'artifact', 'vector'],
        'compatible': true,
      };

  // ── RPC dispatch ──────────────────────────────────────────────────────────

  /// Dispatch an RPC call to the correct repository and return a JSON-safe result.
  ///
  /// [tenantId] is extracted from the request JWT by the HTTP layer.
  Future<dynamic> dispatch({
    required String collection,
    required String operation,
    required Map<String, dynamic> args,
    required String tenantId,
  }) async {
    // Обработка _log коллекций для LoggedStorable
    if (collection.endsWith('_log')) {
      final baseCollection = collection.substring(0, collection.length - 4);
      final reg = _domains[baseCollection];

      if (reg == null) {
        throw VaultNotFoundException(
            'Collection "$baseCollection" is not registered in this Data Service.');
      }

      if (reg.mode != StorageMode.logged) {
        throw VaultStorageException(
            'Collection "$baseCollection" is not LoggedStorable, cannot query log.');
      }

      // Для _log коллекций выполняем query напрямую на storage
      final storage = _storageFactory(tenantId);
      final vault = Vault(storage: storage, tenantId: tenantId);

      try {
        return await _dispatchLogQuery(storage, collection, operation, args);
      } finally {
        await vault.dispose();
      }
    }

    final reg = _domains[collection];
    if (reg == null) {
      throw VaultNotFoundException(
          'Collection "$collection" is not registered in this Data Service.');
    }

    // ВАЖНО: передаём реальный tenantId в Vault.
    // PostgresVaultStorage использует его для RLS через _setTenantContext().
    final storage = _storageFactory(tenantId);
    final vault = Vault(storage: storage, tenantId: tenantId);

    try {
      return switch (reg.mode) {
        StorageMode.direct =>
          await _dispatchDirect(reg, vault, operation, args),
        StorageMode.versioned =>
          await _dispatchVersioned(reg, vault, storage, tenantId, operation, args),
        StorageMode.logged =>
          await _dispatchLogged(reg, vault, operation, args),
        _ => throw VaultStorageException(
            'RPC dispatch not implemented for mode: ${reg.mode.name}'),
      };
    } finally {
      await vault.dispose();
    }
  }

  // ── Direct dispatch ───────────────────────────────────────────────────────

  Future<dynamic> _dispatchDirect(
    DomainRegistration reg,
    Vault vault,
    String operation,
    Map<String, dynamic> args,
  ) async {
    final repo = vault.direct(
      collection: reg.collection,
      fromMap: (m) => reg.fromMap(m) as DirectStorable,
    );

    switch (operation) {
      case 'put':
        final entity =
            reg.fromMap(args['data'] as Map<String, dynamic>) as DirectStorable;
        await repo.save(entity);
        return null;

      case 'putAll':
        final entries = (args['entries'] as Map<String, dynamic>).map((k, v) =>
            MapEntry(
                k, reg.fromMap(v as Map<String, dynamic>) as DirectStorable));
        await repo.saveAll(entries.values.toList());
        return null;

      case 'get':
        final e = await repo.findById(args['id'] as String);
        return e?.toMap();

      case 'exists':
        return await repo.exists(args['id'] as String);

      case 'delete':
        await repo.delete(args['id'] as String);
        return null;

      case 'restore':
        await repo.restore(args['id'] as String);
        return null;

      case 'query':
        final q = _deserializeQuery(args['query'] as Map<String, dynamic>?);
        final items = await repo.findAll(query: q);
        return items.map((e) => e.toMap()).toList();

      case 'queryIncludingDeleted':
        final q = _deserializeQuery(args['query'] as Map<String, dynamic>?);
        final items = await repo.findAllIncludingDeleted(query: q);
        return items.map((e) => e.toMap()).toList();

      case 'queryPage':
        final q = _deserializeQuery(args['query'] as Map<String, dynamic>?);
        final page = await repo.findPage(q ?? const VaultQuery());
        return {
          'items': page.items.map((e) => e.toMap()).toList(),
          'total': page.total,
          'offset': page.offset,
          'limit': page.limit,
        };

      case 'count':
        final q = _deserializeQuery(args['query'] as Map<String, dynamic>?);
        return await repo.count(query: q);

      case 'createIndex':
        // No-op on remote — indexes are managed server-side by SchemaDeployer
        return null;

      case 'clear':
        // Danger: only allow from admin context; HTTP layer must guard this.
        return null;

      default:
        throw VaultStorageException('Unknown direct operation: $operation');
    }
  }

  // ── Versioned dispatch ────────────────────────────────────────────────────

  Future<dynamic> _dispatchVersioned(
    DomainRegistration reg,
    Vault vault,
    VaultStorage storage,
    String tenantId,
    String operation,
    Map<String, dynamic> args,
  ) async {
    // Use PostgresVersionedRepository for PostgreSQL storage
    final repo = storage is PostgresVaultStorage
        ? PostgresVersionedRepository(
            pool: storage.pool,
            collection: reg.collection,
            tenantId: tenantId,
            fromMap: (m) => reg.fromMap(m) as VersionedStorable,
          )
        : vault.versioned(
            collection: reg.collection,
            fromMap: (m) => reg.fromMap(m) as VersionedStorable,
          );

    switch (operation) {
      case 'put': // createEntity
        final model = reg.fromMap(args['data'] as Map<String, dynamic>)
            as VersionedStorable;
        final node = await repo.createEntity(model);
        return node.toMap();

      case 'updateDraft':
        final model = reg.fromMap(args['data'] as Map<String, dynamic>)
            as VersionedStorable;
        await repo.updateDraft(args['nodeId'] as String, model);
        return null;

      case 'publishDraft':
        final increment = IncrementType.values.firstWhere(
          (i) => i.name == (args['increment'] as String? ?? 'patch'),
        );
        final node = await repo.publishDraft(
          args['nodeId'] as String,
          increment: increment,
        );
        return node.toMap();

      case 'snapshotVersion':
        final node = await repo.snapshotVersion(args['nodeId'] as String);
        return node.toMap();

      case 'deleteVersion':
        await repo.deleteVersion(args['nodeId'] as String);
        return null;

      case 'delete':
        await repo.deleteEntity(args['id'] as String);
        return null;

      case 'getCurrent':
        final entity = await repo.getCurrent(args['entityId'] as String);
        return entity?.toMap();

      case 'getVersion':
        final entity = await repo.getVersion(args['nodeId'] as String);
        return entity?.toMap();

      case 'getVersionNode':
        // Получить VersionNode по nodeId
        // Для PostgresVersionedRepository используем getNodeById
        if (storage is PostgresVaultStorage && repo is PostgresVersionedRepository) {
          final node = await (repo as PostgresVersionedRepository).getNodeById(args['nodeId'] as String);
          return node?.toMap();
        } else {
          // Для других реализаций нужен entityId
          final entityId = args['entityId'] as String?;
          if (entityId == null || entityId.isEmpty) {
            throw VaultStorageException('entityId required for non-PostgreSQL storage');
          }
          final nodes = await repo.listVersions(entityId);
          final nodeId = args['nodeId'] as String;
          final node = nodes.cast<VersionNode?>().firstWhere(
            (n) => n?.nodeId == nodeId,
            orElse: () => null,
          );
          return node?.toMap();
        }

      case 'get': // alias for getCurrent
        final entity = await repo.getCurrent(args['id'] as String);
        return entity?.toMap();

      case 'listVersions':
        final nodes = await repo.listVersions(args['entityId'] as String);
        return nodes.map((n) => n.toMap()).toList();

      case 'query':
        final q = _deserializeQuery(args['query'] as Map<String, dynamic>?);
        final nodes = await repo.findNodes(query: q);
        return nodes.map((n) => n.toMap()).toList();

      case 'queryPage':
        final q = _deserializeQuery(args['query'] as Map<String, dynamic>?) ??
            const VaultQuery();
        final page = await repo.findNodesPage(q);
        return {
          'items': page.items.map((n) => n.toMap()).toList(),
          'total': page.total,
          'offset': page.offset,
          'limit': page.limit,
        };

      case 'count':
        final nodes = await repo.findNodes();
        return nodes.length;

      case 'grantAccess':
        await repo.grantAccess(
          args['entityId'] as String,
          actorId: args['actorId'] as String,
          level: AccessLevel.values.firstWhere(
            (l) => l.name == (args['level'] as String? ?? 'read'),
          ),
          requesterId: args['requesterId'] as String,
        );
        return null;

      case 'revokeAccess':
        await repo.revokeAccess(
          args['entityId'] as String,
          actorId: args['actorId'] as String,
          requesterId: args['requesterId'] as String,
        );
        return null;

      case 'hasAccess':
        return await repo.hasAccess(
          args['entityId'] as String,
          actorId: args['actorId'] as String,
          minimumLevel: AccessLevel.values.firstWhere(
            (l) => l.name == (args['level'] as String? ?? 'read'),
          ),
        );

      case 'createBranch':
        final model = reg.fromMap(args['data'] as Map<String, dynamic>)
            as VersionedStorable;
        final node = await repo.createBranch(
          args['parentNodeId'] as String,
          branchName: args['branchName'] as String,
          model: model,
        );
        return node.toMap();

      case 'mergeToMain':
        final node = await repo.mergeToMain(
          args['entityId'] as String,
          sourceBranch: args['sourceBranch'] as String,
          requesterId: args['requesterId'] as String,
          fromMap: (m) => reg.fromMap(m) as VersionedStorable,
        );
        return node.toMap();

      case 'listBranches':
        return await repo.listBranches(args['entityId'] as String);

      case 'createIndex':
      case 'clear':
        return null;

      default:
        throw VaultStorageException('Unknown versioned operation: $operation');
    }
  }

  // ── Logged dispatch ───────────────────────────────────────────────────────

  Future<dynamic> _dispatchLogged(
    DomainRegistration reg,
    Vault vault,
    String operation,
    Map<String, dynamic> args,
  ) async {
    final repo = vault.logged(
      collection: reg.collection,
      fromMap: (m) => reg.fromMap(m) as LoggedStorable,
      captureFullSnapshot: args['captureFullSnapshot'] as bool? ?? false,
    );

    switch (operation) {
      case 'put': // save
        final entity =
            reg.fromMap(args['data'] as Map<String, dynamic>) as LoggedStorable;
        await repo.save(entity, actorId: args['actorId'] as String? ?? 'rpc');
        return null;

      case 'delete':
        await repo.delete(
          args['id'] as String,
          actorId: args['actorId'] as String? ?? 'rpc',
        );
        return null;

      case 'restore':
        await repo.restore(
          args['id'] as String,
          actorId: args['actorId'] as String? ?? 'rpc',
        );
        return null;

      case 'get':
        final e = await repo.findById(args['id'] as String);
        return e?.toMap();

      case 'query':
        final q = _deserializeQuery(args['query'] as Map<String, dynamic>?);
        final items = await repo.findAll(query: q);
        return items.map((e) => e.toMap()).toList();

      case 'queryIncludingDeleted':
        final q = _deserializeQuery(args['query'] as Map<String, dynamic>?);
        final items = await repo.findAllIncludingDeleted(query: q);
        return items.map((e) => e.toMap()).toList();

      case 'queryPage':
        final q = _deserializeQuery(args['query'] as Map<String, dynamic>?) ??
            const VaultQuery();
        final page = await repo.findPage(q);
        return {
          'items': page.items.map((e) => e.toMap()).toList(),
          'total': page.total,
          'offset': page.offset,
          'limit': page.limit,
        };

      case 'count':
        return await repo.count();

      case 'exists':
        return await repo.exists(args['id'] as String);

      case 'getHistory':
        final hist = await repo.getHistory(args['entityId'] as String);
        return hist.map((e) => e.toMap()).toList();

      case 'rollbackTo':
        await repo.rollbackTo(
          args['entityId'] as String,
          args['entryId'] as String,
          actorId: args['actorId'] as String? ?? 'rpc',
        );
        return null;

      case 'createIndex':
      case 'clear':
        return null;

      default:
        throw VaultStorageException('Unknown logged operation: $operation');
    }
  }

  // ── Log query dispatch ────────────────────────────────────────────────────

  /// Обработка запросов к _log коллекциям.
  /// Выполняет query напрямую на storage без создания репозитория.
  Future<dynamic> _dispatchLogQuery(
    VaultStorage storage,
    String logCollection,
    String operation,
    Map<String, dynamic> args,
  ) async {
    switch (operation) {
      case 'query':
        final q = _deserializeQuery(args['query'] as Map<String, dynamic>?);
        final items = await storage.query(logCollection, q ?? const VaultQuery());
        return items; // Возвращаем Map напрямую, не преобразуем в LogEntry

      case 'queryPage':
        final q = _deserializeQuery(args['query'] as Map<String, dynamic>?) ??
            const VaultQuery();
        final page = await storage.queryPage(logCollection, q);
        return {
          'items': page.items,
          'total': page.total,
          'offset': page.offset,
          'limit': page.limit,
        };

      case 'get':
        final result = await storage.get(logCollection, args['id'] as String);
        return result;

      case 'count':
        final q = _deserializeQuery(args['query'] as Map<String, dynamic>?);
        return await storage.count(logCollection, q ?? const VaultQuery());

      default:
        throw VaultStorageException(
            'Operation "$operation" not supported for log collections');
    }
  }

  // ── Query deserialisation ─────────────────────────────────────────────────

  VaultQuery? _deserializeQuery(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    var q = const VaultQuery();

    final filters = (raw['filters'] as List?) ?? [];
    for (final f in filters.whereType<Map<String, dynamic>>()) {
      final op = VaultOperator.values.firstWhere(
        (o) => o.name == (f['operator'] as String? ?? 'equals'),
        orElse: () => VaultOperator.equals,
      );
      q = q.where(f['field'] as String, op, f['value']);
    }

    if (raw['sortField'] != null) {
      q = q.orderBy(
        raw['sortField'] as String,
        descending: raw['sortDescending'] as bool? ?? false,
      );
    }

    final limit = raw['limit'] as int?;
    final offset = raw['offset'] as int?;
    if (limit != null) q = q.page(limit: limit, offset: offset ?? 0);

    return q;
  }
}
