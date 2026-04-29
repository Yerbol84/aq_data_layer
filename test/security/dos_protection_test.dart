import 'package:test/test.dart';
import '../../lib/security/dos_config.dart';
import '../../lib/security/dos_protection.dart';

void main() {
  group('DosProtection', () {
    late DosProtection protection;

    setUp(() {
      protection = DosProtection(
        config: const DosConfig(
          maxBatchSize: 100,
          maxQueryLimit: 1000,
          maxQueryComplexity: 500,
          maxMemoryPerQuery: 10 * 1024 * 1024, // 10 MB
          maxQueryTimeoutSeconds: 30,
        ),
      );
    });

    group('Batch Size Validation', () {
      test('разрешает batch в пределах лимита', () {
        expect(() => protection.validateBatchSize(50), returnsNormally);
        expect(() => protection.validateBatchSize(100), returnsNormally);
      });

      test('блокирует oversized batch', () {
        expect(
          () => protection.validateBatchSize(101),
          throwsA(isA<DosProtectionException>()),
        );
      });

      test('выбрасывает исключение с правильными данными', () {
        try {
          protection.validateBatchSize(200);
          fail('Should throw exception');
        } catch (e) {
          expect(e, isA<DosProtectionException>());
          final ex = e as DosProtectionException;
          expect(ex.violationType, 'batch_size');
          expect(ex.limit, 100);
          expect(ex.actual, 200);
        }
      });
    });

    group('Query Limit Validation', () {
      test('разрешает query limit в пределах', () {
        expect(() => protection.validateQueryLimit(500), returnsNormally);
        expect(() => protection.validateQueryLimit(1000), returnsNormally);
      });

      test('блокирует слишком большой limit', () {
        expect(
          () => protection.validateQueryLimit(1001),
          throwsA(isA<DosProtectionException>()),
        );
      });

      test('разрешает null limit', () {
        expect(() => protection.validateQueryLimit(null), returnsNormally);
      });
    });

    group('Pagination Validation', () {
      test('требует limit для findAll', () {
        expect(
          () => protection.validatePagination(limit: null),
          throwsA(isA<DosProtectionException>()),
        );
      });

      test('разрешает pagination с limit', () {
        expect(
          () => protection.validatePagination(limit: 100, offset: 0),
          returnsNormally,
        );
      });

      test('проверяет limit в pagination', () {
        expect(
          () => protection.validatePagination(limit: 2000),
          throwsA(isA<DosProtectionException>()),
        );
      });
    });

    group('Query Complexity', () {
      test('вычисляет complexity для простого запроса', () {
        final complexity = protection.estimateQueryComplexity(
          conditions: 2,
          resultLimit: 100,
        );
        expect(complexity, 21); // 2*10 + 100/100
      });

      test('вычисляет complexity для сложного запроса', () {
        final complexity = protection.estimateQueryComplexity(
          conditions: 5,
          orConditions: 2,
          inConditions: 1,
          inListSize: 10,
          likeConditions: 3,
          resultLimit: 1000,
        );
        // 5*10 + 2*20 + 1*5*10 + 3*15 + 1000/100 = 50 + 40 + 50 + 45 + 10 = 195
        expect(complexity, 195);
      });

      test('блокирует слишком сложные запросы', () {
        final complexity = protection.estimateQueryComplexity(
          conditions: 100,
        );
        expect(
          () => protection.validateQueryComplexity(complexity),
          throwsA(isA<DosProtectionException>()),
        );
      });

      test('разрешает запросы в пределах complexity', () {
        final complexity = protection.estimateQueryComplexity(
          conditions: 10,
          resultLimit: 100,
        );
        expect(
          () => protection.validateQueryComplexity(complexity),
          returnsNormally,
        );
      });
    });

    group('Memory Usage', () {
      test('вычисляет memory usage', () {
        final memory = protection.estimateMemoryUsage(
          resultCount: 1000,
          avgEntitySizeBytes: 1024,
        );
        expect(memory, 1024 * 1000); // ~1 MB
      });

      test('блокирует запросы с большим memory usage', () {
        final memory = protection.estimateMemoryUsage(
          resultCount: 100000,
          avgEntitySizeBytes: 1024,
        );
        expect(
          () => protection.validateMemoryUsage(memory),
          throwsA(isA<DosProtectionException>()),
        );
      });

      test('разрешает запросы с разумным memory usage', () {
        final memory = protection.estimateMemoryUsage(
          resultCount: 1000,
          avgEntitySizeBytes: 1024,
        );
        expect(
          () => protection.validateMemoryUsage(memory),
          returnsNormally,
        );
      });
    });

    group('Timeout Validation', () {
      test('разрешает timeout в пределах', () {
        expect(
          () => protection.validateTimeout(const Duration(seconds: 10)),
          returnsNormally,
        );
      });

      test('блокирует слишком большой timeout', () {
        expect(
          () => protection.validateTimeout(const Duration(seconds: 60)),
          throwsA(isA<DosProtectionException>()),
        );
      });

      test('разрешает null timeout', () {
        expect(
          () => protection.validateTimeout(null),
          returnsNormally,
        );
      });
    });

    group('Combined Safety Check', () {
      test('проверяет все параметры', () {
        expect(
          () => protection.isSafe(
            batchSize: 50,
            queryLimit: 500,
            queryComplexity: 100,
            memoryUsage: 1024 * 1024,
            timeout: const Duration(seconds: 10),
          ),
          returnsNormally,
        );
      });

      test('выбрасывает исключение при любом нарушении', () {
        expect(
          () => protection.isSafe(
            batchSize: 200, // Exceeds limit
            queryLimit: 500,
          ),
          throwsA(isA<DosProtectionException>()),
        );
      });
    });
  });

  group('DosConfig', () {
    test('создает development конфигурацию', () {
      final config = DosConfig.development();
      expect(config.maxBatchSize, 10000);
      expect(config.maxQueryLimit, 100000);
    });

    test('создает production конфигурацию', () {
      final config = DosConfig.production();
      expect(config.maxBatchSize, 1000);
      expect(config.maxQueryLimit, 10000);
    });
  });
}
