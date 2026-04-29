import 'audit_event.dart';
import 'audit_logger.dart';

/// Audit report types for compliance and security analysis
abstract class AuditReport {
  final DateTime generatedAt;
  final DateTime periodStart;
  final DateTime periodEnd;
  final int totalEvents;

  AuditReport({
    required this.generatedAt,
    required this.periodStart,
    required this.periodEnd,
    required this.totalEvents,
  });

  /// Generate report summary
  String summary();
}

/// Access report - who accessed what resources
class AccessReport extends AuditReport {
  final Map<String, List<ResourceAccess>> accessByActor;
  final Map<String, List<ActorAccess>> accessByResource;
  final int uniqueActors;
  final int uniqueResources;

  AccessReport({
    required super.generatedAt,
    required super.periodStart,
    required super.periodEnd,
    required super.totalEvents,
    required this.accessByActor,
    required this.accessByResource,
    required this.uniqueActors,
    required this.uniqueResources,
  });

  @override
  String summary() {
    return '''
Access Report (${periodStart.toIso8601String()} - ${periodEnd.toIso8601String()})
Total Events: $totalEvents
Unique Actors: $uniqueActors
Unique Resources: $uniqueResources
''';
  }

  /// Get top N most active actors
  List<String> getTopActors(int n) {
    final sorted = accessByActor.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return sorted.take(n).map((e) => e.key).toList();
  }

  /// Get top N most accessed resources
  List<String> getTopResources(int n) {
    final sorted = accessByResource.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return sorted.take(n).map((e) => e.key).toList();
  }
}

/// Change report - what changed and by whom
class ChangeReport extends AuditReport {
  final List<ChangeEvent> changes;
  final Map<String, int> changesByActor;
  final Map<String, int> changesByResource;
  final int creates;
  final int updates;
  final int deletes;

  ChangeReport({
    required super.generatedAt,
    required super.periodStart,
    required super.periodEnd,
    required super.totalEvents,
    required this.changes,
    required this.changesByActor,
    required this.changesByResource,
    required this.creates,
    required this.updates,
    required this.deletes,
  });

  @override
  String summary() {
    return '''
Change Report (${periodStart.toIso8601String()} - ${periodEnd.toIso8601String()})
Total Changes: $totalEvents
Creates: $creates
Updates: $updates
Deletes: $deletes
''';
  }
}

/// Failure report - failed access attempts and errors
class FailureReport extends AuditReport {
  final List<FailureEvent> failures;
  final Map<String, int> failuresByActor;
  final Map<String, int> failuresByResource;
  final Map<String, int> failuresByReason;
  final int authFailures;
  final int authzFailures;
  final int errors;

  FailureReport({
    required super.generatedAt,
    required super.periodStart,
    required super.periodEnd,
    required super.totalEvents,
    required this.failures,
    required this.failuresByActor,
    required this.failuresByResource,
    required this.failuresByReason,
    required this.authFailures,
    required this.authzFailures,
    required this.errors,
  });

  @override
  String summary() {
    return '''
Failure Report (${periodStart.toIso8601String()} - ${periodEnd.toIso8601String()})
Total Failures: $totalEvents
Auth Failures: $authFailures
Authz Failures: $authzFailures
Errors: $errors
''';
  }

  /// Get actors with most failures (potential attackers)
  List<String> getSuspiciousActors(int threshold) {
    return failuresByActor.entries
        .where((e) => e.value >= threshold)
        .map((e) => e.key)
        .toList();
  }
}

/// Anomaly report - unusual patterns and suspicious activity
class AnomalyReport extends AuditReport {
  final List<Anomaly> anomalies;
  final int highSeverity;
  final int mediumSeverity;
  final int lowSeverity;

  AnomalyReport({
    required super.generatedAt,
    required super.periodStart,
    required super.periodEnd,
    required super.totalEvents,
    required this.anomalies,
    required this.highSeverity,
    required this.mediumSeverity,
    required this.lowSeverity,
  });

  @override
  String summary() {
    return '''
Anomaly Report (${periodStart.toIso8601String()} - ${periodEnd.toIso8601String()})
Total Anomalies: ${anomalies.length}
High Severity: $highSeverity
Medium Severity: $mediumSeverity
Low Severity: $lowSeverity
''';
  }
}

// Supporting classes

class ResourceAccess {
  final String resource;
  final AuditAction action;
  final DateTime timestamp;
  final AuditResult result;

  ResourceAccess({
    required this.resource,
    required this.action,
    required this.timestamp,
    required this.result,
  });
}

class ActorAccess {
  final String actor;
  final AuditAction action;
  final DateTime timestamp;
  final AuditResult result;

  ActorAccess({
    required this.actor,
    required this.action,
    required this.timestamp,
    required this.result,
  });
}

class ChangeEvent {
  final String actor;
  final String resource;
  final AuditAction action;
  final DateTime timestamp;
  final Map<String, dynamic> metadata;

  ChangeEvent({
    required this.actor,
    required this.resource,
    required this.action,
    required this.timestamp,
    required this.metadata,
  });
}

class FailureEvent {
  final String actor;
  final String resource;
  final AuditAction action;
  final DateTime timestamp;
  final String? errorMessage;
  final String? ipAddress;

  FailureEvent({
    required this.actor,
    required this.resource,
    required this.action,
    required this.timestamp,
    this.errorMessage,
    this.ipAddress,
  });
}

class Anomaly {
  final String type;
  final String description;
  final AnomalySeverity severity;
  final List<AuditEvent> relatedEvents;
  final DateTime detectedAt;

  Anomaly({
    required this.type,
    required this.description,
    required this.severity,
    required this.relatedEvents,
    required this.detectedAt,
  });
}

enum AnomalySeverity {
  low,
  medium,
  high,
}
