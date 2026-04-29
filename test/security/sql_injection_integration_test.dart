import 'dart:async';
import 'package:test/test.dart';
import 'package:postgres/postgres.dart';
import '../../lib/security/safe_query_builder.dart';
import '../../lib/security/query_validator.dart';
import '../../lib/security/sql_safety_validator.dart';
import '../../lib/security/input_sanitizer.dart';

/// Integration tests for SQL injection prevention with real PostgreSQL
///
/// These tests verify that our security measures work against a real database.
void main() {
  late Connection connection;

  setUpAll(() async {
    // Connect to test database
    connection = await Connection.open(
      Endpoint(
        host: 'localhost',
        database: 'vault_test',
        username: 'postgres',
        password: 'postgres',
      ),
      settings: ConnectionSettings(
        sslMode: SslMode.disable,
      ),
    );

    // Create test table
    await connection.execute('''
      CREATE TABLE IF NOT EXISTS test_users (
        id SERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT NOT NULL,
        status TEXT NOT NULL,
        age INTEGER,
        created_at TIMESTAMP DEFAULT NOW()
      )
    ''');

    // Clear test data
    await connection.execute('TRUNCATE test_users RESTART IDENTITY');
  });

  tearDownAll(() async {
    // Clean up
    await connection.execute('DROP TABLE IF EXISTS test_users');
    await connection.close();
  });

  setUp(() async {
    // Clear data before each test
    await connection.execute('TRUNCATE test_users RESTART IDENTITY');
  });

  group('SafeQueryBuilder - Real Database Integration', () {
    test('INSERT с SafeQueryBuilder безопасно вставляет данные', () async {
      final builder = SafeQueryBuilder()
        .insert('test_users', {
          'name': 'John Doe',
          'email': 'john@example.com',
          'status': 'active',
          'age': 30,
        })
        .returning(['id', 'name']);

      final result = await connection.execute(
        builder.sql,
        parameters: builder.parameters,
      );

      expect(result.length, 1);
      expect(result.first[1], 'John Doe');
    });

    test('SELECT с SafeQueryBuilder безопасно читает данные', () async {
      // Insert test data
      await connection.execute(
        'INSERT INTO test_users (name, email, status, age) VALUES (\$1, \$2, \$3, \$4)',
        parameters: ['Alice', 'alice@example.com', 'active', 25],
      );

      final builder = SafeQueryBuilder()
        .select('test_users', ['id', 'name', 'email'])
        .where('status', '=', 'active')
        .where('age', '>=', 18);

      final result = await connection.execute(
        builder.sql,
        parameters: builder.parameters,
      );

      expect(result.length, 1);
      expect(result.first[1], 'Alice');
    });

    test('UPDATE с SafeQueryBuilder безопасно обновляет данные', () async {
      // Insert test data
      await connection.execute(
        'INSERT INTO test_users (name, email, status, age) VALUES (\$1, \$2, \$3, \$4)',
        parameters: ['Bob', 'bob@example.com', 'pending', 35],
      );

      final builder = SafeQueryBuilder()
        .update('test_users', {'status': 'active'})
        .where('name', '=', 'Bob')
        .returning(['id', 'status']);

      final result = await connection.execute(
        builder.sql,
        parameters: builder.parameters,
      );

      expect(result.length, 1);
      expect(result.first[1], 'active');
    });

    test('DELETE с SafeQueryBuilder безопасно удаляет данные', () async {
      // Insert test data
      await connection.execute(
        'INSERT INTO test_users (name, email, status, age) VALUES (\$1, \$2, \$3, \$4)',
        parameters: ['Charlie', 'charlie@example.com', 'deleted', 40],
      );

      final builder = SafeQueryBuilder()
        .delete('test_users')
        .where('status', '=', 'deleted')
        .returning(['id']);

      final result = await connection.execute(
        builder.sql,
        parameters: builder.parameters,
      );

      expect(result.length, 1);

      // Verify deletion
      final check = await connection.execute(
        'SELECT COUNT(*) FROM test_users WHERE status = \$1',
        parameters: ['deleted'],
      );
      expect(check.first[0], 0);
    });
  });

  group('SQL Injection Attack Prevention', () {
    test('Classic injection attempt блокируется', () async {
      final maliciousInput = "' OR '1'='1";

      // Detect injection
      expect(SqlSafetyValidator.detectInjection(maliciousInput), isTrue);

      // SafeQueryBuilder параметризует input
      final builder = SafeQueryBuilder()
        .select('test_users', ['id', 'name'])
        .where('name', '=', maliciousInput);

      // Insert test data
      await connection.execute(
        'INSERT INTO test_users (name, email, status) VALUES (\$1, \$2, \$3)',
        parameters: ['John', 'john@example.com', 'active'],
      );

      // Query should return 0 results (no user with that exact name)
      final result = await connection.execute(
        builder.sql,
        parameters: builder.parameters,
      );

      expect(result.length, 0);
    });

    test('UNION injection attempt блокируется', () async {
      final maliciousInput = "' UNION SELECT id, name, email FROM test_users--";

      // Detect injection
      expect(SqlSafetyValidator.detectInjection(maliciousInput), isTrue);

      // SafeQueryBuilder параметризует input
      final builder = SafeQueryBuilder()
        .select('test_users', ['id', 'name'])
        .where('email', '=', maliciousInput);

      final result = await connection.execute(
        builder.sql,
        parameters: builder.parameters,
      );

      // Should return 0 results (treated as literal string)
      expect(result.length, 0);
    });

    test('Stacked query injection attempt блокируется', () async {
      final maliciousInput = "'; DROP TABLE test_users--";

      // Detect injection
      expect(SqlSafetyValidator.detectInjection(maliciousInput), isTrue);

      // SafeQueryBuilder параметризует input
      final builder = SafeQueryBuilder()
        .select('test_users', ['id', 'name'])
        .where('name', '=', maliciousInput);

      await connection.execute(
        builder.sql,
        parameters: builder.parameters,
      );

      // Table should still exist
      final result = await connection.execute(
        'SELECT COUNT(*) FROM test_users',
      );
      expect(result, isNotEmpty);
    });

    test('Comment injection attempt блокируется', () async {
      final maliciousInput = "admin'--";

      // Detect injection
      expect(SqlSafetyValidator.detectInjection(maliciousInput), isTrue);

      // SafeQueryBuilder параметризует input
      final builder = SafeQueryBuilder()
        .select('test_users', ['id', 'name'])
        .where('name', '=', maliciousInput);

      final result = await connection.execute(
        builder.sql,
        parameters: builder.parameters,
      );

      // Should return 0 results
      expect(result.length, 0);
    });
  });

  group('Input Sanitization Integration', () {
    test('Sanitized email безопасно сохраняется', () async {
      final email = 'test+tag@example.com';

      expect(InputSanitizer.isValidEmail(email), isTrue);

      final builder = SafeQueryBuilder()
        .insert('test_users', {
          'name': 'Test User',
          'email': email,
          'status': 'active',
        })
        .returning(['email']);

      final result = await connection.execute(
        builder.sql,
        parameters: builder.parameters,
      );

      expect(result.first[0], email);
    });

    test('Sanitized string удаляет опасные символы', () async {
      final maliciousName = '<script>alert("xss")</script>John';
      final sanitized = InputSanitizer.sanitizeString(maliciousName);

      expect(sanitized, 'scriptalert("xss")/scriptJohn');

      final builder = SafeQueryBuilder()
        .insert('test_users', {
          'name': sanitized,
          'email': 'john@example.com',
          'status': 'active',
        })
        .returning(['name']);

      final result = await connection.execute(
        builder.sql,
        parameters: builder.parameters,
      );

      expect(result.first[0], sanitized);
      expect(result.first[0], isNot(contains('<script>')));
    });

    test('Sanitized integer применяет bounds', () async {
      final age = InputSanitizer.sanitizeInt('25', min: 0, max: 150);

      expect(age, 25);

      final builder = SafeQueryBuilder()
        .insert('test_users', {
          'name': 'Test User',
          'email': 'test@example.com',
          'status': 'active',
          'age': age,
        })
        .returning(['age']);

      final result = await connection.execute(
        builder.sql,
        parameters: builder.parameters,
      );

      expect(result.first[0], 25);
    });

    test('Invalid integer отклоняется', () async {
      final age = InputSanitizer.sanitizeInt('invalid', min: 0, max: 150);

      expect(age, isNull);

      // Don't insert invalid data
      if (age == null) {
        return;
      }

      fail('Should not reach here');
    });
  });

  group('Query Validation Integration', () {
    test('Valid parameterized query проходит validation', () async {
      final sql = 'SELECT * FROM test_users WHERE name = \$1 AND age > \$2';
      final params = ['John', 18];

      final validation = QueryValidator.validate(sql, params);

      expect(validation.isValid, isTrue);

      // Insert test data
      await connection.execute(
        'INSERT INTO test_users (name, email, status, age) VALUES (\$1, \$2, \$3, \$4)',
        parameters: ['John', 'john@example.com', 'active', 25],
      );

      final result = await connection.execute(sql, parameters: params);

      expect(result.length, 1);
    });

    test('Invalid query с hardcoded values не проходит validation', () async {
      final sql = "SELECT * FROM test_users WHERE name = 'John'";
      final params = <dynamic>[];

      final validation = QueryValidator.validate(sql, params);

      expect(validation.isValid, isFalse);
      expect(validation.issues, isNotEmpty);
    });

    test('Query с parameter mismatch не проходит validation', () async {
      final sql = 'SELECT * FROM test_users WHERE name = \$1 AND age > \$2';
      final params = ['John']; // Missing second parameter

      final validation = QueryValidator.validate(sql, params);

      expect(validation.isValid, isFalse);
      expect(validation.issues, contains(contains('mismatch')));
    });
  });

  group('Performance Tests', () {
    test('SafeQueryBuilder имеет минимальный overhead', () async {
      final stopwatch = Stopwatch()..start();

      for (var i = 0; i < 100; i++) {
        final builder = SafeQueryBuilder()
          .select('test_users', ['id', 'name', 'email'])
          .where('status', '=', 'active')
          .where('age', '>', 18)
          .orderBy('created_at', descending: true)
          .limit(10);

        // Just build, don't execute
        expect(builder.sql, isNotEmpty);
        expect(builder.parameters, isNotEmpty);
      }

      stopwatch.stop();

      // Should be very fast (<10ms for 100 builds)
      expect(stopwatch.elapsedMilliseconds, lessThan(10));
    });

    test('Input sanitization имеет минимальный overhead', () async {
      final stopwatch = Stopwatch()..start();

      for (var i = 0; i < 1000; i++) {
        InputSanitizer.sanitizeString('test@example.com');
        InputSanitizer.sanitizeInt('123', min: 0, max: 1000);
        InputSanitizer.isValidEmail('test@example.com');
        InputSanitizer.isValidUuid('550e8400-e29b-41d4-a716-446655440000');
      }

      stopwatch.stop();

      // Should be very fast (<10ms for 1000 operations)
      expect(stopwatch.elapsedMilliseconds, lessThan(10));
    });

    test('SQL injection detection имеет минимальный overhead', () async {
      final stopwatch = Stopwatch()..start();

      final testInputs = [
        "' OR '1'='1",
        "' UNION SELECT NULL--",
        "admin'--",
        "normal input",
        "test@example.com",
      ];

      for (var i = 0; i < 200; i++) {
        for (final input in testInputs) {
          SqlSafetyValidator.detectInjection(input);
        }
      }

      stopwatch.stop();

      // Should be fast (<50ms for 1000 checks)
      expect(stopwatch.elapsedMilliseconds, lessThan(50));
    });
  });
}
