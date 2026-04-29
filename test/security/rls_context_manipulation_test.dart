import 'dart:io';
import 'package:test/test.dart';
import 'package:postgres/postgres.dart';

/// RLS Security Tests - Category 3: Context Manipulation
///
/// Проверяет, что tenant не может манипулировать своим контекстом
/// для получения доступа к данным других tenants.
void main() {
  late Connection conn;
  late String testDbUrl;

  setUpAll(() async {
    testDbUrl = Platform.environment['TEST_PG_URL'] ??
        'postgres://aq_app:aq_app_secret@localhost:5432/aq_studio';
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

    await conn.execute('DELETE FROM projects WHERE id LIKE \'ctx-%\'');

    // Создаём тестовые данные
    await conn.runTx((session) async {
      await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");
      await session.execute(
        '''INSERT INTO projects (id, tenant_id, data) VALUES
           ('ctx-a-1', 'tenant-a', '{"id":"ctx-a-1","name":"Context A","tenantId":"tenant-a","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}')
           ON CONFLICT (id, tenant_id) DO UPDATE SET data = EXCLUDED.data
        ''',
      );
    });

    await conn.runTx((session) async {
      await session.execute("SET LOCAL app.current_tenant = 'tenant-b'");
      await session.execute(
        '''INSERT INTO projects (id, tenant_id, data) VALUES
           ('ctx-b-secret', 'tenant-b', '{"id":"ctx-b-secret","name":"SECRET CONTEXT","tenantId":"tenant-b","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}')
           ON CONFLICT (id, tenant_id) DO UPDATE SET data = EXCLUDED.data
        ''',
      );
    });
  });

  tearDown(() async {
    await conn.close();
  });

  group('Category 3: Context Manipulation Tests', () {
    test('Test 3.1: Cannot override context with second SET LOCAL', () async {
      await conn.runTx((session) async {
        // Устанавливаем контекст tenant-a
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Пытаемся переопределить контекст на tenant-b
        await session.execute("SET LOCAL app.current_tenant = 'tenant-b'");

        // Проверяем, какой контекст активен
        final contextResult = await session.execute(
          "SELECT current_setting('app.current_tenant', true)",
        );
        final currentContext = contextResult.first[0] as String;

        // Контекст будет tenant-b (последний SET LOCAL побеждает)
        expect(currentContext, equals('tenant-b'));

        // НО: RLS политика всё равно должна применяться
        // Проверяем, что видим только данные tenant-b
        final dataResult = await session.execute(
          'SELECT id FROM projects WHERE id LIKE \'ctx-%\' ORDER BY id',
        );

        final ids = dataResult.map((row) => row[0] as String).toList();
        expect(ids, equals(['ctx-b-secret']),
            reason: 'После смены контекста должны видеть только данные нового контекста');
      });
    });

    test('Test 3.2: Context is isolated per transaction', () async {
      // Транзакция 1: tenant-a
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        final result = await session.execute(
          'SELECT id FROM projects WHERE id LIKE \'ctx-%\'',
        );

        expect(result.length, equals(1));
        expect(result.first[0], equals('ctx-a-1'));
      });

      // Транзакция 2: tenant-b (новая транзакция, новый контекст)
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-b'");

        final result = await session.execute(
          'SELECT id FROM projects WHERE id LIKE \'ctx-%\'',
        );

        expect(result.length, equals(1));
        expect(result.first[0], equals('ctx-b-secret'),
            reason: 'Новая транзакция должна иметь свежий контекст');
      });
    });

    test('Test 3.3: RESET does not bypass RLS', () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Пытаемся сбросить контекст
        try {
          await session.execute("RESET app.current_tenant");
        } catch (e) {
          // RESET может не работать для custom параметров - это OK
          print('✅ RESET заблокирован: $e');
        }

        // Проверяем, что всё ещё видим только данные tenant-a
        final result = await session.execute(
          'SELECT id FROM projects WHERE id LIKE \'ctx-%\'',
        );

        // Если контекст сброшен, current_setting вернёт пустую строку
        // и RLS политика не пропустит ни одну запись
        expect(result.length, lessThanOrEqualTo(1),
            reason: 'После RESET либо видим свои данные, либо ничего');

        if (result.isNotEmpty) {
          expect(result.first[0], equals('ctx-a-1'));
        }
      });
    });

    test('Test 3.4: Empty context blocks all access', () async {
      await conn.runTx((session) async {
        // Устанавливаем пустой контекст
        await session.execute("SET LOCAL app.current_tenant = ''");

        // Проверяем, что ничего не видим
        final result = await session.execute(
          'SELECT id FROM projects WHERE id LIKE \'ctx-%\'',
        );

        expect(result.isEmpty, isTrue,
            reason: 'Пустой контекст НЕ ДОЛЖЕН давать доступ к данным');
      });
    });

    test('Test 3.5: Context with special characters is escaped', () async {
      // Создаём tenant с специальными символами
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-special'");
        await session.execute(
          '''INSERT INTO projects (id, tenant_id, data) VALUES
             ('ctx-special-1', 'tenant-special', '{"id":"ctx-special-1","name":"Special","tenantId":"tenant-special","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}')
          ''',
        );
      });

      // Пытаемся использовать контекст с SQL injection
      await conn.runTx((session) async {
        final maliciousContext = "tenant-special' OR '1'='1";
        await session.execute(
          "SET LOCAL app.current_tenant = '\$maliciousContext'",
        );

        final result = await session.execute(
          'SELECT id FROM projects WHERE id LIKE \'ctx-%\'',
        );

        // Не должен вернуть все записи
        expect(result.length, lessThanOrEqualTo(1),
            reason: 'SQL injection через context НЕ ДОЛЖНА работать');
      });
    });

    test('Test 3.6: Context persists throughout transaction', () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Выполняем несколько операций
        for (var i = 0; i < 5; i++) {
          final result = await session.execute(
            'SELECT id FROM projects WHERE id = \$1',
            parameters: ['ctx-a-1'],
          );

          expect(result.length, equals(1),
              reason: 'Контекст должен сохраняться на протяжении всей транзакции');
        }
      });
    });

    test('Test 3.7: Cannot access data without setting context', () async {
      await conn.runTx((session) async {
        // НЕ устанавливаем контекст

        // Пытаемся прочитать данные
        final result = await session.execute(
          'SELECT id FROM projects WHERE id LIKE \'ctx-%\'',
        );

        // Без контекста current_setting вернёт пустую строку или NULL
        // RLS политика не пропустит записи
        expect(result.isEmpty, isTrue,
            reason: 'Без установленного контекста НЕ ДОЛЖНО быть доступа к данным');
      });
    });

    test('Test 3.8: Context case sensitivity', () async {
      await conn.runTx((session) async {
        // Устанавливаем контекст с другим регистром
        await session.execute("SET LOCAL app.current_tenant = 'Tenant-A'");

        final result = await session.execute(
          'SELECT id FROM projects WHERE id = \$1',
          parameters: ['ctx-a-1'],
        );

        // tenant_id в БД = 'tenant-a', контекст = 'Tenant-A'
        // Они не совпадают (case-sensitive), запись не должна вернуться
        expect(result.isEmpty, isTrue,
            reason: 'tenant_id должен быть case-sensitive');
      });
    });
  });

  group('Category 4: Transaction Isolation Tests', () {
    test('Test 4.1: Concurrent transactions do not interfere', () async {
      // Создаём два независимых подключения
      final uri = Uri.parse(testDbUrl);
      final conn1 = await Connection.open(
        Endpoint(
          host: uri.host,
          port: uri.port,
          database: uri.pathSegments.first,
          username: uri.userInfo.split(':')[0],
          password: uri.userInfo.split(':')[1],
        ),
        settings: ConnectionSettings(sslMode: SslMode.disable),
      );

      final conn2 = await Connection.open(
        Endpoint(
          host: uri.host,
          port: uri.port,
          database: uri.pathSegments.first,
          username: uri.userInfo.split(':')[0],
          password: uri.userInfo.split(':')[1],
        ),
        settings: ConnectionSettings(sslMode: SslMode.disable),
      );

      try {
        // Запускаем две транзакции параллельно
        final futures = await Future.wait([
          // Транзакция 1: tenant-a
          conn1.runTx((session) async {
            await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");
            await Future<void>.delayed(Duration(milliseconds: 100)); // Имитация работы
            final result = await session.execute(
              'SELECT id FROM projects WHERE id LIKE \'ctx-%\'',
            );
            return result.map((row) => row[0] as String).toList();
          }),

          // Транзакция 2: tenant-b
          conn2.runTx((session) async {
            await session.execute("SET LOCAL app.current_tenant = 'tenant-b'");
            await Future<void>.delayed(Duration(milliseconds: 100)); // Имитация работы
            final result = await session.execute(
              'SELECT id FROM projects WHERE id LIKE \'ctx-%\'',
            );
            return result.map((row) => row[0] as String).toList();
          }),
        ]);

        final resultA = futures[0] as List<String>;
        final resultB = futures[1] as List<String>;

        expect(resultA, equals(['ctx-a-1']),
            reason: 'tenant-a должен видеть только свои данные');
        expect(resultB, equals(['ctx-b-secret']),
            reason: 'tenant-b должен видеть только свои данные');
      } finally {
        await conn1.close();
        await conn2.close();
      }
    });

    test('Test 4.2: Rollback does not leak context', () async {
      // Транзакция 1: устанавливаем контекст и откатываем
      try {
        await conn.runTx((session) async {
          await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

          // Создаём запись
          await session.execute(
            '''INSERT INTO projects (id, tenant_id, data) VALUES
               ('ctx-rollback-1', 'tenant-a', '{"id":"ctx-rollback-1","name":"Rollback Test","tenantId":"tenant-a","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}')
            ''',
          );

          // Принудительно откатываем транзакцию
          throw Exception('Forced rollback');
        });
      } catch (e) {
        // Ожидаем исключение
      }

      // Транзакция 2: проверяем, что контекст не "утёк"
      await conn.runTx((session) async {
        // НЕ устанавливаем контекст явно

        final result = await session.execute(
          'SELECT id FROM projects WHERE id = \'ctx-rollback-1\'',
        );

        // Запись не должна существовать (откатилась)
        // И без контекста мы не должны видеть никаких данных
        expect(result.isEmpty, isTrue,
            reason: 'После rollback контекст НЕ ДОЛЖЕН утечь в новую транзакцию');
      });
    });

    test('Test 4.3: Long transaction maintains context stability', () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Выполняем 20 операций в одной транзакции
        for (var i = 0; i < 20; i++) {
          final result = await session.execute(
            'SELECT id FROM projects WHERE id = \$1',
            parameters: ['ctx-a-1'],
          );

          expect(result.length, equals(1),
              reason: 'Контекст должен оставаться стабильным на протяжении длинной транзакции (операция $i)');

          // Небольшая задержка для имитации реальной работы
          await Future<void>.delayed(Duration(milliseconds: 10));
        }
      });
    });

    test('Test 4.4: Savepoints do not affect context', () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-a'");

        // Создаём savepoint
        await session.execute('SAVEPOINT sp1');

        // Проверяем данные
        var result = await session.execute(
          'SELECT id FROM projects WHERE id = \'ctx-a-1\'',
        );
        expect(result.length, equals(1));

        // Откатываемся к savepoint
        await session.execute('ROLLBACK TO SAVEPOINT sp1');

        // Проверяем, что контекст всё ещё активен
        result = await session.execute(
          'SELECT id FROM projects WHERE id = \'ctx-a-1\'',
        );
        expect(result.length, equals(1),
            reason: 'Контекст должен сохраняться после ROLLBACK TO SAVEPOINT');
      });
    });
  });
}
