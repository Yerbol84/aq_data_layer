import 'package:test/test.dart';
import '../../lib/storage/postgres/vault_query_validator.dart';

void main() {
  group('QueryValidator - String Concatenation', () {
    test('detectStringConcatenation обнаруживает + operator', () {
      final result = QueryValidator.validate(
        "SELECT * FROM users WHERE name = 'John' + ' Doe'",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('+ operator')));
    });

    test('detectStringConcatenation обнаруживает || operator', () {
      final result = QueryValidator.validate(
        "SELECT * FROM users WHERE name = 'John' || ' Doe'",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('|| operator')));
    });

    test('detectStringConcatenation обнаруживает CONCAT function', () {
      final result = QueryValidator.validate(
        "SELECT * FROM users WHERE name = CONCAT('John', ' Doe')",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('CONCAT')));
    });
  });

  group('QueryValidator - Hardcoded Values', () {
    test('detectHardcodedValues обнаруживает WHERE clause', () {
      final result = QueryValidator.validate(
        "SELECT * FROM users WHERE name = 'John'",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('Hardcoded')));
    });

    test('detectHardcodedValues обнаруживает INSERT VALUES', () {
      final result = QueryValidator.validate(
        "INSERT INTO users (name) VALUES ('John')",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('Hardcoded')));
    });

    test('detectHardcodedValues обнаруживает UPDATE SET', () {
      final result = QueryValidator.validate(
        "UPDATE users SET name = 'John'",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('Hardcoded')));
    });
  });

  group('QueryValidator - Parameter Count', () {
    test('detectParameterMismatch обнаруживает несоответствие', () {
      final result = QueryValidator.validate(
        "SELECT * FROM users WHERE id = \$1 AND name = \$2",
        [123], // Only 1 parameter, but 2 placeholders
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('mismatch')));
    });

    test('detectParameterMismatch принимает правильное количество', () {
      final result = QueryValidator.validate(
        "SELECT * FROM users WHERE id = \$1 AND name = \$2",
        [123, 'John'],
      );
      // May have other issues, but not parameter count
      expect(result.issues.where((i) => i.contains('mismatch')), isEmpty);
    });

    test('detectParameterMismatch обрабатывает ? placeholders', () {
      final result = QueryValidator.validate(
        "SELECT * FROM users WHERE id = ? AND name = ?",
        [123], // Only 1 parameter, but 2 placeholders
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('mismatch')));
    });
  });

  group('QueryValidator - Dynamic Identifiers', () {
    test('detectDynamicIdentifiers обнаруживает string interpolation', () {
      final result = QueryValidator.validate(
        "SELECT * FROM \${tableName}",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('interpolation')));
    });

    test('detectDynamicIdentifiers обнаруживает \$table pattern', () {
      final result = QueryValidator.validate(
        "SELECT * FROM \$table",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('Dynamic identifier')));
    });

    test('detectDynamicIdentifiers обнаруживает \$column pattern', () {
      final result = QueryValidator.validate(
        "SELECT \$column FROM users",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('Dynamic identifier')));
    });
  });

  group('QueryValidator - Injection Patterns', () {
    test('detectInjectionPatterns обнаруживает SQL comments', () {
      final result = QueryValidator.validate(
        "SELECT * FROM users WHERE id = 123--",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('comment')));
    });

    test('detectInjectionPatterns обнаруживает block comments', () {
      final result = QueryValidator.validate(
        "SELECT * FROM users /* comment */ WHERE id = 123",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('Block comment')));
    });

    test('detectInjectionPatterns обнаруживает stacked queries', () {
      final result = QueryValidator.validate(
        "SELECT * FROM users; DROP TABLE users",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('Multiple statements')));
    });

    test('detectInjectionPatterns обнаруживает UNION SELECT', () {
      final result = QueryValidator.validate(
        "SELECT * FROM users UNION SELECT * FROM passwords",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('UNION SELECT')));
    });
  });

  group('QueryValidator - Unsafe Operators', () {
    test('detectUnsafeOperators обнаруживает EXECUTE', () {
      final result = QueryValidator.validate(
        "EXECUTE('DROP TABLE users')",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('EXECUTE')));
    });

    test('detectUnsafeOperators обнаруживает xp_cmdshell', () {
      final result = QueryValidator.validate(
        "EXEC xp_cmdshell('dir')",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('xp_cmdshell')));
    });

    test('detectUnsafeOperators обнаруживает INTO OUTFILE', () {
      final result = QueryValidator.validate(
        "SELECT * FROM users INTO OUTFILE '/tmp/users.txt'",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('INTO OUTFILE')));
    });

    test('detectUnsafeOperators обнаруживает LOAD_FILE', () {
      final result = QueryValidator.validate(
        "SELECT LOAD_FILE('/etc/passwd')",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('LOAD_FILE')));
    });
  });

  group('QueryValidator - Safe Queries', () {
    test('validate принимает правильные parameterized queries', () {
      final result = QueryValidator.validate(
        "SELECT * FROM users WHERE id = \$1 AND name = \$2",
        [123, 'John'],
      );
      expect(result.isValid, isTrue);
      expect(result.issues, isEmpty);
    });

    test('validate принимает INSERT с parameters', () {
      final result = QueryValidator.validate(
        "INSERT INTO users (name, email) VALUES (\$1, \$2)",
        ['John', 'john@example.com'],
      );
      expect(result.isValid, isTrue);
      expect(result.issues, isEmpty);
    });

    test('validate принимает UPDATE с parameters', () {
      final result = QueryValidator.validate(
        "UPDATE users SET name = \$1 WHERE id = \$2",
        ['Jane', 123],
      );
      expect(result.isValid, isTrue);
      expect(result.issues, isEmpty);
    });

    test('validate принимает DELETE с parameters', () {
      final result = QueryValidator.validate(
        "DELETE FROM users WHERE id = \$1",
        [123],
      );
      expect(result.isValid, isTrue);
      expect(result.issues, isEmpty);
    });
  });

  group('QueryValidator - Batch Validation', () {
    test('validateBatch обрабатывает несколько queries', () {
      final results = QueryValidator.validateBatch(
        [
          "SELECT * FROM users WHERE id = \$1",
          "INSERT INTO logs (message) VALUES (\$1)",
          "UPDATE users SET status = 'active'", // Hardcoded value
        ],
        [
          [123],
          ['test'],
          [],
        ],
      );

      expect(results.length, 3);
      expect(results[0].isValid, isTrue);
      expect(results[1].isValid, isTrue);
      expect(results[2].isValid, isFalse);
    });

    test('validateBatch отклоняет mismatched lengths', () {
      expect(
        () => QueryValidator.validateBatch(
          ["SELECT * FROM users"],
          [[], []],
        ),
        throwsArgumentError,
      );
    });
  });

  group('QueryValidator - isSafe', () {
    test('isSafe возвращает true для безопасных queries', () {
      expect(
        QueryValidator.isSafe(
          "SELECT * FROM users WHERE id = \$1",
          [123],
        ),
        isTrue,
      );
    });

    test('isSafe возвращает false для небезопасных queries', () {
      expect(
        QueryValidator.isSafe(
          "SELECT * FROM users WHERE name = 'John'",
          [],
        ),
        isFalse,
      );
    });
  });
}
