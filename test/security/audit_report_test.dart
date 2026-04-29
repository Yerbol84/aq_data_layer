import 'package:test/test.dart';
import '../../lib/security/audit_event.dart';
import '../../lib/security/audit_logger.dart';
import '../../lib/security/audit_report.dart';
import '../../lib/security/audit_analyzer.dart';
import '../../lib/security/in_memory_audit_logger.dart';

void main() {
  group('AuditAnalyzer - AccessReport', () {
    late InMemoryAuditLogger logger;
    late AuditAnalyzer analyzer;

    setUp(() {
      logger = InMemoryAuditLogger();
      analyzer = AuditAnalyzer(logger: logger);
    });

    test('generateAccessReport подсчитывает уникальных акторов и ресурсы', () async {
      final now = DateTime.now();

      await logger.log(AuditEvent(
        id: 'evt_1',
        timestamp: now,
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      await logger.log(AuditEvent(
        id: 'evt_2',
        timestamp: now,
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:xyz',
        result: AuditResult.success,
      ));

      await logger.log(AuditEvent(
        id: 'evt_3',
        timestamp: now,
        actor: 'user:bob',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      final report = await analyzer.generateAccessReport(
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 1)),
      );

      expect(report.totalEvents, 3);
      expect(report.uniqueActors, 2); // alice, bob
      expect(report.uniqueResources, 2); // abc, xyz
      expect(report.accessByActor.length, 2);
      expect(report.accessByResource.length, 2);
    });

    test('getTopActors возвращает самых активных акторов', () async {
      final now = DateTime.now();

      // Alice: 3 accesses
      for (var i = 0; i < 3; i++) {
        await logger.log(AuditEvent(
          id: 'evt_alice_$i',
          timestamp: now,
          actor: 'user:alice',
          action: AuditAction.read,
          resource: 'project:$i',
          result: AuditResult.success,
        ));
      }

      // Bob: 1 access
      await logger.log(AuditEvent(
        id: 'evt_bob',
        timestamp: now,
        actor: 'user:bob',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      final report = await analyzer.generateAccessReport(
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 1)),
      );

      final topActors = report.getTopActors(2);
      expect(topActors.first, 'user:alice'); // Most active
    });

    test('getTopResources возвращает самые популярные ресурсы', () async {
      final now = DateTime.now();

      // project:abc: 3 accesses
      for (var i = 0; i < 3; i++) {
        await logger.log(AuditEvent(
          id: 'evt_$i',
          timestamp: now,
          actor: 'user:actor_$i',
          action: AuditAction.read,
          resource: 'project:abc',
          result: AuditResult.success,
        ));
      }

      // project:xyz: 1 access
      await logger.log(AuditEvent(
        id: 'evt_xyz',
        timestamp: now,
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:xyz',
        result: AuditResult.success,
      ));

      final report = await analyzer.generateAccessReport(
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 1)),
      );

      final topResources = report.getTopResources(2);
      expect(topResources.first, 'project:abc'); // Most accessed
    });
  });

  group('AuditAnalyzer - ChangeReport', () {
    late InMemoryAuditLogger logger;
    late AuditAnalyzer analyzer;

    setUp(() {
      logger = InMemoryAuditLogger();
      analyzer = AuditAnalyzer(logger: logger);
    });

    test('generateChangeReport подсчитывает типы изменений', () async {
      final now = DateTime.now();

      await logger.log(AuditEvent(
        id: 'evt_1',
        timestamp: now,
        actor: 'user:alice',
        action: AuditAction.create,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      await logger.log(AuditEvent(
        id: 'evt_2',
        timestamp: now,
        actor: 'user:alice',
        action: AuditAction.update,
        resource: 'project:abc',
        result: AuditResult.success,
      ));

      await logger.log(AuditEvent(
        id: 'evt_3',
        timestamp: now,
        actor: 'user:bob',
        action: AuditAction.delete,
        resource: 'project:xyz',
        result: AuditResult.success,
      ));

      // Read should not be counted
      await logger.log(AuditEvent(
        id: 'evt_4',
        timestamp: now,
        actor: 'user:charlie',
        action: AuditAction.read,
        resource: 'project:def',
        result: AuditResult.success,
      ));

      final report = await analyzer.generateChangeReport(
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 1)),
      );

      expect(report.totalEvents, 3); // Only changes
      expect(report.creates, 1);
      expect(report.updates, 1);
      expect(report.deletes, 1);
      expect(report.changesByActor['user:alice'], 2);
      expect(report.changesByActor['user:bob'], 1);
    });
  });

  group('AuditAnalyzer - FailureReport', () {
    late InMemoryAuditLogger logger;
    late AuditAnalyzer analyzer;

    setUp(() {
      logger = InMemoryAuditLogger();
      analyzer = AuditAnalyzer(logger: logger);
    });

    test('generateFailureReport подсчитывает типы ошибок', () async {
      final now = DateTime.now();

      // Auth failures
      await logger.log(AuditEvent(
        id: 'evt_1',
        timestamp: now,
        actor: 'user:alice',
        action: AuditAction.auth,
        resource: 'session:123',
        result: AuditResult.failure,
        errorMessage: 'Invalid password',
      ));

      await logger.log(AuditEvent(
        id: 'evt_2',
        timestamp: now,
        actor: 'user:alice',
        action: AuditAction.auth,
        resource: 'session:124',
        result: AuditResult.failure,
        errorMessage: 'Invalid password',
      ));

      // Authz failures
      await logger.log(AuditEvent(
        id: 'evt_3',
        timestamp: now,
        actor: 'user:bob',
        action: AuditAction.authz,
        resource: 'project:abc',
        result: AuditResult.denied,
        errorMessage: 'Access denied',
      ));

      // Errors
      await logger.log(AuditEvent(
        id: 'evt_4',
        timestamp: now,
        actor: 'system',
        action: AuditAction.update,
        resource: 'config',
        result: AuditResult.error,
        errorMessage: 'Database error',
      ));

      final report = await analyzer.generateFailureReport(
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 1)),
      );

      expect(report.totalEvents, 4);
      expect(report.authFailures, 2);
      expect(report.authzFailures, 1);
      expect(report.errors, 1);
      expect(report.failuresByActor['user:alice'], 2);
      expect(report.failuresByReason['Invalid password'], 2);
    });

    test('getSuspiciousActors возвращает акторов с множественными ошибками', () async {
      final now = DateTime.now();

      // Alice: 5 failures (suspicious)
      for (var i = 0; i < 5; i++) {
        await logger.log(AuditEvent(
          id: 'evt_alice_$i',
          timestamp: now,
          actor: 'user:alice',
          action: AuditAction.auth,
          resource: 'session:$i',
          result: AuditResult.failure,
        ));
      }

      // Bob: 2 failures (not suspicious)
      for (var i = 0; i < 2; i++) {
        await logger.log(AuditEvent(
          id: 'evt_bob_$i',
          timestamp: now,
          actor: 'user:bob',
          action: AuditAction.auth,
          resource: 'session:$i',
          result: AuditResult.failure,
        ));
      }

      final report = await analyzer.generateFailureReport(
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 1)),
      );

      final suspicious = report.getSuspiciousActors(5);
      expect(suspicious, contains('user:alice'));
      expect(suspicious, isNot(contains('user:bob')));
    });
  });

  group('AuditAnalyzer - AnomalyReport', () {
    late InMemoryAuditLogger logger;
    late AuditAnalyzer analyzer;

    setUp(() {
      logger = InMemoryAuditLogger();
      analyzer = AuditAnalyzer(logger: logger);
    });

    test('detectBruteForce обнаруживает атаки перебора', () async {
      final now = DateTime.now();

      // 5 failed auth attempts in 2 minutes (brute force)
      for (var i = 0; i < 5; i++) {
        await logger.log(AuditEvent(
          id: 'evt_$i',
          timestamp: now.add(Duration(seconds: i * 20)),
          actor: 'user:attacker',
          action: AuditAction.auth,
          resource: 'session:$i',
          result: AuditResult.failure,
        ));
      }

      final report = await analyzer.generateAnomalyReport(
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 1)),
      );

      expect(report.anomalies.length, greaterThan(0));
      final bruteForce = report.anomalies.firstWhere(
        (a) => a.type == 'brute_force',
        orElse: () => throw Exception('Brute force not detected'),
      );
      expect(bruteForce.severity, AnomalySeverity.high);
      expect(bruteForce.relatedEvents.length, 5);
    });

    test('detectPrivilegeEscalation обнаруживает попытки повышения привилегий', () async {
      final now = DateTime.now();

      await logger.log(AuditEvent(
        id: 'evt_1',
        timestamp: now,
        actor: 'user:alice',
        action: AuditAction.admin,
        resource: 'user:bob',
        result: AuditResult.denied,
      ));

      final report = await analyzer.generateAnomalyReport(
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 1)),
      );

      expect(report.anomalies.length, greaterThan(0));
      final privEsc = report.anomalies.firstWhere(
        (a) => a.type == 'privilege_escalation',
        orElse: () => throw Exception('Privilege escalation not detected'),
      );
      expect(privEsc.severity, AnomalySeverity.high);
    });

    test('detectOffHoursAccess обнаруживает доступ в нерабочее время', () async {
      final offHours = DateTime(2026, 4, 9, 2, 0); // 2 AM

      // 10 accesses at 2 AM (off-hours)
      for (var i = 0; i < 10; i++) {
        await logger.log(AuditEvent(
          id: 'evt_$i',
          timestamp: offHours.add(Duration(minutes: i)),
          actor: 'user:alice',
          action: AuditAction.read,
          resource: 'project:$i',
          result: AuditResult.success,
        ));
      }

      final report = await analyzer.generateAnomalyReport(
        from: offHours.subtract(const Duration(hours: 1)),
        to: offHours.add(const Duration(hours: 2)),
      );

      expect(report.anomalies.length, greaterThan(0));
      final offHoursAnomaly = report.anomalies.firstWhere(
        (a) => a.type == 'off_hours_access',
        orElse: () => throw Exception('Off-hours access not detected'),
      );
      expect(offHoursAnomaly.severity, AnomalySeverity.medium);
    });

    test('detectMassDeletion обнаруживает массовое удаление', () async {
      final now = DateTime.now();

      // 10 deletions in 30 seconds (mass deletion)
      for (var i = 0; i < 10; i++) {
        await logger.log(AuditEvent(
          id: 'evt_$i',
          timestamp: now.add(Duration(seconds: i * 3)),
          actor: 'user:alice',
          action: AuditAction.delete,
          resource: 'project:$i',
          result: AuditResult.success,
        ));
      }

      final report = await analyzer.generateAnomalyReport(
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 1)),
      );

      expect(report.anomalies.length, greaterThan(0));
      final massDeletion = report.anomalies.firstWhere(
        (a) => a.type == 'mass_deletion',
        orElse: () => throw Exception('Mass deletion not detected'),
      );
      expect(massDeletion.severity, AnomalySeverity.high);
    });

    test('подсчитывает аномалии по серьезности', () async {
      final now = DateTime.now();

      // High severity: brute force
      for (var i = 0; i < 5; i++) {
        await logger.log(AuditEvent(
          id: 'evt_brute_$i',
          timestamp: now.add(Duration(seconds: i * 20)),
          actor: 'user:attacker',
          action: AuditAction.auth,
          resource: 'session:$i',
          result: AuditResult.failure,
        ));
      }

      // High severity: privilege escalation
      await logger.log(AuditEvent(
        id: 'evt_priv',
        timestamp: now,
        actor: 'user:alice',
        action: AuditAction.admin,
        resource: 'user:bob',
        result: AuditResult.denied,
      ));

      final report = await analyzer.generateAnomalyReport(
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 1)),
      );

      expect(report.highSeverity, greaterThanOrEqualTo(2));
    });
  });

  group('AuditReport - Summary', () {
    test('AccessReport.summary возвращает читаемое представление', () {
      final report = AccessReport(
        generatedAt: DateTime.now(),
        periodStart: DateTime(2026, 4, 9, 0, 0),
        periodEnd: DateTime(2026, 4, 9, 23, 59),
        totalEvents: 100,
        accessByActor: {},
        accessByResource: {},
        uniqueActors: 10,
        uniqueResources: 20,
      );

      final summary = report.summary();
      expect(summary, contains('Access Report'));
      expect(summary, contains('Total Events: 100'));
      expect(summary, contains('Unique Actors: 10'));
      expect(summary, contains('Unique Resources: 20'));
    });

    test('ChangeReport.summary возвращает читаемое представление', () {
      final report = ChangeReport(
        generatedAt: DateTime.now(),
        periodStart: DateTime(2026, 4, 9, 0, 0),
        periodEnd: DateTime(2026, 4, 9, 23, 59),
        totalEvents: 50,
        changes: [],
        changesByActor: {},
        changesByResource: {},
        creates: 10,
        updates: 30,
        deletes: 10,
      );

      final summary = report.summary();
      expect(summary, contains('Change Report'));
      expect(summary, contains('Total Changes: 50'));
      expect(summary, contains('Creates: 10'));
      expect(summary, contains('Updates: 30'));
      expect(summary, contains('Deletes: 10'));
    });

    test('FailureReport.summary возвращает читаемое представление', () {
      final report = FailureReport(
        generatedAt: DateTime.now(),
        periodStart: DateTime(2026, 4, 9, 0, 0),
        periodEnd: DateTime(2026, 4, 9, 23, 59),
        totalEvents: 25,
        failures: [],
        failuresByActor: {},
        failuresByResource: {},
        failuresByReason: {},
        authFailures: 15,
        authzFailures: 5,
        errors: 5,
      );

      final summary = report.summary();
      expect(summary, contains('Failure Report'));
      expect(summary, contains('Total Failures: 25'));
      expect(summary, contains('Auth Failures: 15'));
      expect(summary, contains('Authz Failures: 5'));
      expect(summary, contains('Errors: 5'));
    });

    test('AnomalyReport.summary возвращает читаемое представление', () {
      final report = AnomalyReport(
        generatedAt: DateTime.now(),
        periodStart: DateTime(2026, 4, 9, 0, 0),
        periodEnd: DateTime(2026, 4, 9, 23, 59),
        totalEvents: 1000,
        anomalies: [],
        highSeverity: 5,
        mediumSeverity: 10,
        lowSeverity: 15,
      );

      final summary = report.summary();
      expect(summary, contains('Anomaly Report'));
      expect(summary, contains('Total Anomalies: 0'));
      expect(summary, contains('High Severity: 5'));
      expect(summary, contains('Medium Severity: 10'));
      expect(summary, contains('Low Severity: 15'));
    });
  });
}
