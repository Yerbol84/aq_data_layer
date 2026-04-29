import 'package:test/test.dart';
import '../../lib/security/secrets_manager.dart';
import '../../lib/security/secrets_cache.dart';
import '../../lib/security/in_memory_secrets_manager.dart';

void main() {
  group('SecretsCache', () {
    late SecretsCache cache;

    setUp(() {
      cache = SecretsCache(ttl: const Duration(seconds: 2));
    });

    test('кэширует и возвращает секреты', () {
      cache.set('test_key', 'test_value');
      expect(cache.get('test_key'), 'test_value');
    });

    test('возвращает null для несуществующего ключа', () {
      expect(cache.get('nonexistent'), isNull);
    });

    test('истекает после TTL', () async {
      cache.set('test_key', 'test_value');
      expect(cache.get('test_key'), 'test_value');

      // Wait for expiration
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(cache.get('test_key'), isNull);
    });

    test('инвалидирует конкретный ключ', () {
      cache.set('key1', 'value1');
      cache.set('key2', 'value2');

      cache.invalidate('key1');

      expect(cache.get('key1'), isNull);
      expect(cache.get('key2'), 'value2');
    });

    test('очищает весь кэш', () {
      cache.set('key1', 'value1');
      cache.set('key2', 'value2');

      cache.clear();

      expect(cache.get('key1'), isNull);
      expect(cache.get('key2'), isNull);
    });

    test('возвращает статистику', () {
      cache.set('key1', 'value1');
      cache.set('key2', 'value2');

      final stats = cache.getStats();

      expect(stats['total'], 2);
      expect(stats['active'], 2);
      expect(stats['expired'], 0);
    });

    test('удаляет истекшие записи при cleanup', () async {
      cache.set('key1', 'value1');
      await Future<void>.delayed(const Duration(seconds: 3));
      cache.set('key2', 'value2');

      cache.cleanup();

      expect(cache.get('key1'), isNull);
      expect(cache.get('key2'), 'value2');
    });
  });

  group('InMemorySecretsManager', () {
    late InMemorySecretsManager manager;

    setUp(() {
      manager = InMemorySecretsManager();
    });

    test('сохраняет и получает секрет', () async {
      await manager.setSecret('test_key', 'test_value');
      final value = await manager.getSecret('test_key');
      expect(value, 'test_value');
    });

    test('выбрасывает исключение для несуществующего секрета', () async {
      expect(
        () => manager.getSecret('nonexistent'),
        throwsA(isA<SecretNotFoundException>()),
      );
    });

    test('кэширует секреты', () async {
      await manager.setSecret('cached_key', 'cached_value');

      // First call - from storage
      await manager.getSecret('cached_key');

      // Second call - from cache (should be faster)
      final value = await manager.getSecret('cached_key');
      expect(value, 'cached_value');
    });

    test('инвалидирует кэш при обновлении', () async {
      await manager.setSecret('key', 'old_value');
      await manager.getSecret('key'); // Cache it

      await manager.setSecret('key', 'new_value');
      final value = await manager.getSecret('key');

      expect(value, 'new_value');
    });

    test('ротирует секрет', () async {
      await manager.setSecret('rotate_key', 'old_value');
      await manager.rotateSecret('rotate_key');

      final newValue = await manager.getSecret('rotate_key');
      expect(newValue, isNot('old_value'));
    });

    test('увеличивает версию при ротации', () async {
      await manager.setSecret('key', 'value1');
      final meta1 = await manager.getMetadata('key');
      expect(meta1.version, 1);

      await manager.rotateSecret('key');
      final meta2 = await manager.getMetadata('key');
      expect(meta2.version, 2);
    });

    test('возвращает список секретов', () async {
      await manager.setSecret('key1', 'value1');
      await manager.setSecret('key2', 'value2');
      await manager.setSecret('key3', 'value3');

      final keys = await manager.listSecrets();
      expect(keys, containsAll(['key1', 'key2', 'key3']));
    });

    test('удаляет секрет', () async {
      await manager.setSecret('key', 'value');
      await manager.deleteSecret('key');

      expect(
        () => manager.getSecret('key'),
        throwsA(isA<SecretNotFoundException>()),
      );
    });

    test('проверяет существование секрета', () async {
      await manager.setSecret('existing', 'value');

      expect(await manager.exists('existing'), isTrue);
      expect(await manager.exists('nonexistent'), isFalse);
    });

    test('возвращает метаданные секрета', () async {
      await manager.setSecret('key', 'value', metadata: {'env': 'prod'});

      final meta = await manager.getMetadata('key');

      expect(meta.key, 'key');
      expect(meta.version, 1);
      expect(meta.tags['env'], 'prod');
      expect(meta.createdAt, isNotNull);
    });

    test('получает конкретную версию секрета', () async {
      await manager.setSecret('key', 'value1');
      final value = await manager.getSecretVersion('key', '1');
      expect(value, 'value1');
    });

    test('выбрасывает исключение для несуществующей версии', () async {
      await manager.setSecret('key', 'value');

      expect(
        () => manager.getSecretVersion('key', '999'),
        throwsA(isA<SecretOperationException>()),
      );
    });

    test('генерирует разные типы секретов', () async {
      await manager.setSecret('db_password', 'initial');
      await manager.rotateSecret('db_password');
      final password = await manager.getSecret('db_password');
      expect(password.length, 32);

      await manager.setSecret('api_key', 'initial');
      await manager.rotateSecret('api_key');
      final apiKey = await manager.getSecret('api_key');
      expect(apiKey, isNotEmpty);

      await manager.setSecret('jwt_secret', 'initial');
      await manager.rotateSecret('jwt_secret');
      final jwtSecret = await manager.getSecret('jwt_secret');
      expect(jwtSecret, isNotEmpty);
    });
  });

  group('SecretMetadata', () {
    test('определяет необходимость ротации', () {
      final oldSecret = SecretMetadata(
        key: 'old',
        createdAt: DateTime.now().subtract(const Duration(days: 100)),
        version: 1,
      );

      expect(oldSecret.needsRotation(), isTrue);

      final newSecret = SecretMetadata(
        key: 'new',
        createdAt: DateTime.now().subtract(const Duration(days: 30)),
        version: 1,
      );

      expect(newSecret.needsRotation(), isFalse);
    });

    test('проверяет истечение срока', () {
      final expired = SecretMetadata(
        key: 'expired',
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().subtract(const Duration(days: 1)),
        version: 1,
      );

      expect(expired.isExpired(), isTrue);

      final valid = SecretMetadata(
        key: 'valid',
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(days: 30)),
        version: 1,
      );

      expect(valid.isExpired(), isFalse);
    });

    test('вычисляет дни до ротации', () {
      final secret = SecretMetadata(
        key: 'test',
        createdAt: DateTime.now().subtract(const Duration(days: 60)),
        version: 1,
      );

      final days = secret.daysUntilRotation();
      expect(days, closeTo(30, 1)); // ~30 days remaining
    });
  });
}
