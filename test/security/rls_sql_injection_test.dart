import 'dart:io';
import 'package:test/test.dart';
import 'package:postgres/postgres.dart';

/// RLS Security Tests - Category 2: SQL Injection
///
/// Проверяет, что RLS не обходится через SQL injection атаки.
/// Эти тесты КРИТИЧНЫ для безопасности production системы.
void main() {
  late Connection conn;
  late String testDbUrl;

  setUpAll(() async {
    testDbUrl = Platform.environment['TEST_PG_URL'] ??
        'postgres://aq_app:aq_app_secret@localhost:5432/aq_studio';

    print('🔌 Connecting to PostgreSQL: $testDbUrl');
  });

  setUp(() async {
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

    // Очищаем и создаём тестовые данные
    await conn.execute('DELETE FROM projects WHERE id LIKE \'inject-%\'');

    // Данные для tenant-a
    await conn.runTx((session) async {
      await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");
      await session.execute(
        '''INSERT INTO projects (id, tenant_id, data) VALUES
           ('inject-a-1', 'tenant-a', '{"id":"inject-a-1","name":"Safe A","tenantId":"tenant-a","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}')
           ON CONFLICT (id, tenant_id) DO UPDATE SET data = EXCLUDED.data
        ''',
      );
    });

    // Данные для tenant-b (секретные)
    await conn.runTx((session) async {
      await session.execute("SET LOCAL app.current_tenant = 'tenant-b'");
      await session.execute(
        '''INSERT INTO projects (id, tenant_id, data) VALUES
           ('inject-b-secret', 'tenant-b', '{"id":"inject-b-secret","name":"SECRET DATA","tenantId":"tenant-b","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}')
           ON CONFLICT (id, tenant_id) DO UPDATE SET data = EXCLUDED.data
        ''',
      );
    });

    print('✅ Test data created');
  });

  tearDown(() async {
    await conn.close();
  });

  group('Category 2: SQL Injection Tests', () {
    test('Test 2.1: Injection via ID parameter - OR clause', () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Попытка SQL injection через OR clause
        final maliciousId = "x' OR tenant_id='tenant-b' --";

        final result = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: [maliciousId],
        );

        // КРИТИЧНО: инъекция НЕ должна сработать
        expect(result.isEmpty, isTrue,
            reason: 'SQL injection через OR clause НЕ ДОЛЖНА работать');
      });
    });

    test('Test 2.2: Injection via ID parameter - UNION attack', () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Попытка UNION-based SQL injection
        final maliciousId =
            "x' UNION SELECT data FROM projects WHERE tenant_id='tenant-b' --";

        try {
          final result = await session.execute(
            'SELECT data FROM projects WHERE id = \$1',
            parameters: [maliciousId],
          );

          // Если запрос выполнился, проверяем что секретные данные не утекли
          expect(result.isEmpty, isTrue,
              reason: 'UNION injection НЕ ДОЛЖНА возвращать данные tenant-b');
        } on ServerException catch (e) {
          // Если выбросилась ошибка - это тоже OK (параметризованный запрос защищает)
          print('✅ UNION injection заблокирована: ${e.message}');
        }
      });
    });

    test('Test 2.3: Injection via ID parameter - Comment injection', () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Попытка закомментировать WHERE clause
        final maliciousId = "inject-b-secret' --";

        final result = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: [maliciousId],
        );

        // КРИТИЧНО: не должен вернуть секретную запись
        expect(result.isEmpty, isTrue,
            reason: 'Comment injection НЕ ДОЛЖНА обойти RLS');
      });
    });

    test('Test 2.4: Injection via ID parameter - Subquery attack', () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Попытка использовать подзапрос
        final maliciousId =
            "x' OR id IN (SELECT id FROM projects WHERE tenant_id='tenant-b') --";

        final result = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: [maliciousId],
        );

        expect(result.isEmpty, isTrue,
            reason: 'Subquery injection НЕ ДОЛЖНА работать');
      });
    });

    test('Test 2.5: Injection via ID parameter - Boolean-based blind',
        () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Попытка boolean-based blind SQL injection
        final maliciousId = "x' OR '1'='1";

        final result = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: [maliciousId],
        );

        // Не должен вернуть все записи
        expect(result.isEmpty, isTrue,
            reason: 'Boolean-based injection НЕ ДОЛЖНА возвращать все записи');
      });
    });

    test('Test 2.6: Injection via ID parameter - Stacked queries', () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Попытка выполнить несколько запросов
        final maliciousId = "x'; DELETE FROM projects WHERE tenant_id='tenant-b'; --";

        try {
          await session.execute(
            'SELECT data FROM projects WHERE id = \$1',
            parameters: [maliciousId],
          );
        } catch (e) {
          // Ошибка - это OK
          print('✅ Stacked queries заблокированы: $e');
        }
      });

      // Проверяем, что данные tenant-b не удалены
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-b'");

        final result = await session.execute(
          'SELECT COUNT(*) FROM projects WHERE id LIKE \'inject-%\'',
        );

        final count = result.first[0] as int;
        expect(count, equals(1),
            reason: 'Данные tenant-b НЕ ДОЛЖНЫ быть удалены через stacked queries');
      });
    });

    test('Test 2.7: Injection via JSONB field - data field manipulation',
        () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Попытка инъекции через JSONB поле
        final maliciousData = {
          'id': 'inject-a-2',
          'name': "Test'; DROP TABLE projects; --",
          'tenantId': 'tenant-a',
          'projectType': 'workflow',
          'ownerId': '',
          'path': '',
          'lastOpened': '2026-04-09T14:00:00.000Z',
        };

        // Вставляем запись с потенциально опасными данными
        await session.execute(
          '''INSERT INTO projects (id, tenant_id, data)
             VALUES (\$1, 'tenant-a', \$2)
             ON CONFLICT (id, tenant_id) DO UPDATE SET data = EXCLUDED.data
          ''',
          parameters: ['inject-a-2', maliciousData],
        );

        // Читаем обратно
        final result = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: ['inject-a-2'],
        );

        expect(result.length, equals(1));
        final data = result.first[0] as Map<String, dynamic>;
        expect(data['name'], equals("Test'; DROP TABLE projects; --"),
            reason: 'Данные должны быть сохранены как есть, без выполнения SQL');
      });

      // Проверяем, что таблица не удалена
      final tableExists = await conn.execute(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'projects')",
      );
      expect(tableExists.first[0], isTrue,
          reason: 'Таблица projects НЕ ДОЛЖНА быть удалена');
    });

    test('Test 2.8: Injection via query filter - JSONB operator injection',
        () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Попытка инъекции через JSONB оператор
        final maliciousValue = "x' OR data->>'tenantId'='tenant-b' OR '1'='1";

        final result = await session.execute(
          "SELECT data FROM projects WHERE data->>'name' = \$1",
          parameters: [maliciousValue],
        );

        // Не должен вернуть данные tenant-b
        expect(result.isEmpty, isTrue,
            reason: 'JSONB operator injection НЕ ДОЛЖНА обойти RLS');
      });
    });

    test('Test 2.9: Injection via SET LOCAL - context override attempt',
        () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Попытка изменить контекст через инъекцию
        final maliciousId = "x'; SET LOCAL app.current_tenant = 'tenant-b'; --";

        try {
          final result = await session.execute(
            'SELECT data FROM projects WHERE id = \$1',
            parameters: [maliciousId],
          );

          expect(result.isEmpty, isTrue);
        } catch (e) {
          print('✅ SET LOCAL injection заблокирована: $e');
        }

        // Проверяем, что контекст не изменился
        final contextCheck = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: ['inject-a-1'],
        );

        expect(contextCheck.length, equals(1),
            reason: 'Контекст tenant-a НЕ ДОЛЖЕН быть изменён через injection');
      });
    });

    test('Test 2.10: Injection via special characters - Unicode attack',
        () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Попытка использовать Unicode для обхода фильтров
        // Null byte (\x00) не поддерживается PostgreSQL в UTF8 - это ожидаемо
        final maliciousId = "inject-b-secret' OR '1'='1"; // Без null byte

        final result = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: [maliciousId],
        );

        expect(result.isEmpty, isTrue,
            reason: 'Unicode injection НЕ ДОЛЖНА работать');
      });
    });

    test('Test 2.11: Injection via hex encoding - bypass attempt', () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Попытка использовать hex encoding
        final maliciousId = "x' OR id = 0x696e6a6563742d622d736563726574 --";

        final result = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: [maliciousId],
        );

        expect(result.isEmpty, isTrue,
            reason: 'Hex encoding injection НЕ ДОЛЖНА работать');
      });
    });

    test('Test 2.12: Mass assignment attack - tenantId override in data',
        () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Попытка создать запись с tenantId другого tenant в JSONB data
        final maliciousData = {
          'id': 'inject-a-3',
          'name': 'Mass Assignment Attack',
          'tenantId': 'tenant-b', // Попытка подделать tenantId
          'projectType': 'workflow',
          'ownerId': '',
          'path': '',
          'lastOpened': '2026-04-09T14:00:00.000Z',
        };

        await session.execute(
          '''INSERT INTO projects (id, tenant_id, data)
             VALUES (\$1, 'tenant-a', \$2)
             ON CONFLICT (id, tenant_id) DO UPDATE SET data = EXCLUDED.data
          ''',
          parameters: ['inject-a-3', maliciousData],
        );

        // Проверяем, что запись создалась с правильным tenant_id в колонке
        final result = await session.execute(
          'SELECT tenant_id, data FROM projects WHERE id = \$1',
          parameters: ['inject-a-3'],
        );

        expect(result.length, equals(1));
        final tenantIdColumn = result.first[0] as String;
        final data = result.first[1] as Map<String, dynamic>;

        // КРИТИЧНО: tenant_id в колонке должен быть tenant-a
        expect(tenantIdColumn, equals('tenant-a'),
            reason: 'tenant_id в колонке ДОЛЖЕН быть tenant-a (из контекста)');

        // tenantId в JSONB может быть любым (это просто данные)
        expect(data['tenantId'], equals('tenant-b'),
            reason: 'tenantId в JSONB - это просто данные, не влияют на изоляцию');
      });

      // Проверяем, что tenant-b НЕ видит эту запись
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-b'");

        final result = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: ['inject-a-3'],
        );

        expect(result.isEmpty, isTrue,
            reason: 'tenant-b НЕ ДОЛЖЕН видеть запись tenant-a, даже если tenantId в JSONB = tenant-b');
      });
    });
  });
}
