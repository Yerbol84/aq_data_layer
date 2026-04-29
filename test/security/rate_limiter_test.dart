import 'package:test/test.dart';
import '../../lib/security/rate_limit_store.dart';
import '../../lib/security/in_memory_rate_limit_store.dart';
import '../../lib/security/rate_limit_config.dart';
import '../../lib/security/vault_rate_limiter.dart';

void main() {
  group('InMemoryRateLimitStore', () {
    late RateLimitStore store;

    setUp(() {
      store = InMemoryRateLimitStore();
    });

    test('добавляет и считает записи', () async {
      await store.add('test_key', 1000);
      await store.add('test_key', 2000);
      await store.add('test_key', 3000);

      final count = await store.count('test_key');
      expect(count, 3);
    });

    test('возвращает 0 для несуществующего ключа', () async {
      final count = await store.count('nonexistent');
      expect(count, 0);
    });

    test('удаляет старые записи', () async {
      await store.add('test_key', 1000);
      await store.add('test_key', 2000);
      await store.add('test_key', 3000);
      await store.add('test_key', 4000);

      await store.removeOldEntries('test_key', 2500);

      final count = await store.count('test_key');
      expect(count, 2); // Только 3000 и 4000 остались
    });

    test('возвращает самую старую запись', () async {
      await store.add('test_key', 1000);
      await store.add('test_key', 2000);
      await store.add('test_key', 3000);

      final oldest = await store.getOldestEntry('test_key');
      expect(oldest, 1000);
    });

    test('возвращает null для пустого ключа', () async {
      final oldest = await store.getOldestEntry('empty_key');
      expect(oldest, isNull);
    });

    test('очищает конкретный ключ', () async {
      await store.add('key1', 1000);
      await store.add('key2', 2000);

      await store.clear('key1');

      expect(await store.count('key1'), 0);
      expect(await store.count('key2'), 1);
    });

    test('очищает все ключи', () async {
      await store.add('key1', 1000);
      await store.add('key2', 2000);
      await store.add('key3', 3000);

      await store.clearAll();

      expect(await store.count('key1'), 0);
      expect(await store.count('key2'), 0);
      expect(await store.count('key3'), 0);
    });
  });

  group('VaultRateLimiter', () {
    late VaultRateLimiter limiter;
    late RateLimitStore store;

    setUp(() {
      store = InMemoryRateLimitStore();
      limiter = VaultRateLimiter(
        config: const RateLimitConfig(
          globalLimit: 10,
          tenantLimit: 5,
          userLimit: 2,
          windowSeconds: 60,
        ),
        store: store,
      );
    });

    test('разрешает запрос в пределах лимита', () async {
      final result = await limiter.checkLimit(
        tenantId: 'tenant1',
        operation: 'read',
        userId: 'user1',
      );

      expect(result.allowed, isTrue);
      expect(result.currentCount, 1);
    });

    test('блокирует запрос при превышении user limit', () async {
      // Заполняем до лимита
      await limiter.checkLimit(tenantId: 'tenant1', operation: 'read', userId: 'user1');
      await limiter.checkLimit(tenantId: 'tenant1', operation: 'read', userId: 'user1');

      // Третий запрос должен быть заблокирован
      final result = await limiter.checkLimit(
        tenantId: 'tenant1',
        operation: 'read',
        userId: 'user1',
      );

      expect(result.allowed, isFalse);
      expect(result.limitType, 'user');
      expect(result.retryAfterSeconds, greaterThan(0));
    });

    test('блокирует запрос при превышении tenant limit', () async {
      // Заполняем до лимита разными пользователями
      for (int i = 0; i < 5; i++) {
        await limiter.checkLimit(
          tenantId: 'tenant1',
          operation: 'read',
          userId: 'user$i',
        );
      }

      // Следующий запрос должен быть заблокирован
      final result = await limiter.checkLimit(
        tenantId: 'tenant1',
        operation: 'read',
        userId: 'user99',
      );

      expect(result.allowed, isFalse);
      expect(result.limitType, 'tenant');
    });

    test('блокирует запрос при превышении global limit', () async {
      // Заполняем до лимита разными тенантами
      for (int i = 0; i < 10; i++) {
        await limiter.checkLimit(
          tenantId: 'tenant$i',
          operation: 'read',
        );
      }

      // Следующий запрос должен быть заблокирован
      final result = await limiter.checkLimit(
        tenantId: 'tenant99',
        operation: 'read',
      );

      expect(result.allowed, isFalse);
      expect(result.limitType, 'global');
    });

    test('изолирует тенантов друг от друга', () async {
      // Заполняем лимит для tenant1
      for (int i = 0; i < 5; i++) {
        await limiter.checkLimit(
          tenantId: 'tenant1',
          operation: 'read',
          userId: 'user$i',
        );
      }

      // tenant2 должен иметь свой лимит
      final result = await limiter.checkLimit(
        tenantId: 'tenant2',
        operation: 'read',
        userId: 'user1',
      );

      expect(result.allowed, isTrue);
    });

    test('возвращает статус лимитов', () async {
      await limiter.checkLimit(tenantId: 'tenant1', operation: 'read', userId: 'user1');
      await limiter.checkLimit(tenantId: 'tenant1', operation: 'read', userId: 'user1');

      final status = await limiter.getStatus(tenantId: 'tenant1', userId: 'user1');

      expect(status['global']['count'], 2);
      expect(status['global']['remaining'], 8);
      expect(status['tenant']['count'], 2);
      expect(status['tenant']['remaining'], 3);
      expect(status['user']['count'], 2);
      expect(status['user']['remaining'], 0);
    });
  });

  group('RateLimitConfig', () {
    test('создает development конфигурацию', () {
      final config = RateLimitConfig.development();

      expect(config.globalLimit, 100000);
      expect(config.tenantLimit, 10000);
      expect(config.userLimit, 1000);
    });

    test('создает production конфигурацию', () {
      final config = RateLimitConfig.production();

      expect(config.globalLimit, 10000);
      expect(config.tenantLimit, 1000);
      expect(config.userLimit, 100);
    });
  });
}
