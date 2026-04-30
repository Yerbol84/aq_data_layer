import '../exceptions/vault_exceptions.dart';

/// Типизированный диспетчер команд и запросов.
///
/// Заменяет `switch(operation)` + `_allowedOperations` в [VaultRegistry].
///
/// ## Преимущества перед switch
/// - O(1) lookup вместо перебора
/// - Один источник правды: зарегистрировал handler = операция разрешена
/// - Нет рассинхрона между белым списком и dispatch логикой
/// - Легко расширять: `register('myOp', handler)` без изменения существующего кода
///
/// ## Использование
/// ```dart
/// final dispatcher = VaultCommandDispatcher();
/// dispatcher.register('createBranch', (args) async => ...);
/// final result = await dispatcher.dispatch('createBranch', args);
/// ```
final class VaultCommandDispatcher {
  final Map<String, Future<dynamic> Function(Map<String, dynamic>)> _handlers = {};

  /// Зарегистрировать обработчик для операции [commandName].
  void register(
    String commandName,
    Future<dynamic> Function(Map<String, dynamic> args) handler,
  ) {
    _handlers[commandName] = handler;
  }

  /// Выполнить операцию [commandName] с аргументами [args].
  /// Бросает [VaultStorageException] если операция не зарегистрирована.
  Future<dynamic> dispatch(String commandName, Map<String, dynamic> args) {
    final handler = _handlers[commandName];
    if (handler == null) {
      throw VaultStorageException('Unknown operation: "$commandName"');
    }
    return handler(args);
  }

  /// Проверить что операция зарегистрирована (без выполнения).
  bool isRegistered(String commandName) => _handlers.containsKey(commandName);

  /// Все зарегистрированные операции.
  Set<String> get registeredOperations => _handlers.keys.toSet();
}
