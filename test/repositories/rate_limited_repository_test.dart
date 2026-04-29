import 'package:test/test.dart';
import '../../lib/repositories/repository.dart';
import '../../lib/repositories/rate_limited_repository.dart';
import '../../lib/security/vault_rate_limiter.dart';
import '../../lib/security/dos_protection.dart';
import '../../lib/security/rate_limit_config.dart';
import '../../lib/security/dos_config.dart';
import '../../lib/security/in_memory_rate_limit_store.dart';

/// Mock repository for testing
class MockRepository<T> implements Repository<T> {
  final List<T> _storage = [];

  @override
  Future<T> save(T entity) async {
    _storage.add(entity);
    return entity;
  }

  @override
  Future<List<T>> saveAll(List<T> entities) async {
    _storage.addAll(entities);
    return entities;
  }

  @override
  Future<T?> findById(String id) async {
    return null;
  }

  @override
  Future<List<T>> findAll({
    int? limit,
    int? offset,
    Map<String, dynamic>? where,
  }) async {
    return _storage;
  }

  @override
  Future<int> count({Map<String, dynamic>? where}) async {
    return _storage.length;
  }

  @override
  Future<void> delete(String id) async {
    // Mock implementation
  }

  @override
  Future<void> deleteAll(List<String> ids) async {
    // Mock implementation
  }

  @override
  Future<bool> exists(String id) async {
    return false;
  }
}

class TestEntity {
  final String id;
  final String name;

  TestEntity({required this.id, required this.name});
}

void main() {
  group('RateLimitedRepository', () {
    late RateLimitedRepository<TestEntity> repository;
    late MockRepository<TestEntity> mockRepo;
    late VaultRateLimiter rateLimiter;
    late DosProtection dosProtection;

    setUp(() {
      mockRepo = MockRepository<TestEntity>();
      rateLimiter = VaultRateLimiter(
        config: const RateLimitConfig(
          globalLimit: 10,
          tenantLimit: 5,
          userLimit: 2,
          windowSeconds: 60,
        ),
        store: InMemoryRateLimitStore(),
      );
      dosProtection = DosProtection(
        config: const DosConfig(
          maxBatchSize: 10,
          maxQueryLimit: 100,
        ),
      );

      repository = RateLimitedRepository<TestEntity>(
        inner: mockRepo,
        rateLimiter: rateLimiter,
        dosProtection: dosProtection,
        tenantId: 'tenant1',
        userId: 'user1',
      );
    });

    group('Rate Limiting', () {
      test('разрешает операции в пределах лимита', () async {
        final entity = TestEntity(id: '1', name: 'Test');
        await repository.save(entity);
        expect(mockRepo._storage.length, 1);
      });

      test('блокирует операции при превышении user limit', () async {
        final entity = TestEntity(id: '1', name: 'Test');

        // Заполняем до лимита
        await repository.save(entity);
        await repository.save(entity);

        // Третья операция должна быть заблокирована
        expect(
          () => repository.save(entity),
          throwsA(isA<RateLimitExceededException>()),
        );
      });

      test('изолирует разных пользователей', () async {
        final entity = TestEntity(id: '1', name: 'Test');

        // User1 заполняет свой лимит
        await repository.save(entity);
        await repository.save(entity);

        // User2 должен иметь свой лимит
        final repo2 = RateLimitedRepository<TestEntity>(
          inner: mockRepo,
          rateLimiter: rateLimiter,
          dosProtection: dosProtection,
          tenantId: 'tenant1',
          userId: 'user2',
        );

        await repo2.save(entity);
        expect(mockRepo._storage.length, 3);
      });
    });

    group('DoS Protection', () {
      test('блокирует oversized batch в saveAll', () async {
        final entities = List.generate(
          20,
          (i) => TestEntity(id: '$i', name: 'Test $i'),
        );

        expect(
          () => repository.saveAll(entities),
          throwsA(isA<DosProtectionException>()),
        );
      });

      test('разрешает batch в пределах лимита', () async {
        final entities = List.generate(
          5,
          (i) => TestEntity(id: '$i', name: 'Test $i'),
        );

        await repository.saveAll(entities);
        expect(mockRepo._storage.length, 5);
      });

      test('требует pagination для findAll', () async {
        expect(
          () => repository.findAll(),
          throwsA(isA<DosProtectionException>()),
        );
      });

      test('разрешает findAll с pagination', () async {
        await repository.findAll(limit: 10, offset: 0);
        // Should not throw
      });

      test('блокирует oversized batch в deleteAll', () async {
        final ids = List.generate(20, (i) => '$i');

        expect(
          () => repository.deleteAll(ids),
          throwsA(isA<DosProtectionException>()),
        );
      });
    });

    group('Rate Limit Status', () {
      test('возвращает текущий статус лимитов', () async {
        final entity = TestEntity(id: '1', name: 'Test');
        await repository.save(entity);

        final status = await repository.getRateLimitStatus();

        expect(status['global']['count'], greaterThan(0));
        expect(status['tenant']['count'], greaterThan(0));
        expect(status['user']['count'], greaterThan(0));
      });
    });

    group('All Operations', () {
      test('findById проходит rate limiting', () async {
        await repository.findById('1');
        await repository.findById('2');

        // Третий запрос должен быть заблокирован
        expect(
          () => repository.findById('3'),
          throwsA(isA<RateLimitExceededException>()),
        );
      });

      test('count проходит rate limiting', () async {
        await repository.count();
        await repository.count();

        expect(
          () => repository.count(),
          throwsA(isA<RateLimitExceededException>()),
        );
      });

      test('delete проходит rate limiting', () async {
        await repository.delete('1');
        await repository.delete('2');

        expect(
          () => repository.delete('3'),
          throwsA(isA<RateLimitExceededException>()),
        );
      });

      test('exists проходит rate limiting', () async {
        await repository.exists('1');
        await repository.exists('2');

        expect(
          () => repository.exists('3'),
          throwsA(isA<RateLimitExceededException>()),
        );
      });
    });
  });

  group('RateLimitedRepositoryFactory', () {
    test('создает rate-limited repository', () {
      final factory = RateLimitedRepositoryFactory(
        store: InMemoryRateLimitStore(),
      );

      final mockRepo = MockRepository<TestEntity>();
      final wrapped = factory.wrap(
        repository: mockRepo,
        tenantId: 'tenant1',
        userId: 'user1',
      );

      expect(wrapped, isA<RateLimitedRepository<TestEntity>>());
    });

    test('использует custom конфигурацию', () {
      final factory = RateLimitedRepositoryFactory(
        rateLimitConfig: RateLimitConfig.development(),
        dosConfig: DosConfig.development(),
        store: InMemoryRateLimitStore(),
      );

      expect(factory.rateLimiter.config.globalLimit, 100000);
      expect(factory.dosProtection.config.maxBatchSize, 10000);
    });
  });
}
