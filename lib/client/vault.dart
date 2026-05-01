import 'package:aq_schema/aq_schema.dart';

import 'remote/remote_vault_storage.dart';
import 'remote/remote_logged_repository.dart';
import '../storage/in_memory_vault_storage.dart';
import '../storage/local_buffer_vault_storage.dart';
import '../storage/direct_repository_impl.dart';
import '../storage/versioned_repository_impl.dart';
import '../storage/logged_repository_impl.dart';

/// Factory and entry point for dart_vault.
///
/// ## Singleton
///
/// ```dart
/// // main.dart — один раз до runApp
/// await Vault.connect('http://localhost:8765');
///
/// // Везде в приложении
/// Vault.instance.versioned<WorkflowGraph>(...)
/// ```
///
/// ## Локальный буфер (LocalBufferVaultStorage)
///
/// Всегда включён когда Vault работает с удалённым хранилищем.
/// Все записи сначала идут в локальный буфер (InMemoryVaultStorage).
/// В удалённую БД данные уходят только по [buffer.flush].
///
/// ```dart
/// // Проверить несохранённые изменения
/// final dirty = Vault.instance.buffer?.isDirty(WorkflowGraph.kCollection, id);
///
/// // Сохранить в БД
/// await Vault.instance.buffer?.flush(WorkflowGraph.kCollection, id: graphId);
///
/// // Отбросить изменения
/// await Vault.instance.buffer?.discard(WorkflowGraph.kCollection, id: graphId);
///
/// // Предзагрузить для офлайн-работы
/// await Vault.instance.buffer?.warmupAll(WorkflowGraph.kCollection);
/// ```
///
/// ## Multi-tenancy
///
/// tenantId передаётся в хранилище для изоляции данных.
/// - InMemoryVaultStorage: фильтрует записи по tenantId
/// - PostgresVaultStorage: использует RLS (Row Level Security) политики
/// Префикс `{tenantId}__` больше не используется.
final class Vault {
  final VaultStorage storage;
  final String tenantId;

  Vault({
    VaultStorage? storage,
    this.tenantId = 'system',
  }) : storage = storage ?? InMemoryVaultStorage(tenantId: tenantId);

  // ── Singleton ──────────────────────────────────────────────────────────────

  static Vault? _singleton;

  /// Глобальный singleton. Доступен после [connect].
  static Vault get instance {
    assert(
      _singleton != null,
      '[Vault] Call Vault.connect() before accessing Vault.instance',
    );
    return _singleton!;
  }

  /// Подключиться к Data Service и инициализировать singleton.
  ///
  /// Автоматически оборачивает RemoteVaultStorage в [LocalBufferVaultStorage].
  /// После connect все записи буферизуются локально (если useBuffer = true).
  /// Используйте [Vault.instance.buffer] для управления буфером.
  ///
  /// Для серверных приложений используйте useBuffer: false для прямого подключения.
  ///
  /// ```dart
  /// await Vault.connect('http://localhost:8765');
  /// await Vault.connect('http://localhost:8765', tenantId: userId);
  /// await Vault.connect('http://localhost:8765', useBuffer: false); // для серверов
  /// ```
  static Future<void> connect(
    String endpoint, {
    String tenantId = 'system',
    bool useBuffer = true,
    bool failFast = false,
  }) async {
    if (_singleton != null) return;
    _singleton = await remote(
      endpoint: endpoint,
      tenantId: tenantId,
      useBuffer: useBuffer,
      failFast: failFast,
    );
  }

  /// Сбросить singleton (для тестов или смены пользователя).
  static Future<void> disconnect() async {
    await _singleton?.dispose();
    _singleton = null;
  }

  // ── Буфер ──────────────────────────────────────────────────────────────────

  /// Локальный буфер — доступен если хранилище является [IBufferedStorage].
  ///
  /// Для Vault созданного через [connect] с useBuffer: true буфер присутствует.
  /// Для Vault с useBuffer: false или InMemoryVaultStorage буфер отсутствует (null) —
  /// все операции идут напрямую в хранилище.
  IBufferedStorage? get buffer =>
      storage is IBufferedStorage ? storage as IBufferedStorage : null;

  // ── Repository factories ───────────────────────────────────────────────────

