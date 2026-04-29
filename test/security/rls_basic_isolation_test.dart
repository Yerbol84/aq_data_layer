import 'dart:io';
import 'package:test/test.dart';
import 'package:postgres/postgres.dart';

/// RLS Security Tests - Category 1: Basic Isolation
///
/// Проверяет базовую tenant-изоляцию на уровне PostgreSQL RLS.
/// Эти тесты КРИТИЧНЫ - если хотя бы один падает, система небезопасна.
void main() {
  late Connection conn;
  late String testDbUrl;

  setUpAll(() async {
    // Читаем connection string из окружения или используем дефолтный
    testDbUrl = Platform.environment['TEST_PG_URL'] ??
        'postgres://aq_app:aq_app_secret@localhost:5432/aq_studio';

    print('🔌 Connecting to PostgreSQL: $testDbUrl');
  });

  setUp(() async {
    // Создаём новое подключение для каждого теста
    final uri = Uri.parse(testDbUrl);
    conn = await Connection.open(
      Endpoint(
        host: uri.host,
        port: uri.port,
        database: uri.pathSegments.first,
        username: uri.userInfo.split(':')[0],
        password: uri.userInfo.split(':')[1],
      ),
      settings: ConnectionSettings(sslMode: SslMode.disable),
    );

    // Очищаем тестовые данные
    await conn.execute('DELETE FROM projects WHERE id LIKE \'test-%\'');

    // Создаём тестовые данные для tenant-a
    await conn.runTx((session) async {
      await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");
      await session.execute(
        '''INSERT INTO projects (id, tenant_id, data) VALUES
           ('test-a-1', 'tenant-a', '{"id":"test-a-1","name":"Project A1","tenantId":"tenant-a","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}'),
           ('test-a-2', 'tenant-a', '{"id":"test-a-2","name":"Project A2","tenantId":"tenant-a","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}'),
           ('test-shared-id', 'tenant-a', '{"id":"test-shared-id","name":"Tenant A Shared","tenantId":"tenant-a","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}')
           ON CONFLICT (id, tenant_id) DO UPDATE SET data = EXCLUDED.data
        ''',
      );
    });

    // Создаём тестовые данные для tenant-b
    await conn.runTx((session) async {
      await session.execute("SET LOCAL app.current_tenant = 'tenant-b'");
      await session.execute(
        '''INSERT INTO projects (id, tenant_id, data) VALUES
           ('test-b-1', 'tenant-b', '{"id":"test-b-1","name":"Project B1","tenantId":"tenant-b","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}'),
           ('test-b-2', 'tenant-b', '{"id":"test-b-2","name":"Project B2","tenantId":"tenant-b","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}'),
           ('test-shared-id', 'tenant-b', '{"id":"test-shared-id","name":"Tenant B Shared","tenantId":"tenant-b","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}')
           ON CONFLICT (id, tenant_id) DO UPDATE SET data = EXCLUDED.data
        ''',
      );
    });

    print('✅ Test data created');
  });

  tearDown(() async {
    await conn.close();
  });

  group('Category 1: Basic Isolation Tests', () {
    test('Test 1.1: Read Isolation - tenant-a cannot read tenant-b records',
        () async {
      await conn.runTx((session) async {
        // Устанавливаем контекст tenant-a
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Пытаемся прочитать запись tenant-b
        final result = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: ['test-b-1'],
        );

        // КРИТИЧНО: должен вернуть пустой результат
        expect(result.isEmpty, isTrue,
            reason: 'tenant-a НЕ ДОЛЖЕН видеть записи tenant-b');
      });
    });

    test('Test 1.2: Write Isolation - tenant-a can create record with same ID as tenant-b',
        () async {
      await conn.runTx((session) async {
        // Устанавливаем контекст tenant-a
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Создаём запись с ID, который уже существует у tenant-b
        await session.execute(
          '''INSERT INTO projects (id, tenant_id, data) VALUES
             ('test-b-1', 'tenant-a', '{"id":"test-b-1","name":"Tenant A Hijack Attempt","tenantId":"tenant-a","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}')
          ''',
        );

        // Проверяем, что создалась новая запись для tenant-a
        final resultA = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: ['test-b-1'],
        );

        expect(resultA.length, equals(1));
        final dataA = resultA.first[0] as Map<String, dynamic>;
        expect(dataA['name'], equals('Tenant A Hijack Attempt'));
      });

      // Проверяем, что запись tenant-b не изменилась
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-b'");

        final resultB = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: ['test-b-1'],
        );

        expect(resultB.length, equals(1));
        final dataB = resultB.first[0] as Map<String, dynamic>;
        expect(dataB['name'], equals('Project B1'),
            reason: 'Запись tenant-b НЕ ДОЛЖНА быть изменена');
      });
    });

    test('Test 1.3: Delete Isolation - tenant-a cannot delete tenant-b records',
        () async {
      await conn.runTx((session) async {
        // Устанавливаем контекст tenant-a
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Пытаемся удалить запись tenant-b
        await session.execute(
          'DELETE FROM projects WHERE id = \$1',
          parameters: ['test-b-1'],
        );

        // Операция должна завершиться успешно (не выбросить ошибку)
        // но ничего не удалить
      });

      // Проверяем, что запись tenant-b всё ещё существует
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-b'");

        final result = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: ['test-b-1'],
        );

        expect(result.length, equals(1),
            reason: 'Запись tenant-b НЕ ДОЛЖНА быть удалена');
      });
    });

    test('Test 1.4: Query Isolation - tenant-a sees only own records',
        () async {
      await conn.runTx((session) async {
        // Устанавливаем контекст tenant-a
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Запрашиваем ВСЕ записи без фильтров
        final result = await session.execute(
          'SELECT id, data FROM projects WHERE id LIKE \'test-%\' ORDER BY id',
        );

        // КРИТИЧНО: должны вернуться только записи tenant-a
        expect(result.length, equals(3),
            reason: 'tenant-a должен видеть ровно 3 свои записи');

        final ids = result.map((row) => row[0] as String).toList();
        expect(ids, containsAll(['test-a-1', 'test-a-2', 'test-shared-id']));
        expect(ids, isNot(contains('test-b-1')));
        expect(ids, isNot(contains('test-b-2')));
      });
    });

    test('Test 1.5: Count Isolation - tenant-a count excludes tenant-b records',
        () async {
      await conn.runTx((session) async {
        // Устанавливаем контекст tenant-a
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Считаем записи
        final result = await session.execute(
          'SELECT COUNT(*) FROM projects WHERE id LIKE \'test-%\'',
        );

        final count = result.first[0] as int;
        expect(count, equals(3),
            reason: 'tenant-a должен видеть ровно 3 свои записи');
      });

      // Проверяем count для tenant-b
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-b'");

        final result = await session.execute(
          'SELECT COUNT(*) FROM projects WHERE id LIKE \'test-%\'',
        );

        final count = result.first[0] as int;
        expect(count, equals(3),
            reason: 'tenant-b должен видеть ровно 3 свои записи');
      });
    });

    test('Test 1.6: Shared ID Isolation - same ID for different tenants',
        () async {
      // tenant-a читает запись с shared ID
      String? nameA;
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        final result = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: ['test-shared-id'],
        );

        expect(result.length, equals(1));
        final data = result.first[0] as Map<String, dynamic>;
        nameA = data['name'] as String;
      });

      // tenant-b читает запись с тем же ID
      String? nameB;
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-b'");

        final result = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: ['test-shared-id'],
        );

        expect(result.length, equals(1));
        final data = result.first[0] as Map<String, dynamic>;
        nameB = data['name'] as String;
      });

      // КРИТИЧНО: должны быть разные записи
      expect(nameA, equals('Tenant A Shared'));
      expect(nameB, equals('Tenant B Shared'));
      expect(nameA, isNot(equals(nameB)),
          reason: 'Записи с одинаковым ID должны быть разными для разных tenants');
    });

    test('Test 1.7: Update Isolation - tenant-a cannot update tenant-b records',
        () async {
      await conn.runTx((session) async {
        // Устанавливаем контекст tenant-a
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Пытаемся обновить запись tenant-b
        await session.execute(
          '''UPDATE projects
             SET data = '{"id":"test-b-1","name":"HACKED","tenantId":"tenant-a","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}'::jsonb
             WHERE id = \$1
          ''',
          parameters: ['test-b-1'],
        );
      });

      // Проверяем, что запись tenant-b не изменилась
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-b'");

        final result = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: ['test-b-1'],
        );

        expect(result.length, equals(1));
        final data = result.first[0] as Map<String, dynamic>;
        expect(data['name'], equals('Project B1'),
            reason: 'Запись tenant-b НЕ ДОЛЖНА быть изменена');
      });
    });
  });
}
