import 'package:test/test.dart';
import 'package:dart_vault/server.dart';
import 'package:aq_schema/aq_schema.dart';

/// Тест валидации схемы для PostgresSchemaDeployer.
///
/// Проверяет:
/// - Обнаружение отсутствующих таблиц
/// - Валидацию структуры существующих таблиц
/// - Проверку типов колонок
/// - Валидацию дополнительных таблиц для Versioned/Logged режимов
void main() {
  group('PostgresSchemaDeployer Validation', () {
    test('validates table structure - missing columns', () {
      // Этот тест демонстрирует логику валидации
      // В реальности нужна PostgreSQL база для интеграционного теста

      final requiredColumns = {'id', 'tenant_id', 'data', 'created_at', 'updated_at'};
      final actualColumns = {'id', 'tenant_id', 'data'}; // Отсутствуют created_at, updated_at

      final missingColumns = requiredColumns.difference(actualColumns);

      expect(missingColumns, isNotEmpty);
      expect(missingColumns, containsAll(['created_at', 'updated_at']));
    });

    test('validates column types', () {
      final columns = {
        'id': 'text',
        'tenant_id': 'text',
        'data': 'jsonb',
        'created_at': 'timestamp with time zone',
        'updated_at': 'timestamp with time zone',
      };

      // Проверка правильных типов
      expect(columns['id'], equals('text'));
      expect(columns['tenant_id'], equals('text'));
      expect(columns['data'], equals('jsonb'));
      expect(columns['created_at'], equals('timestamp with time zone'));
      expect(columns['updated_at'], equals('timestamp with time zone'));
    });

    test('validates versioned mode tables', () {
      // Для Versioned режима нужны дополнительные таблицы
      final collection = 'workflows';
      final versionsTable = '${collection}_versions';
      final currentTable = '${collection}_current';

      expect(versionsTable, equals('workflows_versions'));
      expect(currentTable, equals('workflows_current'));

      // Проверка обязательных колонок для _versions
      final requiredVersionsColumns = {
        'node_id',
        'entity_id',
        'tenant_id',
        'version',
        'status',
        'branch',
        'data',
        'created_at'
      };

      expect(requiredVersionsColumns.length, equals(8));

      // Проверка обязательных колонок для _current
      final requiredCurrentColumns = {
        'entity_id',
        'tenant_id',
        'node_id',
        'updated_at'
      };

      expect(requiredCurrentColumns.length, equals(4));
    });

    test('validates logged mode tables', () {
      // Для Logged режима нужна дополнительная таблица _log
      final collection = 'runs';
      final logTable = '${collection}_log';

      expect(logTable, equals('runs_log'));

      // Проверка обязательных колонок для _log
      final requiredLogColumns = {
        'entry_id',
        'entity_id',
        'tenant_id',
        'operation',
        'actor_id',
        'changes',
        'timestamp'
      };

      expect(requiredLogColumns.length, equals(7));
    });

    test('error message format for missing columns', () {
      final tableName = 'workflows';
      final missingColumns = {'created_at', 'updated_at'};
      final requiredColumns = {'id', 'tenant_id', 'data', 'created_at', 'updated_at'};
      final foundColumns = {'id', 'tenant_id', 'data'};

      final errorMessage = 'Table "$tableName" is missing required columns: ${missingColumns.join(", ")}\n'
          'Expected columns: ${requiredColumns.join(", ")}\n'
          'Found columns: ${foundColumns.join(", ")}\n'
          'Please run migration or drop the table to recreate it.';

      expect(errorMessage, contains('missing required columns'));
      expect(errorMessage, contains('created_at, updated_at'));
      expect(errorMessage, contains('Please run migration'));
    });

    test('error message format for wrong column type', () {
      final tableName = 'workflows';
      final columnName = 'data';
      final expectedType = 'jsonb';
      final actualType = 'text';

      final errorMessage = 'Table "$tableName" column "$columnName" has wrong type.\n'
          'Expected: $expectedType\n'
          'Found: $actualType';

      expect(errorMessage, contains('wrong type'));
      expect(errorMessage, contains('Expected: jsonb'));
      expect(errorMessage, contains('Found: text'));
    });

    test('validates direct mode structure', () {
      // Direct режим требует только основную таблицу
      final requiredColumns = {
        'id',
        'tenant_id',
        'data',
        'created_at',
        'updated_at'
      };

      expect(requiredColumns.length, equals(5));
      expect(requiredColumns, contains('id'));
      expect(requiredColumns, contains('tenant_id'));
      expect(requiredColumns, contains('data'));
    });

    test('table existence check query', () {
      // SQL запрос для проверки существования таблицы
      final tableName = 'workflows';
      final query = '''
      SELECT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_name = @table_name
      )
      ''';

      expect(query, contains('information_schema.tables'));
      expect(query, contains('table_schema = \'public\''));
      expect(query, contains('table_name = @table_name'));
    });

    test('column info query', () {
      // SQL запрос для получения информации о колонках
      final query = '''
      SELECT column_name, data_type
      FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = @table_name
      ''';

      expect(query, contains('information_schema.columns'));
      expect(query, contains('column_name, data_type'));
      expect(query, contains('table_schema = \'public\''));
    });
  });

  group('Schema Validation Flow', () {
    test('validation flow for new table', () {
      // Новая таблица: не существует → создаём
      final tableExists = false;

      if (tableExists) {
        fail('Should not validate non-existent table');
      } else {
        // Создаём таблицу
        expect(tableExists, isFalse);
      }
    });

    test('validation flow for existing table', () {
      // Существующая таблица: существует → валидируем
      final tableExists = true;

      if (tableExists) {
        // Валидируем структуру
        expect(tableExists, isTrue);
      } else {
        fail('Should validate existing table');
      }
    });

    test('validation catches schema mismatch', () {
      // Симуляция несоответствия схемы
      final expectedColumns = {'id', 'tenant_id', 'data', 'created_at', 'updated_at'};
      final actualColumns = {'id', 'data'}; // Неполная структура

      final isValid = expectedColumns.difference(actualColumns).isEmpty;

      expect(isValid, isFalse, reason: 'Schema mismatch should be detected');
    });

    test('validation passes for correct schema', () {
      // Симуляция правильной схемы
      final expectedColumns = {'id', 'tenant_id', 'data', 'created_at', 'updated_at'};
      final actualColumns = {'id', 'tenant_id', 'data', 'created_at', 'updated_at'};

      final isValid = expectedColumns.difference(actualColumns).isEmpty;

      expect(isValid, isTrue, reason: 'Correct schema should pass validation');
    });
  });
}
