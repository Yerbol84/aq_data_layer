import 'package:test/test.dart';
import '../../lib/security/audit_event.dart';
import '../../lib/security/audit_retention.dart';
import '../../lib/security/in_memory_audit_logger.dart';

void main() {
  group('RetentionPolicy', () {
    test('default policy имеет правильные значения', () {
      const policy = RetentionPolicy();

      expect(policy.normalRetention, const Duration(days: 90));
      expect(policy.criticalRetention, const Duration(days: 365));
      expect(policy.authRetention, const Duration(days: 180));
      expect(policy.archiveBeforeDelete, isTrue);
    });

    test('SOC 2 policy соответствует стандарту', () {
      final policy = RetentionPolicy.soc2();

      expect(policy.normalRetention, const Duration(days: 365));
      expect(policy.criticalRetention, const Duration(days: 730));
      expect(policy.authRetention, const Duration(days: 365));
      expect(policy.archiveBeforeDelete, isTrue);
    });

    test('PCI DSS policy соответствует стандарту', () {
      final policy = RetentionPolicy.pciDss();

      expect(policy.normalRetention, const Duration(days: 90));
      expect(policy.criticalRetention, const Duration(days: 365));
      expect(policy.authRetention, const Duration(days: 90));
      expect(policy.archiveBeforeDelete, isTrue);
    });

    test('GDPR policy минимизирует хранение', () {
      final policy = RetentionPolicy.gdpr();

      expect(policy.normalRetention, const Duration(days: 30));
      expect(policy.criticalRetention, const Duration(days: 90));
      expect(policy.authRetention, const Duration(days: 60));
      expect(policy.archiveBeforeDelete, isFalse);
    });

    test('getRetentionFor возвращает правильный период для критических событий', () {
      const policy = RetentionPolicy();

      final criticalEvent = AuditEvent(
        id: 'evt_1',
        timestamp: DateTime.now(),
        actor: 'user:alice',
        action: AuditAction.delete,
        resource: 'user:bob',
        result: AuditResult.success,
        severity: AuditSeverity.critical,
      );

      expect(policy.getRetentionFor(criticalEvent), const Duration(days: 365));
    });

    test('getRetentionFor возвращает правильный период для auth событий', () {
      const policy = RetentionPolicy();

      final authEvent = AuditEvent(
        id: 'evt_2',
        timestamp: DateTime.now(),
        actor: 'user:alice',
        action: AuditAction.auth,
        resource: 'session:123',
        result: AuditResult.success,
      );

      expect(policy.getRetentionFor(authEvent), const Duration(days: 180));
    });

    test('getRetentionFor возвращает правильный период для обычных событий', () {
      const policy = RetentionPolicy();

      final normalEvent = AuditEvent(
        id: 'evt_3',
        timestamp: DateTime.now(),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      );

      expect(policy.getRetentionFor(normalEvent), const Duration(days: 90));
    });

    test('shouldRetain возвращает true для свежих событий', () {
      const policy = RetentionPolicy();
      final now = DateTime.now();

      final recentEvent = AuditEvent(
        id: 'evt_4',
        timestamp: now.subtract(const Duration(days: 30)),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      );

      expect(policy.shouldRetain(recentEvent, now), isTrue);
    });

    test('shouldRetain возвращает false для старых событий', () {
      const policy = RetentionPolicy();
      final now = DateTime.now();

      final oldEvent = AuditEvent(
        id: 'evt_5',
        timestamp: now.subtract(const Duration(days: 100)),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      );

      expect(policy.shouldRetain(oldEvent, now), isFalse);
    });

    test('shouldArchive возвращает true для старых событий с archiveBeforeDelete', () {
      const policy = RetentionPolicy(archiveBeforeDelete: true);
      final now = DateTime.now();

      final oldEvent = AuditEvent(
        id: 'evt_6',
        timestamp: now.subtract(const Duration(days: 100)),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      );

      expect(policy.shouldArchive(oldEvent, now), isTrue);
    });

    test('shouldArchive возвращает false без archiveBeforeDelete', () {
      const policy = RetentionPolicy(archiveBeforeDelete: false);
      final now = DateTime.now();

      final oldEvent = AuditEvent(
        id: 'evt_7',
        timestamp: now.subtract(const Duration(days: 100)),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      );

      expect(policy.shouldArchive(oldEvent, now), isFalse);
    });
  });

  group('AuditRetentionService', () {
    late InMemoryAuditLogger logger;
    late AuditRetentionService service;

    setUp(() {
      logger = InMemoryAuditLogger();
      service = AuditRetentionService(
        logger: logger,
        policy: const RetentionPolicy(
          normalRetention: Duration(days: 30),
          archiveBeforeDelete: true,
        ),
      );
    });

    test('applyRetention обрабатывает события', () async {
      final now = DateTime.now();

      // Recent event - should be retained
      await logger.log(AuditEvent(
        id: 'evt_recent',
        timestamp: now.subtract(const Duration(days: 10)),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      // Old event - should be archived and deleted
      await logger.log(AuditEvent(
        id: 'evt_old',
        timestamp: now.subtract(const Duration(days: 40)),
        actor: 'user:bob',
        action: AuditAction.read,
        resource: 'project:xyz',
        result: AuditResult.success,
      ));

      final report = await service.applyRetention();

      expect(report.retained.length, 1);
      expect(report.retained, contains('evt_recent'));
      expect(report.archived.length, 1);
      expect(report.archived, contains('evt_old'));
      expect(report.deleted.length, 1);
      expect(report.deleted, contains('evt_old'));
    });

    test('getRetentionStatus возвращает статус всех событий', () async {
      final now = DateTime.now();

      await logger.log(AuditEvent(
        id: 'evt_1',
        timestamp: now.subtract(const Duration(days: 10)),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      await logger.log(AuditEvent(
        id: 'evt_2',
        timestamp: now.subtract(const Duration(days: 40)),
        actor: 'user:bob',
        action: AuditAction.read,
        resource: 'project:xyz',
        result: AuditResult.success,
      ));

      final statuses = await service.getRetentionStatus();

      expect(statuses.length, 2);
      expect(statuses[0].shouldRetain, isTrue);
      expect(statuses[1].shouldRetain, isFalse);
    });
  });

  group('RetentionReport', () {
    test('total возвращает сумму всех событий', () {
      final report = RetentionReport();
      report.retained.add('evt_1');
      report.archived.add('evt_2');
      report.deleted.add('evt_3');
      report.failed['evt_4'] = 'error';

      expect(report.total, 4);
    });

    test('hasFailures возвращает true при наличии ошибок', () {
      final report = RetentionReport();
      report.failed['evt_1'] = 'error';

      expect(report.hasFailures, isTrue);
    });

    test('toString возвращает читаемое представление', () {
      final report = RetentionReport();
      report.retained.add('evt_1');
      report.archived.add('evt_2');

      final str = report.toString();

      expect(str, contains('retained: 1'));
      expect(str, contains('archived: 1'));
    });
  });

  group('RetentionStatus', () {
    test('toString возвращает читаемое представление', () {
      final status = RetentionStatus(
        eventId: 'evt_1',
        timestamp: DateTime.now(),
        expiryDate: DateTime.now().add(const Duration(days: 30)),
        daysUntilExpiry: 30,
        shouldRetain: true,
        shouldArchive: false,
        shouldDelete: false,
      );

      final str = status.toString();

      expect(str, contains('evt_1'));
      expect(str, contains('30 days'));
      expect(str, contains('retain: true'));
    });
  });
}
