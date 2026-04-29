import 'package:test/test.dart';
import '../../lib/security/sql_safety_validator.dart';

void main() {
  group('SqlSafetyValidator - Classic Injection', () {
    test("detectInjection обнаруживает ' OR '1'='1", () {
      expect(SqlSafetyValidator.detectInjection("' OR '1'='1"), isTrue);
      expect(SqlSafetyValidator.detectInjection("admin' OR '1'='1"), isTrue);
    });

    test("detectInjection обнаруживает ' OR 1=1", () {
      expect(SqlSafetyValidator.detectInjection("' OR 1=1"), isTrue);
      expect(SqlSafetyValidator.detectInjection("' OR 1=1--"), isTrue);
      expect(SqlSafetyValidator.detectInjection("' OR 1=1#"), isTrue);
    });

    test("detectInjection обнаруживает admin'--", () {
      expect(SqlSafetyValidator.detectInjection("admin'--"), isTrue);
      expect(SqlSafetyValidator.detectInjection("admin' --"), isTrue);
    });

    test("detectInjection обнаруживает admin'#", () {
      expect(SqlSafetyValidator.detectInjection("admin'#"), isTrue);
      expect(SqlSafetyValidator.detectInjection("admin' #"), isTrue);
    });
  });

  group('SqlSafetyValidator - UNION Injection', () {
    test("detectInjection обнаруживает UNION SELECT", () {
      expect(SqlSafetyValidator.detectInjection("' UNION SELECT NULL--"), isTrue);
      expect(SqlSafetyValidator.detectInjection("' UNION SELECT username, password FROM users--"), isTrue);
    });

    test("detectInjection обнаруживает UNION ALL SELECT", () {
      expect(SqlSafetyValidator.detectInjection("' UNION ALL SELECT NULL--"), isTrue);
      expect(SqlSafetyValidator.detectInjection("' UNION ALL SELECT NULL, NULL, NULL--"), isTrue);
    });
  });

  group('SqlSafetyValidator - Boolean Blind Injection', () {
    test("detectInjection обнаруживает AND 1=1", () {
      expect(SqlSafetyValidator.detectInjection("' AND 1=1--"), isTrue);
      expect(SqlSafetyValidator.detectInjection("' AND 1=2--"), isTrue);
    });

    test("detectInjection обнаруживает SUBSTRING", () {
      expect(SqlSafetyValidator.detectInjection("' AND SUBSTRING(version(),1,1)='5'--"), isTrue);
    });
  });

  group('SqlSafetyValidator - Time-based Blind Injection', () {
    test("detectInjection обнаруживает WAITFOR DELAY", () {
      expect(SqlSafetyValidator.detectInjection("'; WAITFOR DELAY '00:00:05'--"), isTrue);
    });

    test("detectInjection обнаруживает SLEEP", () {
      expect(SqlSafetyValidator.detectInjection("'; SELECT SLEEP(5)--"), isTrue);
      expect(SqlSafetyValidator.detectInjection("' AND (SELECT * FROM (SELECT(SLEEP(5)))a)--"), isTrue);
    });

    test("detectInjection обнаруживает pg_sleep", () {
      expect(SqlSafetyValidator.detectInjection("'; SELECT pg_sleep(5)--"), isTrue);
    });

    test("detectInjection обнаруживает BENCHMARK", () {
      expect(SqlSafetyValidator.detectInjection("' AND BENCHMARK(5000000,MD5('test'))--"), isTrue);
    });
  });

  group('SqlSafetyValidator - Stacked Queries', () {
    test("detectInjection обнаруживает DROP TABLE", () {
      expect(SqlSafetyValidator.detectInjection("'; DROP TABLE users--"), isTrue);
      expect(SqlSafetyValidator.detectInjection("admin'; DROP TABLE users--"), isTrue);
    });

    test("detectInjection обнаруживает DELETE FROM", () {
      expect(SqlSafetyValidator.detectInjection("'; DELETE FROM users--"), isTrue);
      expect(SqlSafetyValidator.detectInjection("'; DELETE FROM users WHERE 1=1--"), isTrue);
    });

    test("detectInjection обнаруживает UPDATE SET", () {
      expect(SqlSafetyValidator.detectInjection("'; UPDATE users SET password='hacked'--"), isTrue);
    });

    test("detectInjection обнаруживает INSERT INTO", () {
      expect(SqlSafetyValidator.detectInjection("'; INSERT INTO users VALUES('hacker','pass')--"), isTrue);
    });
  });

  group('SqlSafetyValidator - Information Schema', () {
    test("detectInjection обнаруживает information_schema", () {
      expect(SqlSafetyValidator.detectInjection("' UNION SELECT table_name FROM information_schema.tables--"), isTrue);
    });

    test("detectInjection обнаруживает pg_catalog", () {
      expect(SqlSafetyValidator.detectInjection("' UNION SELECT * FROM pg_catalog.pg_tables--"), isTrue);
    });

    test("detectInjection обнаруживает sys.", () {
      expect(SqlSafetyValidator.detectInjection("' UNION SELECT * FROM sys.tables--"), isTrue);
    });
  });

  group('SqlSafetyValidator - Command Execution', () {
    test("detectInjection обнаруживает xp_cmdshell", () {
      expect(SqlSafetyValidator.detectInjection("'; EXEC xp_cmdshell('dir')--"), isTrue);
    });

    test("detectInjection обнаруживает exec/execute", () {
      expect(SqlSafetyValidator.detectInjection("'; exec('DROP TABLE users')--"), isTrue);
      expect(SqlSafetyValidator.detectInjection("'; execute('DROP TABLE users')--"), isTrue);
    });
  });

  group('SqlSafetyValidator - SQL Keywords', () {
    test("detectInjection обнаруживает SQL keywords", () {
      expect(SqlSafetyValidator.detectInjection("SELECT * FROM users"), isTrue);
      expect(SqlSafetyValidator.detectInjection("INSERT INTO users"), isTrue);
      expect(SqlSafetyValidator.detectInjection("UPDATE users SET"), isTrue);
      expect(SqlSafetyValidator.detectInjection("DELETE FROM users"), isTrue);
    });

    test("detectInjection НЕ срабатывает на keywords в кавычках", () {
      // This is a limitation - we allow keywords in quoted strings
      // In practice, parameterized queries prevent this
      expect(SqlSafetyValidator.detectInjection("'SELECT'"), isFalse);
    });
  });

  group('SqlSafetyValidator - Safe Input', () {
    test("detectInjection НЕ срабатывает на безопасный ввод", () {
      expect(SqlSafetyValidator.detectInjection("john.doe@example.com"), isFalse);
      expect(SqlSafetyValidator.detectInjection("John Doe"), isFalse);
      expect(SqlSafetyValidator.detectInjection("123-456-7890"), isFalse);
      expect(SqlSafetyValidator.detectInjection("2026-04-10"), isFalse);
      expect(SqlSafetyValidator.detectInjection(""), isFalse);
    });
  });

  group('SqlSafetyValidator - validateQuery', () {
    test("validateQuery обнаруживает string concatenation", () {
      final result = SqlSafetyValidator.validateQuery(
        "SELECT * FROM users WHERE name = 'John' + ' Doe'",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('concatenation')));
    });

    test("validateQuery обнаруживает hardcoded values", () {
      final result = SqlSafetyValidator.validateQuery(
        "SELECT * FROM users WHERE name = 'John'",
        [],
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('Hardcoded')));
    });

    test("validateQuery обнаруживает parameter mismatch", () {
      final result = SqlSafetyValidator.validateQuery(
        "SELECT * FROM users WHERE id = \$1 AND name = \$2",
        [123], // Only 1 parameter, but 2 placeholders
      );
      expect(result.isValid, isFalse);
      expect(result.issues, contains(contains('mismatch')));
    });

    test("validateQuery принимает правильные parameterized queries", () {
      final result = SqlSafetyValidator.validateQuery(
        "SELECT * FROM users WHERE id = \$1 AND name = \$2",
        [123, 'John'],
      );
      expect(result.isValid, isTrue);
      expect(result.issues, isEmpty);
    });
  });

  group('SqlSafetyValidator - sanitizeInput', () {
    test("sanitizeInput экранирует single quotes", () {
      expect(SqlSafetyValidator.sanitizeInput("O'Brien"), "O''Brien");
      expect(SqlSafetyValidator.sanitizeInput("It's"), "It''s");
    });

    test("sanitizeInput экранирует double quotes", () {
      expect(SqlSafetyValidator.sanitizeInput('Say "hello"'), 'Say ""hello""');
    });

    test("sanitizeInput удаляет semicolons", () {
      expect(SqlSafetyValidator.sanitizeInput("test; DROP TABLE"), "test DROP TABLE");
    });

    test("sanitizeInput удаляет SQL comments", () {
      expect(SqlSafetyValidator.sanitizeInput("admin'--"), "admin''");
      expect(SqlSafetyValidator.sanitizeInput("test /* comment */"), "test  comment ");
      expect(SqlSafetyValidator.sanitizeInput("test # comment"), "test  comment");
    });

    test("sanitizeInput strict mode удаляет все спецсимволы", () {
      final result = SqlSafetyValidator.sanitizeInput(
        "test@example.com!#\$%",
        strict: true,
      );
      expect(result, "testexample.com");
    });
  });

  group('SqlSafetyValidator - isValidIdentifier', () {
    test("isValidIdentifier принимает правильные имена", () {
      expect(SqlSafetyValidator.isValidIdentifier("users"), isTrue);
      expect(SqlSafetyValidator.isValidIdentifier("user_name"), isTrue);
      expect(SqlSafetyValidator.isValidIdentifier("_private"), isTrue);
      expect(SqlSafetyValidator.isValidIdentifier("table123"), isTrue);
    });

    test("isValidIdentifier отклоняет неправильные имена", () {
      expect(SqlSafetyValidator.isValidIdentifier("123table"), isFalse); // Starts with digit
      expect(SqlSafetyValidator.isValidIdentifier("user-name"), isFalse); // Contains dash
      expect(SqlSafetyValidator.isValidIdentifier("user name"), isFalse); // Contains space
      expect(SqlSafetyValidator.isValidIdentifier("user.name"), isFalse); // Contains dot
      expect(SqlSafetyValidator.isValidIdentifier(""), isFalse); // Empty
    });

    test("isValidIdentifier отклоняет SQL keywords", () {
      expect(SqlSafetyValidator.isValidIdentifier("SELECT"), isFalse);
      expect(SqlSafetyValidator.isValidIdentifier("select"), isFalse);
      expect(SqlSafetyValidator.isValidIdentifier("DROP"), isFalse);
      expect(SqlSafetyValidator.isValidIdentifier("TABLE"), isFalse);
    });

    test("isValidIdentifier отклоняет слишком длинные имена", () {
      final longName = 'a' * 64; // PostgreSQL limit is 63
      expect(SqlSafetyValidator.isValidIdentifier(longName), isFalse);
    });
  });

  group('SqlSafetyValidator - Edge Cases', () {
    test("detectInjection обрабатывает case-insensitive", () {
      expect(SqlSafetyValidator.detectInjection("' or '1'='1"), isTrue);
      expect(SqlSafetyValidator.detectInjection("' OR '1'='1"), isTrue);
      expect(SqlSafetyValidator.detectInjection("' Or '1'='1"), isTrue);
    });

    test("detectInjection обрабатывает whitespace variations", () {
      expect(SqlSafetyValidator.detectInjection("'OR'1'='1"), isTrue);
      expect(SqlSafetyValidator.detectInjection("'  OR  '1'='1"), isTrue);
      expect(SqlSafetyValidator.detectInjection("'\tOR\t'1'='1"), isTrue);
    });

    test("detectInjection обрабатывает hex encoding", () {
      expect(SqlSafetyValidator.detectInjection("0x61646D696E"), isTrue); // 'admin' in hex
    });

    test("detectInjection обрабатывает CHAR encoding", () {
      expect(SqlSafetyValidator.detectInjection("CHAR(97)"), isTrue);
      expect(SqlSafetyValidator.detectInjection("CHR(97)"), isTrue);
    });
  });

  group('SqlSafetyValidator - Real-world Scenarios', () {
    test("detectInjection обрабатывает реальные email адреса", () {
      expect(SqlSafetyValidator.detectInjection("user@example.com"), isFalse);
      expect(SqlSafetyValidator.detectInjection("john.doe+tag@example.co.uk"), isFalse);
    });

    test("detectInjection обрабатывает реальные имена", () {
      expect(SqlSafetyValidator.detectInjection("O'Brien"), isFalse); // Apostrophe in name
      expect(SqlSafetyValidator.detectInjection("Jean-Pierre"), isFalse);
      expect(SqlSafetyValidator.detectInjection("Mary Ann"), isFalse);
    });

    test("detectInjection обрабатывает UUID", () {
      expect(SqlSafetyValidator.detectInjection("550e8400-e29b-41d4-a716-446655440000"), isFalse);
    });

    test("detectInjection обрабатывает JSON", () {
      expect(SqlSafetyValidator.detectInjection('{"name":"John","age":30}'), isFalse);
    });
  });
}
