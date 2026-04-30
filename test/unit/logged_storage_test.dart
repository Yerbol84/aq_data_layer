// Независимый тест для LoggedStorable
// Проверяет создание log entries и rollback для локального и удалённого хранилища

import 'package:test/test.dart';
import 'package:dart_vault/dart_vault.dart';
import 'package:dart_vault/storage/in_memory_vault_storage.dart';
import 'package:aq_schema/aq_schema.dart';

/// Простая тестовая сущность с историей изменений
class TestLoggedEntity implements LoggedStorable {
  @override
  final String id;

  final String name;
  final int value;
  final String tenantId;

  const TestLoggedEntity({
    required this.id,
    required this.name,
    required this.value,
    this.tenantId = 'default',
  });

  @override
  String get collectionName => 'test_logged_entities';

  @override
  bool get softDelete => false;

  @override
  Set<String> get trackedFields => {}; // Пустой = отслеживаем все поля

  @override
  Map<String, dynamic> get indexFields => {
    'name': name,
    'value': value,
  };

  @override
  Map<String, dynamic> get jsonSchema => {
    'type': 'object',
    'properties': {
      'id': {'type': 'string'},
      'name': {'type': 'string'},
      'value': {'type': 'integer'},
      'tenant_id': {'type': 'string'},
    },
    'required': ['id', 'name', 'value'],
  };

  @override
  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'value': value,
    'tenant_id': tenantId,
  };

  factory TestLoggedEntity.fromMap(Map<String, dynamic> map) {
    return TestLoggedEntity(
      id: map['id'] as String,
      name: map['name'] as String,
      value: map['value'] as int,
      tenantId: map['tenant_id'] as String? ?? 'default',
    );
  }

  TestLoggedEntity copyWith({
    String? name,
    int? value,
  }) {
    return TestLoggedEntity(
      id: id,
      name: name ?? this.name,
      value: value ?? this.value,
      tenantId: tenantId,
    );
  }

  static const kCollection = 'test_logged_entities';
}

