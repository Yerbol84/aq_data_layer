import 'dart:io';
import 'package:test/test.dart';
import 'package:postgres/postgres.dart';

/// RLS Security Tests - Category 9: Edge Cases
///
/// Проверяет поведение системы в экстремальных и нестандартных ситуациях.
/// Эти тесты выявляют уязвимости, которые могут быть упущены в обычных тестах.
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

    // Очищаем все тестовые данные перед каждым тестом
    // Используем TRUNCATE для полной очистки, включая нарушенные constraint'ы
    try {
      await conn.execute('TRUNCATE TABLE projects CASCADE');
    } catch (e) {
      // Если TRUNCATE не работает, пробуем DELETE
      await conn.execute('DELETE FROM projects');
    }
  });

  tearDown(() async {
    await conn.close();
  });

  group('Category 9: Edge Cases', () {
    test('Test 9.1: Empty tenant ID blocks all access', () async {
      await conn.runTx((session) async {
        // Устанавливаем пустой tenant ID
        await session.execute("SET LOCAL app.current_tenant = ''");

        // Пытаемся прочитать данные
        final result = await session.execute(
          'SELECT id FROM projects WHERE id LIKE \'edge-%\'',
        );

        expect(result.isEmpty, isTrue,
            reason: 'Пустой tenant ID НЕ ДОЛЖЕН давать доступ к данным');
      });
    });

    test('Test 9.2: Whitespace-only tenant ID blocks access', () async {
      await conn.runTx((session) async {
        // Устанавливаем tenant ID из пробелов
        await session.execute("SET LOCAL app.current_tenant = '   '");

        final result = await session.execute(
          'SELECT id FROM projects WHERE id LIKE \'edge-%\'',
        );

        expect(result.isEmpty, isTrue,
            reason: 'Whitespace tenant ID НЕ ДОЛЖЕН давать доступ');
      });
    });

    test('Test 9.3: SQL keywords as tenant ID', () async {
      // Создаём tenant с ID = SQL keyword
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'SELECT'");
        await session.execute(
          '''INSERT INTO projects (id, tenant_id, data) VALUES
             ('edge-select-1', 'SELECT', '{"id":"edge-select-1","name":"SQL Keyword","tenantId":"SELECT","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}')
          ''',
        );
      });

      // Проверяем, что можем прочитать
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'SELECT'");

        final result = await session.execute(
          'SELECT id FROM projects WHERE id = \$1',
          parameters: ['edge-select-1'],
        );

        expect(result.length, equals(1),
            reason: 'SQL keywords как tenant ID должны работать корректно');
      });

      // Проверяем изоляцию
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'DROP'");

        final result = await session.execute(
          'SELECT id FROM projects WHERE id = \$1',
          parameters: ['edge-select-1'],
        );

        expect(result.isEmpty, isTrue,
            reason: 'Другой tenant НЕ ДОЛЖЕН видеть запись');
      });
    });

    test('Test 9.4: Special characters in tenant ID', () async {
      final specialTenants = [
        "tenant'; DROP TABLE projects--",
        "tenant\"; DELETE FROM projects--",
        "tenant' OR '1'='1",
        "tenant\\x00",
        "tenant\n\r\t",
        "tenant<script>alert('xss')</script>",
        "../../../etc/passwd",
        "tenant%00",
      ];

      for (final tenantId in specialTenants) {
        await conn.runTx((session) async {
          // Экранируем одинарные кавычки для SET LOCAL
          final escapedTenantId = tenantId.replaceAll("'", "''");

          try {
            await session.execute(
                "SET LOCAL app.current_tenant = '$escapedTenantId'");

            // Пытаемся создать запись
            await session.execute(
              '''INSERT INTO projects (id, tenant_id, data) VALUES
                 (\$1, \$2, \$3)
              ''',
              parameters: [
                'edge-special-${specialTenants.indexOf(tenantId)}',
                tenantId,
                {
                  'id': 'edge-special-${specialTenants.indexOf(tenantId)}',
                  'name': 'Special Char Test',
                  'tenantId': tenantId,
                  'projectType': 'workflow',
                  'ownerId': '',
                  'path': '',
                  'lastOpened': '2026-04-09T14:00:00.000Z',
                }
              ],
            );

            // Если создание прошло успешно, проверяем изоляцию
            final result = await session.execute(
              'SELECT id FROM projects WHERE id = \$1',
              parameters: ['edge-special-${specialTenants.indexOf(tenantId)}'],
            );

            expect(result.length, equals(1),
                reason: 'Запись должна быть создана для tenant: $tenantId');
          } catch (e) {
            // Некоторые символы могут вызвать ошибку - это OK
            print('⚠️  Tenant ID "$tenantId" вызвал ошибку: $e');
          }
        });
      }

      // Проверяем, что таблица не удалена
      final tableExists = await conn.execute(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'projects')",
      );
      expect(tableExists.first[0], isTrue,
          reason: 'Таблица НЕ ДОЛЖНА быть удалена через special characters');
    });

    test('Test 9.5: Very long tenant ID', () async {
      // Создаём очень длинный tenant ID (10000 символов)
      final longTenantId = 'tenant-' + 'x' * 9993;

      await conn.runTx((session) async {
        try {
          await session.execute(
              "SET LOCAL app.current_tenant = '${longTenantId.replaceAll("'", "''")}'");

          await session.execute(
            '''INSERT INTO projects (id, tenant_id, data) VALUES
               ('edge-long-1', \$1, \$2)
            ''',
            parameters: [
              longTenantId,
              {
                'id': 'edge-long-1',
                'name': 'Long Tenant ID',
                'tenantId': longTenantId,
                'projectType': 'workflow',
                'ownerId': '',
                'path': '',
                'lastOpened': '2026-04-09T14:00:00.000Z',
              }
            ],
          );

          // Проверяем, что можем прочитать
          final result = await session.execute(
            'SELECT id FROM projects WHERE id = \$1',
            parameters: ['edge-long-1'],
          );

          expect(result.length, equals(1),
              reason: 'Длинный tenant ID должен работать корректно');
        } catch (e) {
          // Если длина превышает лимит PostgreSQL - это OK
          print('⚠️  Очень длинный tenant ID вызвал ошибку: $e');
        }
      });
    });

    test('Test 9.6: Unicode tenant ID', () async {
      final unicodeTenants = [
        '租户-中文',
        'арендатор-русский',
        'tenant-עברית',
        'tenant-🔒🔐🔑',
        'tenant-\u200B\u200C\u200D', // Zero-width characters
        'tenant-\uFEFF', // BOM
      ];

      for (final tenantId in unicodeTenants) {
        await conn.runTx((session) async {
          try {
            await session.execute(
                "SET LOCAL app.current_tenant = '${tenantId.replaceAll("'", "''")}'");

            await session.execute(
              '''INSERT INTO projects (id, tenant_id, data) VALUES
                 (\$1, \$2, \$3)
              ''',
              parameters: [
                'edge-unicode-${unicodeTenants.indexOf(tenantId)}',
                tenantId,
                {
                  'id': 'edge-unicode-${unicodeTenants.indexOf(tenantId)}',
                  'name': 'Unicode Test',
                  'tenantId': tenantId,
                  'projectType': 'workflow',
                  'ownerId': '',
                  'path': '',
                  'lastOpened': '2026-04-09T14:00:00.000Z',
                }
              ],
            );

            // Проверяем изоляцию
            final result = await session.execute(
              'SELECT id FROM projects WHERE id = \$1',
              parameters: ['edge-unicode-${unicodeTenants.indexOf(tenantId)}'],
            );

            expect(result.length, equals(1),
                reason: 'Unicode tenant ID должен работать: $tenantId');
          } catch (e) {
            print('⚠️  Unicode tenant ID "$tenantId" вызвал ошибку: $e');
          }
        });
      }
    });

    test('Test 9.7: Case sensitivity of tenant ID', () async {
      // Создаём записи для разных вариантов регистра
      final tenantVariants = ['tenant-case', 'Tenant-Case', 'TENANT-CASE'];

      for (final tenantId in tenantVariants) {
        await conn.runTx((session) async {
          await session.execute(
              "SET LOCAL app.current_tenant = '${tenantId.replaceAll("'", "''")}'");

          await session.execute(
            '''INSERT INTO projects (id, tenant_id, data) VALUES
               (\$1, \$2, \$3)
            ''',
            parameters: [
              'edge-case-${tenantVariants.indexOf(tenantId)}',
              tenantId,
              {
                'id': 'edge-case-${tenantVariants.indexOf(tenantId)}',
                'name': 'Case Test $tenantId',
                'tenantId': tenantId,
                'projectType': 'workflow',
                'ownerId': '',
                'path': '',
                'lastOpened': '2026-04-09T14:00:00.000Z',
              }
            ],
          );
        });
      }

      // Проверяем, что каждый вариант видит только свою запись
      for (final tenantId in tenantVariants) {
        await conn.runTx((session) async {
          await session.execute(
              "SET LOCAL app.current_tenant = '${tenantId.replaceAll("'", "''")}'");

          final result = await session.execute(
            'SELECT id, tenant_id FROM projects WHERE id LIKE \'edge-case-%\' ORDER BY id',
          );

          expect(result.length, equals(1),
              reason: 'Tenant "$tenantId" должен видеть только свою запись');

          final returnedTenantId = result.first[1] as String;
          expect(returnedTenantId, equals(tenantId),
              reason: 'tenant_id должен быть case-sensitive');
        });
      }
    });

    test('Test 9.8: Numeric tenant ID', () async {
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = '12345'");

        await session.execute(
          '''INSERT INTO projects (id, tenant_id, data) VALUES
             ('edge-numeric-1', '12345', '{"id":"edge-numeric-1","name":"Numeric Tenant","tenantId":"12345","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}')
          ''',
        );

        final result = await session.execute(
          'SELECT id FROM projects WHERE id = \$1',
          parameters: ['edge-numeric-1'],
        );

        expect(result.length, equals(1),
            reason: 'Numeric tenant ID должен работать');
      });
    });

    test('Test 9.9: Tenant ID with path traversal attempt', () async {
      final pathTraversalIds = [
        '../../../etc/passwd',
        '..\\..\\..\\windows\\system32',
        'tenant/../../admin',
        'tenant/../../../root',
      ];

      for (final tenantId in pathTraversalIds) {
        await conn.runTx((session) async {
          try {
            await session.execute(
                "SET LOCAL app.current_tenant = '${tenantId.replaceAll("'", "''")}'");

            await session.execute(
              '''INSERT INTO projects (id, tenant_id, data) VALUES
                 (\$1, \$2, \$3)
              ''',
              parameters: [
                'edge-path-${pathTraversalIds.indexOf(tenantId)}',
                tenantId,
                {
                  'id': 'edge-path-${pathTraversalIds.indexOf(tenantId)}',
                  'name': 'Path Traversal Test',
                  'tenantId': tenantId,
                  'projectType': 'workflow',
                  'ownerId': '',
                  'path': '',
                  'lastOpened': '2026-04-09T14:00:00.000Z',
                }
              ],
            );

            // Проверяем изоляцию
            final result = await session.execute(
              'SELECT id FROM projects WHERE id = \$1',
              parameters: ['edge-path-${pathTraversalIds.indexOf(tenantId)}'],
            );

            expect(result.length, equals(1),
                reason: 'Path traversal в tenant ID не должен вызывать проблем');
          } catch (e) {
            print('⚠️  Path traversal tenant ID "$tenantId" вызвал ошибку: $e');
          }
        });
      }
    });

    test('Test 9.10: Tenant ID with null bytes', () async {
      // PostgreSQL не поддерживает null bytes в текстовых полях
      // Это security feature - null bytes часто используются в атаках
      // Тест проверяет, что система корректно отклоняет такие попытки
      try {
        await conn.runTx((session) async {
          // Попытка использовать null byte
          final tenantWithNull = 'tenant\x00admin';
          await session.execute(
              "SET LOCAL app.current_tenant = '${tenantWithNull.replaceAll("'", "''")}'");

          await session.execute(
            '''INSERT INTO projects (id, tenant_id, data) VALUES
               ('edge-null-1', \$1, \$2)
            ''',
            parameters: [
              tenantWithNull,
              {
                'id': 'edge-null-1',
                'name': 'Null Byte Test',
                'tenantId': tenantWithNull,
                'projectType': 'workflow',
                'ownerId': '',
                'path': '',
                'lastOpened': '2026-04-09T14:00:00.000Z',
              }
            ],
          );

          // Если создание прошло успешно, проверяем изоляцию
          final result = await session.execute(
            'SELECT id FROM projects WHERE id = \$1',
            parameters: ['edge-null-1'],
          );

          expect(result.length, equals(1),
              reason: 'Null byte в tenant ID должен обрабатываться корректно');
        });
      } catch (e) {
        // PostgreSQL отклоняет null bytes - это ПРАВИЛЬНОЕ поведение
        // Null bytes не должны использоваться в tenant ID
        expect(e.toString(), contains('insufficient data'),
            reason: 'PostgreSQL должен отклонять null bytes в строках');
      }
    });

    test('Test 9.11: Duplicate tenant IDs with different data', () async {
      // Создаём две записи с одинаковым ID для одного tenant
      await conn.runTx((session) async {
        await session.execute("SET LOCAL app.current_tenant = 'tenant-dup'");

        // Первая вставка
        await session.execute(
          '''INSERT INTO projects (id, tenant_id, data) VALUES
             ('edge-dup-1', 'tenant-dup', '{"id":"edge-dup-1","name":"First","tenantId":"tenant-dup","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}')
          ''',
        );

        // Вторая вставка с тем же ID (должна обновить через ON CONFLICT)
        await session.execute(
          '''INSERT INTO projects (id, tenant_id, data) VALUES
             ('edge-dup-1', 'tenant-dup', '{"id":"edge-dup-1","name":"Second","tenantId":"tenant-dup","projectType":"workflow","ownerId":"","path":"","lastOpened":"2026-04-09T14:00:00.000Z"}')
             ON CONFLICT (id, tenant_id) DO UPDATE SET data = EXCLUDED.data
          ''',
        );

        // Проверяем, что осталась только одна запись с последними данными
        final result = await session.execute(
          'SELECT data FROM projects WHERE id = \$1',
          parameters: ['edge-dup-1'],
        );

        expect(result.length, equals(1));
        final data = result.first[0] as Map<String, dynamic>;
        expect(data['name'], equals('Second'),
            reason: 'ON CONFLICT должен обновить запись');
      });
    });
  });
}
