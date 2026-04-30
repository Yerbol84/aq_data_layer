import 'package:aq_schema/aq_schema.dart';
import 'package:postgres/postgres.dart';

import 'domain_registration.dart' show StorageMode;

/// Имена всех таблиц для конкретного типа хранения.
///
/// Единственный источник правды для имён таблиц.
/// Никакого хардкода суффиксов вне реализаций [IStorageSchema].
final class StorageTableNames {
  /// Основная таблица (всегда = collection).
  final String main;

  /// Таблица удалённых записей (все режимы).
  final String deleted;

  /// Таблица лога (только Logged).
  final String? log;

  /// Таблица версий (только Versioned).
  final String? versions;

  /// Таблица текущего указателя (только Versioned).
  final String? current;

  const StorageTableNames({
    required this.main,
    required this.deleted,
    this.log,
    this.versions,
    this.current,
  });

  /// Все таблицы этого типа хранения.
  List<String> get all => [
        main,
        deleted,
        if (log != null) log!,
        if (versions != null) versions!,
        if (current != null) current!,
      ];
}

/// Контракт типа хранения — инкапсулирует весь DDL для одного режима.
///
/// Каждый тип хранения (Direct, Versioned, Logged) реализует этот интерфейс
/// и является единственным местом где определяется:
/// - какие таблицы создаются
/// - какие индексы нужны
/// - какие RLS политики применяются
///
/// [SchemaDeployer] не знает о режимах — он просто вызывает [deploy].
/// Клиент (домен) не знает о таблицах — он работает через [tableNames].
///
/// ## Правило
/// Нет ни одной строки вида `'${collection}_log'` вне реализаций этого интерфейса.
abstract interface class IStorageSchema {
  /// Имя коллекции (задаётся клиентом при регистрации домена).
  String get collection;

  /// Режим хранения.
  StorageMode get mode;

  /// Все имена таблиц — единственный источник правды.
  StorageTableNames get tableNames;

  /// Создать все таблицы, индексы и RLS политики.
  /// Идемпотентно — безопасно вызывать при каждом старте.
  Future<void> deploy(Session connection, List<VaultIndex> indexes);

  /// Валидировать структуру существующих таблиц.
  Future<void> validate(Session connection);
}
