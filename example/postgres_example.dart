// example/postgres_example.dart
/// Пример использования PostgresVaultStorage с реальной PostgreSQL базой данных.
///
/// Требования:
/// - PostgreSQL 14+ установлен и запущен
/// - База данных 'dart_vault_example' создана
/// - Пользователь 'postgres' с паролем 'postgres'
///
/// Создание базы:
/// ```sql
/// CREATE DATABASE dart_vault_example;
/// ```
library;

import 'package:postgres/postgres.dart';
import 'package:dart_vault/server.dart';
import 'package:aq_schema/aq_schema.dart';

// ── Пример домена: User ──────────────────────────────────────────────────

class User implements DirectStorable {
  @override
  final String id;
  final String tenantId;
  final String name;
  final String email;
  final int age;

  User({
    required this.id,
    required this.tenantId,
    required this.name,
    required this.email,
    required this.age,
  });

  @override
  String get collectionName => kCollection;

  @override
  Map<String, dynamic> get indexFields => {
        'name': name,
        'email': email,
        'age': age,
      };

  @override
  Map<String, dynamic> get jsonSchema => kJsonSchema;

  @override
  Map<String, dynamic> toMap() => {
        'id': id,
        'tenantId': tenantId,
        'name': name,
        'email': email,
        'age': age,
      };

  factory User.fromMap(Map<String, dynamic> map) => User(
        id: map['id'] as String,
        tenantId: map['tenantId'] as String,
        name: map['name'] as String,
        email: map['email'] as String,
        age: map['age'] as int,
      );

  static const kCollection = 'users';
  static const kJsonSchema = {
    'type': 'object',
    'properties': {
      'id': {'type': 'string'},
      'tenantId': {'type': 'string'},
      'name': {'type': 'string'},
      'email': {'type': 'string', 'format': 'email'},
      'age': {'type': 'integer'},
    },
    'required': ['id', 'tenantId', 'name', 'email', 'age'],
  };

  @override
  // TODO: implement softDelete
  bool get softDelete => true;
}

// ── Main ──────────────────────────────────────────────────────────────────

