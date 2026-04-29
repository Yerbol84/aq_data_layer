// test/integration/postgres_integration_test.dart
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:postgres/postgres.dart';
import 'package:dart_vault/server.dart';
import 'package:aq_schema/aq_schema.dart';

// ── Test Domain ───────────────────────────────────────────────────────────

class TestEntity implements DirectStorable {
  @override
  final String id;
  final String tenantId;
  final String name;
  final int value;

  TestEntity({
    required this.id,
    required this.tenantId,
    required this.name,
    required this.value,
  });

  @override
  String get collectionName => kCollection;

  @override
  Map<String, dynamic> get indexFields => {
        'name': name,
        'value': value,
      };

  @override
  Map<String, dynamic> get jsonSchema => kJsonSchema;

  @override
  Map<String, dynamic> toMap() => {
        'id': id,
        'tenantId': tenantId,
        'name': name,
        'value': value,
      };

  factory TestEntity.fromMap(Map<String, dynamic> map) => TestEntity(
        id: map['id'] as String,
        tenantId: map['tenantId'] as String,
        name: map['name'] as String,
        value: map['value'] as int,
      );

  static const kCollection = 'test_entities';
  static const kJsonSchema = {
    'type': 'object',
    'properties': {
      'id': {'type': 'string'},
      'tenantId': {'type': 'string'},
      'name': {'type': 'string'},
      'value': {'type': 'integer'},
    },
    'required': ['id', 'tenantId', 'name', 'value'],
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────

void main() {
  Pool? connection;
  VaultRegistry? registry;
  Vault? vault;
  DirectRepository<TestEntity>? repo;

  setUpAll(() async {
    // Подключение к тестовой базе
    connection = Pool<Connection>.withEndpoints(
      [
        Endpoint(
          host: 'localhost',
          database: 'dart_vault_test',
          username: 'postgres',
          password: 'postgres',
        ),
      ],
      settings: PoolSettings(
        maxConnectionCount: 10,
        sslMode: SslMode.disable,
      ),
    );

    // Создание registry
    registry = VaultRegistry(
      storageFactory: (tenantId) => PostgresVaultStorage(
        pool: connection!,
        tenantId: tenantId,
      ),
      deployer: PostgresSchemaDeployer(pool: connection!),
    );

    // Регистрация домена
    registry!.register(DomainRegistration(
      collection: TestEntity.kCollection,
      mode: StorageMode.direct,
      fromMap: TestEntity.fromMap,
      jsonSchema: TestEntity.kJsonSchema,
      indexes: [
        VaultIndex(name: 'idx_test_name', field: 'name'),
        VaultIndex(name: 'idx_test_value', field: 'value'),
      ],
    ));

    // Deploy схемы
    await registry!.deploy();

    // Создание Vault и репозитория
    vault = Vault(
      storage: PostgresVaultStorage(
        pool: connection!,
        tenantId: 'test-tenant',
      ),
      tenantId: 'test-tenant',
    );

    repo = vault!.direct<TestEntity>(
      collection: TestEntity.kCollection,
      fromMap: TestEntity.fromMap,
    );
  });

  tearDownAll(() async {
    // Сначала закрываем Vault (освобождает соединения из pool)
    if (vault != null) {
      await vault!.dispose();
    }

    // Потом очищаем таблицы и закрываем pool
    if (connection != null) {
      try {
        await connection!.execute('DROP TABLE IF EXISTS ${TestEntity.kCollection}');
        await connection!.execute('DROP TABLE IF EXISTS _vault_migrations');
      } catch (e) {
        // Игнорируем ошибки при cleanup
      }
      await connection!.close();
    }
  });

  setUp(() async {
    // Очистка данных перед каждым тестом
    if (connection != null) {
      await connection!.execute(
        'DELETE FROM ${TestEntity.kCollection} WHERE tenant_id = @tenant',
        parameters: {'tenant': 'test-tenant'},
      );
    }
  });

  group('PostgresVaultStorage CRUD', () {
    test('save and findById', () async {
      final entity = TestEntity(
        id: 'test-1',
        tenantId: 'test-tenant',
        name: 'Test Entity',
        value: 42,
      );

      await repo!.save(entity);

      final found = await repo!.findById('test-1');
      expect(found, isNotNull);
      expect(found!.id, equals('test-1'));
      expect(found.name, equals('Test Entity'));
      expect(found.value, equals(42));
    });

    test('save updates existing entity', () async {
      final entity1 = TestEntity(
        id: 'test-1',
        tenantId: 'test-tenant',
        name: 'Original',
        value: 10,
      );
      await repo!.save(entity1);

      final entity2 = TestEntity(
        id: 'test-1',
        tenantId: 'test-tenant',
        name: 'Updated',
        value: 20,
      );
      await repo!.save(entity2);

      final found = await repo!.findById('test-1');
      expect(found!.name, equals('Updated'));
      expect(found.value, equals(20));
    });

    test('delete removes entity', () async {
      final entity = TestEntity(
        id: 'test-1',
        tenantId: 'test-tenant',
        name: 'To Delete',
        value: 100,
      );
      await repo!.save(entity);

      await repo!.delete('test-1');

      final found = await repo!.findById('test-1');
      expect(found, isNull);
    });

    test('exists returns true for existing entity', () async {
      final entity = TestEntity(
        id: 'test-1',
        tenantId: 'test-tenant',
        name: 'Exists',
        value: 1,
      );
      await repo!.save(entity);

      final exists = await repo!.exists('test-1');
      expect(exists, isTrue);
    });

    test('exists returns false for non-existing entity', () async {
      final exists = await repo!.exists('non-existing');
      expect(exists, isFalse);
    });
  });

  group('PostgresVaultStorage Query', () {
    setUp(() async {
      // Создание тестовых данных
      await repo!.save(TestEntity(
        id: 'e1',
        tenantId: 'test-tenant',
        name: 'Alpha',
        value: 10,
      ));
      await repo!.save(TestEntity(
        id: 'e2',
        tenantId: 'test-tenant',
        name: 'Beta',
        value: 20,
      ));
      await repo!.save(TestEntity(
        id: 'e3',
        tenantId: 'test-tenant',
        name: 'Gamma',
        value: 30,
      ));
    });

    test('findAll returns all entities', () async {
      final all = await repo!.findAll();
      expect(all.length, equals(3));
    });

    test('query with equals filter', () async {
      final storage = vault!.storage;
      final results = await storage.query(
        TestEntity.kCollection,
        VaultQuery(
          filters: [VaultFilter('name', VaultOperator.equals, 'Beta')],
        ),
      );

      expect(results.length, equals(1));
      final entity = TestEntity.fromMap(results.first);
      expect(entity.name, equals('Beta'));
    });

    test('query with greaterThan filter', () async {
      final storage = vault!.storage;
      final results = await storage.query(
        TestEntity.kCollection,
        VaultQuery(
          filters: [VaultFilter('value', VaultOperator.greaterThan, 15)],
        ),
      );

      expect(results.length, equals(2));
      for (final data in results) {
        final entity = TestEntity.fromMap(data);
        expect(entity.value, greaterThan(15));
      }
    });

    test('query with sorting', () async {
      final storage = vault!.storage;
      final results = await storage.query(
        TestEntity.kCollection,
        VaultQuery(
          sort: VaultSort(field: 'value', descending: true),
        ),
      );

      expect(results.length, equals(3));
      final entities = results.map(TestEntity.fromMap).toList();
      expect(entities[0].value, equals(30));
      expect(entities[1].value, equals(20));
      expect(entities[2].value, equals(10));
    });

    test('query with limit', () async {
      final storage = vault!.storage;
      final results = await storage.query(
        TestEntity.kCollection,
        VaultQuery(
          limit: 2,
          sort: VaultSort(field: 'name'),
        ),
      );

      expect(results.length, equals(2));
      final entities = results.map(TestEntity.fromMap).toList();
      expect(entities[0].name, equals('Alpha'));
      expect(entities[1].name, equals('Beta'));
    });

    test('query with offset', () async {
      final storage = vault!.storage;
      final results = await storage.query(
        TestEntity.kCollection,
        VaultQuery(
          offset: 1,
          sort: VaultSort(field: 'name'),
        ),
      );

      expect(results.length, equals(2));
      final entities = results.map(TestEntity.fromMap).toList();
      expect(entities[0].name, equals('Beta'));
      expect(entities[1].name, equals('Gamma'));
    });

    test('queryPage returns correct pagination', () async {
      final storage = vault!.storage;
      final page = await storage.queryPage(
        TestEntity.kCollection,
        VaultQuery(
          limit: 2,
          offset: 0,
          sort: VaultSort(field: 'name'),
        ),
      );

      expect(page.total, equals(3));
      expect(page.items.length, equals(2));
      expect(page.offset, equals(0));
      expect(page.limit, equals(2));
    });

    test('count returns correct number', () async {
      final count = await repo!.count();
      expect(count, equals(3));
    });

    test('count with filter', () async {
      final storage = vault!.storage;
      final count = await storage.count(
        TestEntity.kCollection,
        VaultQuery(
          filters: [VaultFilter('value', VaultOperator.greaterOrEqual, 20)],
        ),
      );
      expect(count, equals(2));
    });
  });

  group('PostgresVaultStorage Multi-tenancy', () {
    late Vault vault2;
    late DirectRepository<TestEntity> repo2;

    setUp(() async {
      vault2 = Vault(
        storage: PostgresVaultStorage(
          pool: connection!,
          tenantId: 'tenant-2',
        ),
        tenantId: 'tenant-2',
      );

      repo2 = vault2.direct<TestEntity>(
        collection: TestEntity.kCollection,
        fromMap: TestEntity.fromMap,
      );

      // Данные для tenant-1
      await repo!.save(TestEntity(
        id: 'e1',
        tenantId: 'test-tenant',
        name: 'Tenant 1 Entity',
        value: 100,
      ));

      // Данные для tenant-2
      await repo2.save(TestEntity(
        id: 'e1',
        tenantId: 'tenant-2',
        name: 'Tenant 2 Entity',
        value: 200,
      ));
    });

    tearDown(() async {
      await connection!.execute(
        'DELETE FROM ${TestEntity.kCollection} WHERE tenant_id = @tenant',
        parameters: {'tenant': 'tenant-2'},
      );
    });

    test('tenants are isolated', () async {
      final tenant1Data = await repo!.findAll();
      final tenant2Data = await repo2.findAll();

      expect(tenant1Data.length, equals(1));
      expect(tenant2Data.length, equals(1));
      expect(tenant1Data.first.value, equals(100));
      expect(tenant2Data.first.value, equals(200));
    });

    test('same ID in different tenants', () async {
      final entity1 = await repo!.findById('e1');
      final entity2 = await repo2.findById('e1');

      expect(entity1, isNotNull);
      expect(entity2, isNotNull);
      expect(entity1!.name, equals('Tenant 1 Entity'));
      expect(entity2!.name, equals('Tenant 2 Entity'));
    });

    test('delete in one tenant does not affect another', () async {
      await repo!.delete('e1');

      final entity1 = await repo!.findById('e1');
      final entity2 = await repo2.findById('e1');

      expect(entity1, isNull);
      expect(entity2, isNotNull);
    });
  });

  group('PostgresVaultStorage Batch Operations', () {
    test('putAll saves multiple entities', () async {
      final storage = vault!.storage;

      await storage.putAll(TestEntity.kCollection, {
        'b1': {'id': 'b1', 'tenantId': 'test-tenant', 'name': 'Batch 1', 'value': 1},
        'b2': {'id': 'b2', 'tenantId': 'test-tenant', 'name': 'Batch 2', 'value': 2},
        'b3': {'id': 'b3', 'tenantId': 'test-tenant', 'name': 'Batch 3', 'value': 3},
      });

      final count = await repo!.count();
      expect(count, equals(3));
    });
  });
}
