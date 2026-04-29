import 'package:test/test.dart';
import '../../lib/security/audit_event.dart';
import '../../lib/security/audit_logger.dart';
import '../../lib/security/in_memory_audit_logger.dart';

void main() {
  group('InMemoryAuditLogger', () {
    late InMemoryAuditLogger logger;

    setUp(() {
      logger = InMemoryAuditLogger();
    });

    test('логирует событие', () async {
      final event = AuditEvent(
        id: 'evt_1',
        timestamp: DateTime.now(),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      );

      await logger.log(event);

      expect(logger.eventCount, 1);
      expect(logger.events.first, equals(event));
    });

    test('генерирует ID если не указан', () async {
      final event = AuditEvent(
        id: '',
        timestamp: DateTime.now(),
        actor: 'user:bob',
        action: AuditAction.create,
        resource: 'project:xyz',
        result: AuditResult.success,
      );

      await logger.log(event);

      expect(logger.eventCount, 1);
      expect(logger.events.first.id, isNotEmpty);
      expect(logger.events.first.id, isNot(''));
    });

    test('query возвращает все события без фильтра', () async {
      await logger.log(AuditEvent(
        id: 'evt_1',
        timestamp: DateTime.now(),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      await logger.log(AuditEvent(
        id: 'evt_2',
        timestamp: DateTime.now(),
        actor: 'user:bob',
        action: AuditAction.update,
        resource: 'project:xyz',
        result: AuditResult.success,
      ));

      final results = await logger.query(const AuditFilter());

      expect(results.length, 2);
    });

    test('query фильтрует по actor', () async {
      await logger.log(AuditEvent(
        id: 'evt_1',
        timestamp: DateTime.now(),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      await logger.log(AuditEvent(
        id: 'evt_2',
        timestamp: DateTime.now(),
        actor: 'user:bob',
        action: AuditAction.read,
        resource: 'project:xyz',
        result: AuditResult.success,
      ));

      final results = await logger.query(AuditFilter.actor('user:alice'));

      expect(results.length, 1);
      expect(results.first.actor, 'user:alice');
    });

    test('query фильтрует по временному диапазону', () async {
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      final tomorrow = now.add(const Duration(days: 1));

      await logger.log(AuditEvent(
        id: 'evt_old',
        timestamp: yesterday,
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      await logger.log(AuditEvent(
        id: 'evt_new',
        timestamp: now,
        actor: 'user:bob',
        action: AuditAction.read,
        resource: 'project:xyz',
        result: AuditResult.success,
      ));

      final results = await logger.query(AuditFilter.timeRange(
        from: yesterday.subtract(const Duration(hours: 1)),
        to: yesterday.add(const Duration(hours: 1)),
      ));

      expect(results.length, 1);
      expect(results.first.id, 'evt_old');
    });

    test('query сортирует по timestamp descending', () async {
      final now = DateTime.now();

      await logger.log(AuditEvent(
        id: 'evt_1',
        timestamp: now.subtract(const Duration(seconds: 2)),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      await logger.log(AuditEvent(
        id: 'evt_2',
        timestamp: now,
        actor: 'user:bob',
        action: AuditAction.read,
        resource: 'project:xyz',
        result: AuditResult.success,
      ));

      await logger.log(AuditEvent(
        id: 'evt_3',
        timestamp: now.subtract(const Duration(seconds: 1)),
        actor: 'user:charlie',
        action: AuditAction.read,
        resource: 'project:def',
        result: AuditResult.success,
      ));

      final results = await logger.query(const AuditFilter());

      expect(results[0].id, 'evt_2'); // newest
      expect(results[1].id, 'evt_3');
      expect(results[2].id, 'evt_1'); // oldest
    });

    test('query применяет limit', () async {
      for (var i = 0; i < 10; i++) {
        await logger.log(AuditEvent(
          id: 'evt_$i',
          timestamp: DateTime.now(),
          actor: 'user:alice',
          action: AuditAction.read,
          resource: 'project:$i',
          result: AuditResult.success,
        ));
      }

      final results = await logger.query(const AuditFilter(limit: 5));

      expect(results.length, 5);
    });

    test('query применяет offset', () async {
      for (var i = 0; i < 10; i++) {
        await logger.log(AuditEvent(
          id: 'evt_$i',
          timestamp: DateTime.now().add(Duration(seconds: i)),
          actor: 'user:alice',
          action: AuditAction.read,
          resource: 'project:$i',
          result: AuditResult.success,
        ));
      }

      final results = await logger.query(const AuditFilter(offset: 5, limit: 3));

      expect(results.length, 3);
    });

    test('count возвращает количество событий', () async {
      await logger.log(AuditEvent(
        id: 'evt_1',
        timestamp: DateTime.now(),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      await logger.log(AuditEvent(
        id: 'evt_2',
        timestamp: DateTime.now(),
        actor: 'user:alice',
        action: AuditAction.update,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      final count = await logger.count(AuditFilter.actor('user:alice'));

      expect(count, 2);
    });

    test('getByActor возвращает события актора', () async {
      await logger.log(AuditEvent(
        id: 'evt_1',
        timestamp: DateTime.now(),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      await logger.log(AuditEvent(
        id: 'evt_2',
        timestamp: DateTime.now(),
        actor: 'user:bob',
        action: AuditAction.read,
        resource: 'project:xyz',
        result: AuditResult.success,
      ));

      final results = await logger.getByActor('user:alice');

      expect(results.length, 1);
      expect(results.first.actor, 'user:alice');
    });

    test('getByResource возвращает события ресурса', () async {
      await logger.log(AuditEvent(
        id: 'evt_1',
        timestamp: DateTime.now(),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      await logger.log(AuditEvent(
        id: 'evt_2',
        timestamp: DateTime.now(),
        actor: 'user:bob',
        action: AuditAction.update,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      final results = await logger.getByResource('project:abc');

      expect(results.length, 2);
      expect(results.every((e) => e.resource == 'project:abc'), isTrue);
    });

    test('getFailedAttempts возвращает только неудачные попытки', () async {
      await logger.log(AuditEvent(
        id: 'evt_1',
        timestamp: DateTime.now(),
        actor: 'user:alice',
        action: AuditAction.auth,
        resource: 'session:123',
        result: AuditResult.success,
      ));

      await logger.log(AuditEvent(
        id: 'evt_2',
        timestamp: DateTime.now(),
        actor: 'user:bob',
        action: AuditAction.auth,
        resource: 'session:456',
        result: AuditResult.failure,
      ));

      await logger.log(AuditEvent(
        id: 'evt_3',
        timestamp: DateTime.now(),
        actor: 'user:charlie',
        action: AuditAction.auth,
        resource: 'session:789',
        result: AuditResult.failure,
      ));

      final results = await logger.getFailedAttempts();

      expect(results.length, 2);
      expect(results.every((e) => e.result == AuditResult.failure), isTrue);
    });

    test('getCriticalEvents возвращает только критические события', () async {
      await logger.log(AuditEvent(
        id: 'evt_1',
        timestamp: DateTime.now(),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
        severity: AuditSeverity.info,
      ));

      await logger.log(AuditEvent(
        id: 'evt_2',
        timestamp: DateTime.now(),
        actor: 'user:bob',
        action: AuditAction.delete,
        resource: 'user:charlie',
        result: AuditResult.success,
        severity: AuditSeverity.critical,
      ));

      final results = await logger.getCriticalEvents();

      expect(results.length, 1);
      expect(results.first.severity, AuditSeverity.critical);
    });

    test('clear удаляет все события', () async {
      await logger.log(AuditEvent(
        id: 'evt_1',
        timestamp: DateTime.now(),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      expect(logger.eventCount, 1);

      await logger.clear();

      expect(logger.eventCount, 0);
    });
  });

  group('AuditFilter', () {
    test('matches проверяет соответствие события', () {
      final filter = AuditFilter(
        actor: 'user:alice',
        action: AuditAction.read,
        result: AuditResult.success,
      );

      final matchingEvent = AuditEvent(
        id: 'evt_1',
        timestamp: DateTime.now(),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      );

      final nonMatchingEvent = AuditEvent(
        id: 'evt_2',
        timestamp: DateTime.now(),
        actor: 'user:bob',
        action: AuditAction.read,
        resource: 'project:xyz',
        result: AuditResult.success,
      );

      expect(filter.matches(matchingEvent), isTrue);
      expect(filter.matches(nonMatchingEvent), isFalse);
    });

    test('toString возвращает читаемое представление', () {
      final filter = AuditFilter(
        actor: 'user:alice',
        action: AuditAction.read,
        limit: 10,
      );

      final str = filter.toString();

      expect(str, contains('user:alice'));
      expect(str, contains('read'));
      expect(str, contains('limit: 10'));
    });
  });
}
