import 'package:dart_vault/dart_vault.dart';
import 'remote_vault_storage.dart';

/// Singleton-инициализатор подключения к Data Service.
///
/// Инициализируется один раз в main.dart.
/// Все провайдеры берут vault через VaultClient.instance.vault.
///
/// В основе — RemoteVaultStorage: все операции уходят на HTTP в Data Service.
/// Data Service хранит данные в PostgreSQL.
@Deprecated('message')
class VaultClient {
  VaultClient._();

  static VaultClient? _instance;
  static VaultClient get instance => _instance ??= VaultClient._();

  Vault? _vault;

  /// Vault для создания репозиториев.
  /// Кидает если connect() не был вызван.
  Vault get vault {
    assert(_vault != null, 'VaultClient: call connect() before using vault');
    return _vault!;
  }

  bool get isConnected => _vault != null;

  /// Подключиться к Data Service.
  /// Выполнить в main.dart до runApp().
  Future<void> connect(String endpoint) async {
    if (_vault != null) return;

    final storage = RemoteVaultStorage(
      endpoint: endpoint,
      tenantId: 'system', // глобальный тенант для AQ Studio
      authToken: null, // TODO: передавать JWT из AuthService
    );

    // Handshake: проверяем связь и получаем список коллекций
    await storage.connect();

    _vault = Vault(storage: storage);
  }

  Future<void> dispose() async {
    await _vault?.dispose();
    _vault = null;
  }
}
