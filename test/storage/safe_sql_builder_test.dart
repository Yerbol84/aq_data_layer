import 'package:test/test.dart';
import '../../lib/storage/postgres/safe_sql_builder.dart';

void main() {
  group('SafeQueryBuilder - SELECT', () {
    test('select строит базовый SELECT запрос', () {
      final builder = SafeQueryBuilder()
        .select('users', ['id', 'name', 'email']);

      expect(builder.sql, 'SELECT id, name, email FROM users');
      expect(builder.parameters, isEmpty);
    });

    test('select с WHERE clause', () {
      final builder = SafeQueryBuilder()
        .select('users', ['id', 'name'])
        .where('status', '=', 'active');

      expect(builder.sql, 'SELECT id, name FROM users WHERE status = \$1');
      expect(builder.parameters, ['active']);
    });

    test('select с несколькими WHERE conditions', () {
      final builder = SafeQueryBuilder()
        .select('users', ['id', 'name'])
        .where('status', '=', 'active')
        .where('age', '>', 18);

      expect(builder.sql, 'SELECT id, name FROM users WHERE status = \$1 AND age > \$2');
      expect(builder.parameters, ['active', 18]);
    });

    test('select с OR WHERE', () {
      final builder = SafeQueryBuilder()
        .select('users', ['id', 'name'])
        .where('status', '=', 'active')
        .orWhere('status', '=', 'pending');

      expect(builder.sql, 'SELECT id, name FROM users WHERE status = \$1 OR status = \$2');
      expect(builder.parameters, ['active', 'pending']);
    });

    test('select с WHERE IN', () {
      final builder = SafeQueryBuilder()
        .select('users', ['id', 'name'])
        .whereIn('status', ['active', 'pending', 'verified']);

      expect(builder.sql, 'SELECT id, name FROM users WHERE status IN (\$1, \$2, \$3)');
      expect(builder.parameters, ['active', 'pending', 'verified']);
    });

    test('select с ORDER BY', () {
      final builder = SafeQueryBuilder()
        .select('users', ['id', 'name'])
        .orderBy('created_at');

      expect(builder.sql, 'SELECT id, name FROM users ORDER BY created_at');
      expect(builder.parameters, isEmpty);
    });

    test('select с ORDER BY DESC', () {
      final builder = SafeQueryBuilder()
        .select('users', ['id', 'name'])
        .orderBy('created_at', descending: true);

      expect(builder.sql, 'SELECT id, name FROM users ORDER BY created_at DESC');
      expect(builder.parameters, isEmpty);
    });

    test('select с LIMIT', () {
      final builder = SafeQueryBuilder()
        .select('users', ['id', 'name'])
        .limit(10);

      expect(builder.sql, 'SELECT id, name FROM users LIMIT \$1');
      expect(builder.parameters, [10]);
    });

    test('select с OFFSET', () {
      final builder = SafeQueryBuilder()
        .select('users', ['id', 'name'])
        .limit(10)
        .offset(20);

      expect(builder.sql, 'SELECT id, name FROM users LIMIT \$1 OFFSET \$2');
      expect(builder.parameters, [10, 20]);
    });

    test('select комплексный запрос', () {
      final builder = SafeQueryBuilder()
        .select('users', ['id', 'name', 'email'])
        .where('status', '=', 'active')
        .where('age', '>=', 18)
        .orderBy('created_at', descending: true)
        .limit(50)
        .offset(100);

      expect(
        builder.sql,
        'SELECT id, name, email FROM users WHERE status = \$1 AND age >= \$2 ORDER BY created_at DESC LIMIT \$3 OFFSET \$4',
      );
      expect(builder.parameters, ['active', 18, 50, 100]);
    });
  });

  group('SafeQueryBuilder - INSERT', () {
    test('insert строит базовый INSERT запрос', () {
      final builder = SafeQueryBuilder()
        .insert('users', {
          'name': 'John Doe',
          'email': 'john@example.com',
          'status': 'active',
        });

      expect(builder.sql, 'INSERT INTO users (name, email, status) VALUES (\$1, \$2, \$3)');
      expect(builder.parameters, ['John Doe', 'john@example.com', 'active']);
    });

    test('insert с RETURNING', () {
      final builder = SafeQueryBuilder()
        .insert('users', {
          'name': 'John Doe',
          'email': 'john@example.com',
        })
        .returning(['id', 'created_at']);

      expect(builder.sql, 'INSERT INTO users (name, email) VALUES (\$1, \$2) RETURNING id, created_at');
      expect(builder.parameters, ['John Doe', 'john@example.com']);
    });
  });

  group('SafeQueryBuilder - UPDATE', () {
    test('update строит базовый UPDATE запрос', () {
      final builder = SafeQueryBuilder()
        .update('users', {
          'name': 'Jane Doe',
          'status': 'inactive',
        })
        .where('id', '=', 123);

      expect(builder.sql, 'UPDATE users SET name = \$1, status = \$2 WHERE id = \$3');
      expect(builder.parameters, ['Jane Doe', 'inactive', 123]);
    });

    test('update с несколькими WHERE conditions', () {
      final builder = SafeQueryBuilder()
        .update('users', {'status': 'archived'})
        .where('status', '=', 'deleted')
        .where('created_at', '<', DateTime(2020, 1, 1));

      expect(builder.sql, 'UPDATE users SET status = \$1 WHERE status = \$2 AND created_at < \$3');
      expect(builder.parameters, ['archived', 'deleted', DateTime(2020, 1, 1)]);
    });

    test('update с RETURNING', () {
      final builder = SafeQueryBuilder()
        .update('users', {'status': 'active'})
        .where('id', '=', 123)
        .returning(['id', 'status', 'updated_at']);

      expect(builder.sql, 'UPDATE users SET status = \$1 WHERE id = \$2 RETURNING id, status, updated_at');
      expect(builder.parameters, ['active', 123]);
    });
  });

  group('SafeQueryBuilder - DELETE', () {
    test('delete строит базовый DELETE запрос', () {
      final builder = SafeQueryBuilder()
        .delete('users')
        .where('id', '=', 123);

      expect(builder.sql, 'DELETE FROM users WHERE id = \$1');
      expect(builder.parameters, [123]);
    });

    test('delete с несколькими WHERE conditions', () {
      final builder = SafeQueryBuilder()
        .delete('users')
        .where('status', '=', 'deleted')
        .where('created_at', '<', DateTime(2020, 1, 1));

      expect(builder.sql, 'DELETE FROM users WHERE status = \$1 AND created_at < \$2');
      expect(builder.parameters, ['deleted', DateTime(2020, 1, 1)]);
    });

    test('delete с RETURNING', () {
      final builder = SafeQueryBuilder()
        .delete('users')
        .where('id', '=', 123)
        .returning(['id']);

      expect(builder.sql, 'DELETE FROM users WHERE id = \$1 RETURNING id');
      expect(builder.parameters, [123]);
    });
  });

  group('SafeQueryBuilder - Validation', () {
    test('select отклоняет invalid table name', () {
      expect(
        () => SafeQueryBuilder().select('users; DROP TABLE users--', ['id']),
        throwsArgumentError,
      );
    });

    test('select отклоняет invalid column name', () {
      expect(
        () => SafeQueryBuilder().select('users', ['id', 'name; DROP TABLE users--']),
        throwsArgumentError,
      );
    });

    test('where отклоняет invalid column name', () {
      expect(
        () => SafeQueryBuilder()
          .select('users', ['id'])
          .where('id; DROP TABLE users--', '=', 123),
        throwsArgumentError,
      );
    });

    test('where отклоняет invalid operator', () {
      expect(
        () => SafeQueryBuilder()
          .select('users', ['id'])
          .where('id', 'INVALID', 123),
        throwsArgumentError,
      );
    });

    test('insert отклоняет invalid table name', () {
      expect(
        () => SafeQueryBuilder().insert('users; DROP TABLE users--', {'name': 'test'}),
        throwsArgumentError,
      );
    });

    test('insert отклоняет invalid column name', () {
      expect(
        () => SafeQueryBuilder().insert('users', {'name; DROP TABLE users--': 'test'}),
        throwsArgumentError,
      );
    });

    test('insert отклоняет empty data', () {
      expect(
        () => SafeQueryBuilder().insert('users', {}),
        throwsArgumentError,
      );
    });

    test('update отклоняет invalid table name', () {
      expect(
        () => SafeQueryBuilder().update('users; DROP TABLE users--', {'name': 'test'}),
        throwsArgumentError,
      );
    });

    test('update отклоняет empty data', () {
      expect(
        () => SafeQueryBuilder().update('users', {}),
        throwsArgumentError,
      );
    });

    test('delete отклоняет invalid table name', () {
      expect(
        () => SafeQueryBuilder().delete('users; DROP TABLE users--'),
        throwsArgumentError,
      );
    });

    test('limit отклоняет negative/zero values', () {
      expect(
        () => SafeQueryBuilder().select('users', ['id']).limit(0),
        throwsArgumentError,
      );
      expect(
        () => SafeQueryBuilder().select('users', ['id']).limit(-1),
        throwsArgumentError,
      );
    });

    test('offset отклоняет negative values', () {
      expect(
        () => SafeQueryBuilder().select('users', ['id']).offset(-1),
        throwsArgumentError,
      );
    });

    test('whereIn отклоняет empty values', () {
      expect(
        () => SafeQueryBuilder().select('users', ['id']).whereIn('status', []),
        throwsArgumentError,
      );
    });
  });

  group('SafeQueryBuilder - Operators', () {
    test('поддерживает все стандартные операторы сравнения', () {
      final operators = ['=', '!=', '<>', '<', '>', '<=', '>='];

      for (final op in operators) {
        final builder = SafeQueryBuilder()
          .select('users', ['id'])
          .where('age', op, 18);

        expect(builder.sql, contains(op));
      }
    });

    test('поддерживает LIKE операторы', () {
      final builder = SafeQueryBuilder()
        .select('users', ['id'])
        .where('name', 'LIKE', '%John%');

      expect(builder.sql, 'SELECT id FROM users WHERE name LIKE \$1');
      expect(builder.parameters, ['%John%']);
    });

    test('поддерживает IS NULL', () {
      final builder = SafeQueryBuilder()
        .select('users', ['id'])
        .where('deleted_at', 'IS NULL', null);

      expect(builder.sql, 'SELECT id FROM users WHERE deleted_at IS NULL \$1');
      expect(builder.parameters, [null]);
    });
  });

  group('SafeQueryBuilder - Reset', () {
    test('reset очищает builder', () {
      final builder = SafeQueryBuilder()
        .select('users', ['id', 'name'])
        .where('status', '=', 'active');

      expect(builder.sql, isNotEmpty);
      expect(builder.parameters, isNotEmpty);

      builder.reset();

      expect(builder.sql, isEmpty);
      expect(builder.parameters, isEmpty);
    });

    test('reset позволяет переиспользовать builder', () {
      final builder = SafeQueryBuilder();

      builder
        .select('users', ['id'])
        .where('status', '=', 'active');

      expect(builder.sql, 'SELECT id FROM users WHERE status = \$1');

      builder.reset();

      builder
        .select('posts', ['id', 'title'])
        .where('published', '=', true);

      expect(builder.sql, 'SELECT id, title FROM posts WHERE published = \$1');
      expect(builder.parameters, [true]);
    });
  });
}
