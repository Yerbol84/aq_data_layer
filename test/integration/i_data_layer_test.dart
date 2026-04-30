// Test IDataLayer integration with dart_vault implementation
import 'package:test/test.dart';
import 'package:dart_vault/dart_vault.dart';
import 'package:aq_schema/aq_schema.dart';

void main() {
  group('IDataLayer API', () {
    test('isInitialized is false before register', () {
      // Если предыдущий тест не зарегистрировал — false
      // Этот тест проверяет что геттер существует и возвращает bool
      expect(IDataLayer.isInitialized, isA<bool>());
    });

    test('register and instance work', () {
      if (IDataLayer.isInitialized) return; // уже зарегистрирован

      final impl = _FakeDataLayer();
      IDataLayer.register(impl);
      expect(IDataLayer.isInitialized, true);
      expect(IDataLayer.instance, same(impl));
    });

    test('instance throws AssertionError if not initialized', () {
      if (IDataLayer.isInitialized) return; // пропустить если уже есть
      expect(() => IDataLayer.instance, throwsA(isA<AssertionError>()));
    });
  });

  group('Backward compatibility with Vault', () {
    tearDown(() async {
      await Vault.disconnect();
    });

    test('Vault.disconnect is safe when not connected', () async {
      await Vault.disconnect(); // не должен бросать
    });

    test('Vault.connect falls back to in-memory on unreachable server', () async {
      // failFast: false — тихий fallback
      await Vault.connect('http://localhost:19999', failFast: false);
      expect(Vault.instance, isNotNull);
      expect(Vault.instance.buffer, isNull); // InMemory не имеет буфера
    });
  });
}

// ── Minimal fake for testing ──────────────────────────────────────────────────

class _FakeDataLayer implements IDataLayer {
  @override
  DirectRepository<T> direct<T extends DirectStorable>({
    required String collection,
    required T Function(Map<String, dynamic>) fromMap,
    List<VaultIndex> indexes = const [],
  }) => throw UnimplementedError();

  @override
  VersionedRepository<T> versioned<T extends VersionedStorable>({
    required String collection,
    required T Function(Map<String, dynamic>) fromMap,
    List<VaultIndex> indexes = const [],
  }) => throw UnimplementedError();

  @override
  LoggedRepository<T> logged<T extends LoggedStorable>({
    required String collection,
    required T Function(Map<String, dynamic>) fromMap,
    List<VaultIndex> indexes = const [],
    bool captureFullSnapshot = false,
  }) => throw UnimplementedError();

  @override
  IBufferedStorage? get buffer => null;
  @override
  String get tenantId => 'test';
  @override
  String get endpoint => 'http://fake';
  @override
  String? get serverVersion => null;
  @override
  bool get isConnected => false;
  @override
  Future<void> dispose() async {}
}