void main() async {
  print('🚀 PostgreSQL Vault Example\n');

  // 1. Подключение к PostgreSQL
  print('📡 Подключение к PostgreSQL...');
  final pool = Pool<Connection>.withEndpoints(
    [
      Endpoint(
        host: 'localhost',
        database: 'dart_vault_example',
        username: 'postgres',
        password: 'postgres',
      ),
    ],
    settings: PoolSettings(
      maxConnectionCount: 10,
      sslMode: SslMode.disable,
    ),
  );
  print('✅ Подключено\n');

  try {
    // 2. Создание VaultRegistry
    print('📦 Создание VaultRegistry...');
    final registry = VaultRegistry(
      storageFactory: (tenantId) => PostgresVaultStorage(
        pool: pool,
        tenantId: tenantId,
      ),
      deployer: PostgresSchemaDeployer(pool: pool),
    );

    // 3. Регистрация домена User
    print('📝 Регистрация домена User...');
    registry.register(DomainRegistration(
      collection: User.kCollection,
      mode: StorageMode.direct,
      fromMap: User.fromMap,
      jsonSchema: User.kJsonSchema,
      indexes: [
        VaultIndex(name: 'idx_users_email', field: 'email'),
        VaultIndex(name: 'idx_users_age', field: 'age'),
      ],
    ));

    // 4. Deploy схемы (создание таблиц)
    print('🔨 Создание таблиц из JSON Schema...');
    await registry.deploy();
    print('✅ Таблицы созданы\n');

    // 5. Создание Vault с PostgreSQL storage
    print('🏢 Работа с tenant: company-123\n');
    final vault = Vault(
      storage: PostgresVaultStorage(
        pool: pool,
        tenantId: 'company-123',
      ),
      tenantId: 'company-123',
    );

    final userRepo = vault.direct<User>(
      collection: User.kCollection,
      fromMap: User.fromMap,
    );

    // 6. Создание пользователей
    print('➕ Создание пользователей...');
    await userRepo.save(User(
      id: 'user-1',
      tenantId: 'company-123',
      name: 'Иван Иванов',
      email: 'ivan@example.com',
      age: 30,
    ));

    await userRepo.save(User(
      id: 'user-2',
      tenantId: 'company-123',
      name: 'Мария Петрова',
      email: 'maria@example.com',
      age: 25,
    ));

    await userRepo.save(User(
      id: 'user-3',
      tenantId: 'company-123',
      name: 'Пётр Сидоров',
      email: 'petr@example.com',
      age: 35,
    ));
    print('✅ Создано 3 пользователя\n');

    // 7. Получение пользователя по ID
    print('🔍 Получение пользователя user-1...');
    final user1 = await userRepo.findById('user-1');
    print('   Найден: ${user1?.name} (${user1?.email})\n');

    // 8. Запрос всех пользователей
    print('📋 Все пользователи:');
    final allUsers = await userRepo.findAll();
    for (final user in allUsers) {
      print('   - ${user.name}, ${user.age} лет (${user.email})');
    }
    print('');

    // 9. Запрос с фильтром (возраст > 28) - используем storage напрямую
    print('🔎 Пользователи старше 28 лет:');
    final storage = vault.storage;
    final olderUsersData = await storage.query(
      User.kCollection,
      VaultQuery(
        filters: [
          VaultFilter('age', VaultOperator.greaterThan, 28),
        ],
        sort: VaultSort(field: 'age', descending: false),
      ),
    );
    for (final data in olderUsersData) {
      final user = User.fromMap(data);
      print('   - ${user.name}, ${user.age} лет');
    }
    print('');

    // 10. Запрос с пагинацией
    print('📄 Первые 2 пользователя (пагинация):');
    final page = await storage.queryPage(
      User.kCollection,
      VaultQuery(
        limit: 2,
        offset: 0,
        sort: VaultSort(field: 'name', descending: false),
      ),
    );
    print('   Всего: ${page.total}, показано: ${page.items.length}');
    for (final data in page.items) {
      final user = User.fromMap(data);
      print('   - ${user.name}');
    }
    print('');

    // 11. Обновление пользователя
    print('✏️  Обновление возраста user-2...');
    final user2 = await userRepo.findById('user-2');
    if (user2 != null) {
      await userRepo.save(User(
        id: user2.id,
        tenantId: user2.tenantId,
        name: user2.name,
        email: user2.email,
        age: 26, // Было 25
      ));
      print('   ✅ Возраст обновлён: 25 → 26\n');
    }

    // 12. Подсчёт пользователей
    print('🔢 Количество пользователей:');
    final count = await userRepo.count();
    print('   Всего: $count\n');

    // 13. Удаление пользователя
    print('🗑️  Удаление user-3...');
    await userRepo.delete('user-3');
    final countAfterDelete = await userRepo.count();
    print('   ✅ Удалён. Осталось: $countAfterDelete\n');

    // 14. Multi-tenancy: другой tenant
    print('🏢 Работа с другим tenant: company-456\n');
    final vault2 = Vault(
      storage: PostgresVaultStorage(
        pool: pool,
        tenantId: 'company-456',
      ),
      tenantId: 'company-456',
    );

    final userRepo2 = vault2.direct<User>(
      collection: User.kCollection,
      fromMap: User.fromMap,
    );

    await userRepo2.save(User(
      id: 'user-10',
      tenantId: 'company-456',
      name: 'Анна Смирнова',
      email: 'anna@example.com',
      age: 28,
    ));

    final tenant1Count = await userRepo.count();
    final tenant2Count = await userRepo2.count();
    print('   Tenant company-123: $tenant1Count пользователей');
    print('   Tenant company-456: $tenant2Count пользователей');
    print('   ✅ Изоляция тенантов работает!\n');

    print('🎉 Пример завершён успешно!');
  } finally {
    // Закрытие соединения
    await pool.close();
    print('\n👋 Соединение закрыто');
  }
}