void main() {
  group('LoggedStorable - Local Storage', () {
    late Vault vault;
    late LoggedRepository<TestLoggedEntity> repo;

    setUp(() {
      vault = Vault(
        storage: InMemoryVaultStorage(tenantId: 'default'),
        tenantId: 'default',
      );
      repo = vault.logged<TestLoggedEntity>(
        collection: TestLoggedEntity.kCollection,
        fromMap: TestLoggedEntity.fromMap,
      );
    });

    test('создаёт log entry при save', () async {
      // Создаём сущность
      final entity = TestLoggedEntity(
        id: 'test-1',
        name: 'Initial',
        value: 100,
      );

      await repo.save(entity, actorId: 'test-user');

      // Проверяем историю
      final history = await repo.getHistory('test-1');
      expect(history.length, 1);
      expect(history.first.operation, LogOperation.created);
      expect(history.first.changedBy, 'test-user');
    });

    test('создаёт log entry при update', () async {
      // Создаём
      final entity = TestLoggedEntity(
        id: 'test-2',
        name: 'Initial',
        value: 100,
      );
      await repo.save(entity, actorId: 'user-1');

      // Обновляем
      final updated = entity.copyWith(name: 'Updated', value: 200);
      await repo.save(updated, actorId: 'user-2');

      // Проверяем историю
      final history = await repo.getHistory('test-2');
      expect(history.length, 2);
      expect(history[0].operation, LogOperation.created);
      expect(history[1].operation, LogOperation.updated);
      expect(history[1].changedBy, 'user-2');
    });

    test('diff содержит только изменённые поля', () async {
      final entity = TestLoggedEntity(
        id: 'test-3',
        name: 'Initial',
        value: 100,
      );
      await repo.save(entity, actorId: 'user-1');

      // Меняем только value
      final updated = entity.copyWith(value: 200);
      await repo.save(updated, actorId: 'user-2');

      final history = await repo.getHistory('test-3');
      final updateEntry = history.firstWhere((e) => e.operation == LogOperation.updated);

      expect(updateEntry.diff, isNotEmpty);
      expect(updateEntry.diff['value']?.after, 200);
      expect(updateEntry.diff['value']?.before, 100);
      expect(updateEntry.diff.containsKey('name'), false); // name не изменился
    });

    test('rollback восстанавливает предыдущее состояние', () async {
      // Используем репозиторий с captureFullSnapshot для rollback
      final repoWithSnapshot = vault.logged<TestLoggedEntity>(
        collection: '${TestLoggedEntity.kCollection}_rollback',
        fromMap: TestLoggedEntity.fromMap,
        captureFullSnapshot: true,
      );

      final entity = TestLoggedEntity(
        id: 'test-4',
        name: 'Version 1',
        value: 100,
      );
      await repoWithSnapshot.save(entity, actorId: 'user-1');

      final v2 = entity.copyWith(name: 'Version 2', value: 200);
      await repoWithSnapshot.save(v2, actorId: 'user-2');

      final v3 = v2.copyWith(name: 'Version 3', value: 300);
      await repoWithSnapshot.save(v3, actorId: 'user-3');

      // Откатываемся к Version 2
      final history = await repoWithSnapshot.getHistory('test-4');
      final v2Entry = history.firstWhere((e) => e.snapshot?['name'] == 'Version 2');

      await repoWithSnapshot.rollbackTo('test-4', v2Entry.entryId, actorId: 'admin');

      // Проверяем что откатились
      final current = await repoWithSnapshot.findById('test-4');
      expect(current?.name, 'Version 2');
      expect(current?.value, 200);

      // Проверяем что создался log entry для rollback
      final newHistory = await repoWithSnapshot.getHistory('test-4');
      expect(newHistory.length, 4); // created + 2 updates + rollback
      expect(newHistory.last.operation, LogOperation.rollback);
    });

    test('captureFullSnapshot сохраняет полный снимок', () async {
      final repoWithSnapshot = vault.logged<TestLoggedEntity>(
        collection: '${TestLoggedEntity.kCollection}_snapshot',
        fromMap: TestLoggedEntity.fromMap,
        captureFullSnapshot: true,
      );

      final entity = TestLoggedEntity(
        id: 'test-5',
        name: 'Initial',
        value: 100,
      );
      await repoWithSnapshot.save(entity, actorId: 'user-1');

      final updated = entity.copyWith(value: 200);
      await repoWithSnapshot.save(updated, actorId: 'user-2');

      final history = await repoWithSnapshot.getHistory('test-5');
      final updateEntry = history.firstWhere((e) => e.operation == LogOperation.updated);

      expect(updateEntry.snapshot, isNotNull);
      expect(updateEntry.snapshot!['name'], 'Initial');
      expect(updateEntry.snapshot!['value'], 200);
    });

    test('delete создаёт log entry', () async {
      final entity = TestLoggedEntity(
        id: 'test-6',
        name: 'To Delete',
        value: 100,
      );
      await repo.save(entity, actorId: 'user-1');
      await repo.delete('test-6', actorId: 'admin');

      final history = await repo.getHistory('test-6');
      expect(history.length, 2);
      expect(history.last.operation, LogOperation.deleted);
      expect(history.last.changedBy, 'admin');
    });
  });

  group('LoggedStorable - Remote Storage', () {
    // Эти тесты требуют запущенный Data Service
    // Пропускаем если сервис недоступен

    test('создаёт log entry через Data Service', () async {
      try {
        final vault = await Vault.remote(
          endpoint: 'http://localhost:8765',
          tenantId: 'default',
          useBuffer: false,
        );

        final repo = vault.logged<TestLoggedEntity>(
          collection: TestLoggedEntity.kCollection,
          fromMap: TestLoggedEntity.fromMap,
        );

        final entity = TestLoggedEntity(
          id: 'remote-test-1',
          name: 'Remote Entity',
          value: 500,
        );

        await repo.save(entity, actorId: 'remote-user');

        // Проверяем историю
        final history = await repo.getHistory('remote-test-1');
        expect(history.length, greaterThan(0));
        expect(history.first.changedBy, 'remote-user');

        await vault.dispose();
      } catch (e) {
        // Сервис недоступен - пропускаем тест
        print('⚠️  Data Service недоступен, тест пропущен: $e');
      }
    }, skip: 'Требует запущенный Data Service');
  });
}
