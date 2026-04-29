import 'package:test/test.dart';
import '../../lib/security/audit_event.dart';

void main() {
  group('AuditEvent', () {
    test('создает событие с обязательными полями', () {
      final event = AuditEvent(
        id: 'evt_123',
        timestamp: DateTime(2026, 4, 9, 12, 0, 0),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      );

      expect(event.id, 'evt_123');
      expect(event.actor, 'user:alice');
      expect(event.action, AuditAction.read);
      expect(event.resource, 'project:abc');
      expect(event.result, AuditResult.success);
      expect(event.severity, AuditSeverity.info); // default
    });

    test('создает событие со всеми полями', () {
      final event = AuditEvent(
        id: 'evt_456',
        timestamp: DateTime(2026, 4, 9, 12, 0, 0),
        actor: 'user:bob',
        action: AuditAction.delete,
        resource: 'user:charlie',
        result: AuditResult.failure,
        severity: AuditSeverity.critical,
        ipAddress: '192.168.1.100',
        userAgent: 'Mozilla/5.0',
        metadata: {'reason': 'unauthorized'},
        errorMessage: 'Access denied',
      );

      expect(event.severity, AuditSeverity.critical);
      expect(event.ipAddress, '192.168.1.100');
      expect(event.userAgent, 'Mozilla/5.0');
      expect(event.metadata['reason'], 'unauthorized');
      expect(event.errorMessage, 'Access denied');
    });

    test('toJson сериализует событие', () {
      final event = AuditEvent(
        id: 'evt_789',
        timestamp: DateTime(2026, 4, 9, 12, 0, 0),
        actor: 'system',
        action: AuditAction.rotate,
        resource: 'secret:db_password',
        result: AuditResult.success,
        severity: AuditSeverity.info,
        metadata: {'old_version': '1', 'new_version': '2'},
      );

      final json = event.toJson();

      expect(json['id'], 'evt_789');
      expect(json['actor'], 'system');
      expect(json['action'], 'rotate');
      expect(json['resource'], 'secret:db_password');
      expect(json['result'], 'success');
      expect(json['severity'], 'info');
      expect(json['metadata']['old_version'], '1');
    });

    test('fromJson десериализует событие', () {
      final json = {
        'id': 'evt_abc',
        'timestamp': '2026-04-09T12:00:00.000',
        'actor': 'user:dave',
        'action': 'create',
        'resource': 'project:xyz',
        'result': 'success',
        'severity': 'info',
        'metadata': {'name': 'New Project'},
      };

      final event = AuditEvent.fromJson(json);

      expect(event.id, 'evt_abc');
      expect(event.actor, 'user:dave');
      expect(event.action, AuditAction.create);
      expect(event.resource, 'project:xyz');
      expect(event.result, AuditResult.success);
      expect(event.metadata['name'], 'New Project');
    });

    test('fromJson обрабатывает опциональные поля', () {
      final json = {
        'id': 'evt_def',
        'timestamp': '2026-04-09T12:00:00.000',
        'actor': 'user:eve',
        'action': 'auth',
        'resource': 'session:123',
        'result': 'failure',
        'ip_address': '10.0.0.1',
        'user_agent': 'curl/7.0',
        'error_message': 'Invalid credentials',
      };

      final event = AuditEvent.fromJson(json);

      expect(event.ipAddress, '10.0.0.1');
      expect(event.userAgent, 'curl/7.0');
      expect(event.errorMessage, 'Invalid credentials');
      expect(event.severity, AuditSeverity.info); // default
    });

    test('события с одинаковым ID равны', () {
      final event1 = AuditEvent(
        id: 'evt_same',
        timestamp: DateTime(2026, 4, 9, 12, 0, 0),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      );

      final event2 = AuditEvent(
        id: 'evt_same',
        timestamp: DateTime(2026, 4, 9, 13, 0, 0), // different time
        actor: 'user:bob', // different actor
        action: AuditAction.update, // different action
        resource: 'project:xyz', // different resource
        result: AuditResult.failure, // different result
      );

      expect(event1, equals(event2));
      expect(event1.hashCode, equals(event2.hashCode));
    });

    test('события с разными ID не равны', () {
      final event1 = AuditEvent(
        id: 'evt_1',
        timestamp: DateTime(2026, 4, 9, 12, 0, 0),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      );

      final event2 = AuditEvent(
        id: 'evt_2',
        timestamp: DateTime(2026, 4, 9, 12, 0, 0),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      );

      expect(event1, isNot(equals(event2)));
    });

    test('toString возвращает читаемое представление', () {
      final event = AuditEvent(
        id: 'evt_str',
        timestamp: DateTime(2026, 4, 9, 12, 0, 0),
        actor: 'user:alice',
        action: AuditAction.read,
        resource: 'project:abc',
        result: AuditResult.success,
      );

      final str = event.toString();

      expect(str, contains('user:alice'));
      expect(str, contains('read'));
      expect(str, contains('project:abc'));
      expect(str, contains('success'));
    });

    test('timestamp имеет микросекундную точность', () {
      final now = DateTime.now();
      final event = AuditEvent(
        id: 'evt_micro',
        timestamp: now,
        actor: 'system',
        action: AuditAction.admin,
        resource: 'config',
        result: AuditResult.success,
      );

      expect(event.timestamp.microsecond, equals(now.microsecond));
    });
  });

  group('AuditAction', () {
    test('содержит все необходимые действия', () {
      expect(AuditAction.values, contains(AuditAction.create));
      expect(AuditAction.values, contains(AuditAction.read));
      expect(AuditAction.values, contains(AuditAction.update));
      expect(AuditAction.values, contains(AuditAction.delete));
      expect(AuditAction.values, contains(AuditAction.auth));
      expect(AuditAction.values, contains(AuditAction.authz));
      expect(AuditAction.values, contains(AuditAction.admin));
      expect(AuditAction.values, contains(AuditAction.secret));
      expect(AuditAction.values, contains(AuditAction.rotate));
      expect(AuditAction.values, contains(AuditAction.export));
      expect(AuditAction.values, contains(AuditAction.import_));
    });
  });

  group('AuditResult', () {
    test('содержит все результаты', () {
      expect(AuditResult.values, contains(AuditResult.success));
      expect(AuditResult.values, contains(AuditResult.failure));
      expect(AuditResult.values, contains(AuditResult.error));
      expect(AuditResult.values, contains(AuditResult.denied));
    });
  });

  group('AuditSeverity', () {
    test('содержит все уровни серьезности', () {
      expect(AuditSeverity.values, contains(AuditSeverity.info));
      expect(AuditSeverity.values, contains(AuditSeverity.warning));
      expect(AuditSeverity.values, contains(AuditSeverity.critical));
    });
  });
}
