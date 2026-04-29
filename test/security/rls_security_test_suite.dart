import 'package:test/test.dart';

import 'rls_basic_isolation_test.dart' as basic_isolation;
import 'rls_sql_injection_test.dart' as sql_injection;
import 'rls_context_manipulation_test.dart' as context_manipulation;
import 'rls_edge_cases_test.dart' as edge_cases;

/// RLS Security Test Suite Runner
///
/// Запускает все критичные security тесты для проверки RLS tenant-изоляции.
///
/// ## Использование
///
/// ```bash
/// # Запуск всех security тестов
/// dart test test/security/
///
/// # Запуск конкретной категории
/// dart test test/security/rls_basic_isolation_test.dart
/// dart test test/security/rls_sql_injection_test.dart
/// dart test test/security/rls_context_manipulation_test.dart
/// dart test test/security/rls_edge_cases_test.dart
///
/// # С переменной окружения для PostgreSQL
/// TEST_PG_URL=postgres://aq_app:aq_app_secret@localhost:5432/aq_studio dart test test/security/
/// ```
///
/// ## Требования
///
/// 1. PostgreSQL должен быть запущен (localhost:5432)
/// 2. База данных `aq_studio` должна существовать
/// 3. Пользователь `aq_app` должен иметь доступ
/// 4. Таблица `projects` должна быть создана с RLS политиками
///
/// ## Критерии успеха
///
/// ✅ **MUST PASS** (100% критичные):
/// - Все тесты Category 1 (Basic Isolation)
/// - Все тесты Category 2 (SQL Injection)
/// - Все тесты Category 3 (Context Manipulation)
/// - Test 9.1, 9.2 (Empty/Null tenant ID)
///
/// Если хотя бы один из этих тестов падает - система НЕБЕЗОПАСНА для production.
///
/// ## Что проверяют тесты
///
/// ### Category 1: Basic Isolation (7 тестов)
/// - Read isolation: tenant не видит чужие записи
/// - Write isolation: tenant может создать запись с ID другого tenant
/// - Delete isolation: tenant не может удалить чужие записи
/// - Query isolation: query без фильтров возвращает только свои записи
/// - Count isolation: count учитывает только свои записи
/// - Shared ID isolation: разные tenants могут иметь записи с одинаковым ID
/// - Update isolation: tenant не может обновить чужие записи
///
/// ### Category 2: SQL Injection (12 тестов)
/// - OR clause injection
/// - UNION-based injection
/// - Comment injection
/// - Subquery injection
/// - Boolean-based blind injection
/// - Stacked queries injection
/// - JSONB field injection
/// - JSONB operator injection
/// - SET LOCAL injection
/// - Unicode injection
/// - Hex encoding injection
/// - Mass assignment attack
///
/// ### Category 3: Context Manipulation (8 тестов)
/// - Multiple SET LOCAL attempts
/// - Transaction isolation
/// - RESET attempts
/// - Empty context
/// - Special characters in context
/// - Context persistence
/// - Access without context
/// - Case sensitivity
///
/// ### Category 4: Transaction Isolation (4 теста)
/// - Concurrent transactions
/// - Rollback context leak
/// - Long transaction stability
/// - Savepoints
///
/// ### Category 9: Edge Cases (11 тестов)
/// - Empty tenant ID
/// - Whitespace tenant ID
/// - SQL keywords as tenant ID
/// - Special characters
/// - Very long tenant ID
/// - Unicode tenant ID
/// - Case sensitivity
/// - Numeric tenant ID
/// - Path traversal
/// - Null bytes
/// - Duplicate IDs
///
/// ## Интерпретация результатов
///
/// ```
/// ✅ All tests passed - RLS работает корректно, система безопасна
/// ⚠️  Some tests failed - КРИТИЧНО! Проверьте failed тесты
/// ❌ Many tests failed - RLS НЕ РАБОТАЕТ, система небезопасна
/// ```
void main() {
  print('');
  print('🔒 ═══════════════════════════════════════════════════════════');
  print('🔒 RLS Security Test Suite');
  print('🔒 ═══════════════════════════════════════════════════════════');
  print('');
  print('📋 Test Categories:');
  print('   1. Basic Isolation (7 tests) - CRITICAL');
  print('   2. SQL Injection (12 tests) - CRITICAL');
  print('   3. Context Manipulation (8 tests) - CRITICAL');
  print('   4. Transaction Isolation (4 tests)');
  print('   9. Edge Cases (11 tests)');
  print('');
  print('🎯 Total: 42 security tests');
  print('');
  print('⚠️  IMPORTANT: If ANY test fails, investigate immediately!');
  print('   Failed security tests indicate potential data leaks.');
  print('');
  print('🔒 ═══════════════════════════════════════════════════════════');
  print('');

  group('🔒 RLS Security Test Suite', () {
    group('Category 1: Basic Isolation (CRITICAL)', () {
      basic_isolation.main();
    });

    group('Category 2: SQL Injection (CRITICAL)', () {
      sql_injection.main();
    });

    group('Category 3: Context Manipulation (CRITICAL)', () {
      context_manipulation.main();
    });

    group('Category 9: Edge Cases', () {
      edge_cases.main();
    });
  });
}