  DirectRepository<T> direct<T extends DirectStorable>({
    required String collection,
    required T Function(Map<String, dynamic>) fromMap,
    List<VaultIndex> indexes = const [],
  }) {
    final col = _qualify(collection);
    final repo = DirectRepositoryImpl<T>(
      storage: storage,
      collection: col,
      fromMap: fromMap,
    );
    _initIndexes((idx) => repo.registerIndex(idx), indexes);
    return repo;
  }

  VersionedRepository<T> versioned<T extends VersionedStorable>({
    required String collection,
    required T Function(Map<String, dynamic>) fromMap,
    List<VaultIndex> indexes = const [],
  }) {
    final col = _qualify(collection);
    final repo = VersionedRepositoryImpl<T>(
      storage: storage,
      collection: col,
      fromMap: fromMap,
    );
    _initIndexes((idx) => repo.registerIndex(idx), indexes);
    return repo;
  }

  LoggedRepository<T> logged<T extends LoggedStorable>({
    required String collection,
    required T Function(Map<String, dynamic>) fromMap,
    List<VaultIndex> indexes = const [],
    bool captureFullSnapshot = false,
  }) {
    final col = _qualify(collection);

    // Resolve the underlying remote storage if wrapped in a buffer
    final base = storage is LocalBufferVaultStorage
        ? (storage as LocalBufferVaultStorage).remote
        : storage;

    // Remote: thin client — no business logic, no knowledge of _log tables
    if (base is RemoteVaultStorage) {
      final repo = RemoteLoggedRepository<T>(
        storage: base,
        collection: col,
        fromMap: fromMap,
      );
      _initIndexes((idx) => repo.registerIndex(idx), indexes);
      return repo;
    }

    // Local (InMemory / PostgreSQL on server): full business logic
    final repo = LoggedRepositoryImpl<T>(
      storage: storage,
      collection: col,
      fromMap: fromMap,
      captureFullSnapshot: captureFullSnapshot,
    );
    _initIndexes((idx) => repo.registerIndex(idx), indexes);
    return repo;
  }

  // ── Фабрики хранилищ ───────────────────────────────────────────────────────

  /// Создать Vault с удалённым хранилищем.
  ///
  /// По умолчанию оборачивает в [LocalBufferVaultStorage] для UI приложений.
  /// Для серверных приложений используйте useBuffer: false для прямого подключения.
  ///
  /// ```dart
  /// // UI приложение (с буфером)
  /// final vault = await Vault.remote(endpoint: 'http://localhost:8765');
  ///
  /// // Серверное приложение (без буфера)
  /// final vault = await Vault.remote(
  ///   endpoint: 'http://localhost:8765',
  ///   useBuffer: false,
  /// );
  /// ```
  static Future<Vault> remote({
    required String endpoint,
    String tenantId = 'system',
    bool useBuffer = true,
    bool failFast = false,
    String? authToken,
  }) async {
    final remoteStorage = RemoteVaultStorage(
      endpoint: endpoint,
      tenantId: tenantId,
      authToken: authToken,
    );
    try {
      await remoteStorage.connect();
    } catch (e) {
      if (failFast) rethrow;
      assert(() {
        // ignore: avoid_print
        print('[Vault] Cannot connect to $endpoint, falling back to in-memory. Error: $e');
        return true;
      }());
      return Vault(
        storage: InMemoryVaultStorage(tenantId: tenantId),
        tenantId: tenantId,
      );
    }

    final storage =
        useBuffer ? LocalBufferVaultStorage(remoteStorage) : remoteStorage;

    return Vault(storage: storage, tenantId: tenantId);
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  Future<void> dispose() => storage.dispose();

  // ── Private ────────────────────────────────────────────────────────────────

  /// Возвращает имя коллекции без изменений.
  /// Тенантность обеспечивается tenant_id колонкой в PostgreSQL (RLS политики)
  /// и tenant_id параметром в InMemoryVaultStorage.
  /// Префикс через __ больше не используется.
  String _qualify(String collection) => collection;

  void _initIndexes(
    Future<void> Function(VaultIndex) register,
    List<VaultIndex> indexes,
  ) {
    if (indexes.isEmpty) return;
    Future.microtask(() async {
      for (final idx in indexes) {
        await register(idx);
      }
    });
  }
}
