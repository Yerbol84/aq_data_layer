import 'audit_event.dart';
import 'audit_logger.dart';
import 'audit_report.dart';

/// Analyzer for detecting patterns and anomalies in audit logs
class AuditAnalyzer {
  final AuditLogger logger;

  AuditAnalyzer({required this.logger});

  /// Generate access report for a time period
  Future<AccessReport> generateAccessReport({
    required DateTime from,
    required DateTime to,
  }) async {
    final events = await logger.query(AuditFilter(from: from, to: to));

    final accessByActor = <String, List<ResourceAccess>>{};
    final accessByResource = <String, List<ActorAccess>>{};
    final uniqueActors = <String>{};
    final uniqueResources = <String>{};

    for (final event in events) {
      uniqueActors.add(event.actor);
      uniqueResources.add(event.resource);

      // Group by actor
      accessByActor.putIfAbsent(event.actor, () => []).add(ResourceAccess(
            resource: event.resource,
            action: event.action,
            timestamp: event.timestamp,
            result: event.result,
          ));

      // Group by resource
      accessByResource.putIfAbsent(event.resource, () => []).add(ActorAccess(
            actor: event.actor,
            action: event.action,
            timestamp: event.timestamp,
            result: event.result,
          ));
    }

    return AccessReport(
      generatedAt: DateTime.now(),
      periodStart: from,
      periodEnd: to,
      totalEvents: events.length,
      accessByActor: accessByActor,
      accessByResource: accessByResource,
      uniqueActors: uniqueActors.length,
      uniqueResources: uniqueResources.length,
    );
  }

  /// Generate change report for a time period
  Future<ChangeReport> generateChangeReport({
    required DateTime from,
    required DateTime to,
  }) async {
    final events = await logger.query(AuditFilter(from: from, to: to));

    final changes = <ChangeEvent>[];
    final changesByActor = <String, int>{};
    final changesByResource = <String, int>{};
    var creates = 0;
    var updates = 0;
    var deletes = 0;

    for (final event in events) {
      if (event.action == AuditAction.create ||
          event.action == AuditAction.update ||
          event.action == AuditAction.delete) {
        changes.add(ChangeEvent(
          actor: event.actor,
          resource: event.resource,
          action: event.action,
          timestamp: event.timestamp,
          metadata: event.metadata,
        ));

        changesByActor[event.actor] = (changesByActor[event.actor] ?? 0) + 1;
        changesByResource[event.resource] =
            (changesByResource[event.resource] ?? 0) + 1;

        if (event.action == AuditAction.create) creates++;
        if (event.action == AuditAction.update) updates++;
        if (event.action == AuditAction.delete) deletes++;
      }
    }

    return ChangeReport(
      generatedAt: DateTime.now(),
      periodStart: from,
      periodEnd: to,
      totalEvents: changes.length,
      changes: changes,
      changesByActor: changesByActor,
      changesByResource: changesByResource,
      creates: creates,
      updates: updates,
      deletes: deletes,
    );
  }

  /// Generate failure report for a time period
  Future<FailureReport> generateFailureReport({
    required DateTime from,
    required DateTime to,
  }) async {
    final events = await logger.query(AuditFilter(
      from: from,
      to: to,
      result: AuditResult.failure,
    ));

    // Also get errors
    final errorEvents = await logger.query(AuditFilter(
      from: from,
      to: to,
      result: AuditResult.error,
    ));

    // Also get denied
    final deniedEvents = await logger.query(AuditFilter(
      from: from,
      to: to,
      result: AuditResult.denied,
    ));

    final allFailures = [...events, ...errorEvents, ...deniedEvents];

    final failures = <FailureEvent>[];
    final failuresByActor = <String, int>{};
    final failuresByResource = <String, int>{};
    final failuresByReason = <String, int>{};
    var authFailures = 0;
    var authzFailures = 0;
    var errors = 0;

    for (final event in allFailures) {
      failures.add(FailureEvent(
        actor: event.actor,
        resource: event.resource,
        action: event.action,
        timestamp: event.timestamp,
        errorMessage: event.errorMessage,
        ipAddress: event.ipAddress,
      ));

      failuresByActor[event.actor] = (failuresByActor[event.actor] ?? 0) + 1;
      failuresByResource[event.resource] =
          (failuresByResource[event.resource] ?? 0) + 1;

      if (event.errorMessage != null) {
        failuresByReason[event.errorMessage!] =
            (failuresByReason[event.errorMessage!] ?? 0) + 1;
      }

      if (event.action == AuditAction.auth) authFailures++;
      if (event.action == AuditAction.authz) authzFailures++;
      if (event.result == AuditResult.error) errors++;
    }

    return FailureReport(
      generatedAt: DateTime.now(),
      periodStart: from,
      periodEnd: to,
      totalEvents: allFailures.length,
      failures: failures,
      failuresByActor: failuresByActor,
      failuresByResource: failuresByResource,
      failuresByReason: failuresByReason,
      authFailures: authFailures,
      authzFailures: authzFailures,
      errors: errors,
    );
  }

  /// Generate anomaly report for a time period
  Future<AnomalyReport> generateAnomalyReport({
    required DateTime from,
    required DateTime to,
  }) async {
    final events = await logger.query(AuditFilter(from: from, to: to));
    final anomalies = <Anomaly>[];

    // Detect brute force attacks (multiple failed auth attempts)
    final bruteForceAnomalies = _detectBruteForce(events);
    anomalies.addAll(bruteForceAnomalies);

    // Detect privilege escalation attempts
    final privEscAnomalies = _detectPrivilegeEscalation(events);
    anomalies.addAll(privEscAnomalies);

    // Detect unusual access patterns (off-hours access)
    final offHoursAnomalies = _detectOffHoursAccess(events);
    anomalies.addAll(offHoursAnomalies);

    // Detect mass deletion attempts
    final massDeletionAnomalies = _detectMassDeletion(events);
    anomalies.addAll(massDeletionAnomalies);

    var highSeverity = 0;
    var mediumSeverity = 0;
    var lowSeverity = 0;

    for (final anomaly in anomalies) {
      switch (anomaly.severity) {
        case AnomalySeverity.high:
          highSeverity++;
          break;
        case AnomalySeverity.medium:
          mediumSeverity++;
          break;
        case AnomalySeverity.low:
          lowSeverity++;
          break;
      }
    }

    return AnomalyReport(
      generatedAt: DateTime.now(),
      periodStart: from,
      periodEnd: to,
      totalEvents: events.length,
      anomalies: anomalies,
      highSeverity: highSeverity,
      mediumSeverity: mediumSeverity,
      lowSeverity: lowSeverity,
    );
  }

  /// Detect brute force attacks (5+ failed auth attempts in 5 minutes)
  List<Anomaly> _detectBruteForce(List<AuditEvent> events) {
    final anomalies = <Anomaly>[];
    final failedAuthByActor = <String, List<AuditEvent>>{};

    for (final event in events) {
      if (event.action == AuditAction.auth &&
          event.result == AuditResult.failure) {
        failedAuthByActor.putIfAbsent(event.actor, () => []).add(event);
      }
    }

    for (final entry in failedAuthByActor.entries) {
      final actor = entry.key;
      final failures = entry.value;

      if (failures.length >= 5) {
        // Check if within 5 minutes
        failures.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        final first = failures.first.timestamp;
        final last = failures.last.timestamp;
        final duration = last.difference(first);

        if (duration.inMinutes <= 5) {
          anomalies.add(Anomaly(
            type: 'brute_force',
            description:
                'Brute force attack detected: $actor made ${failures.length} failed auth attempts in ${duration.inMinutes} minutes',
            severity: AnomalySeverity.high,
            relatedEvents: failures,
            detectedAt: DateTime.now(),
          ));
        }
      }
    }

    return anomalies;
  }

  /// Detect privilege escalation attempts
  List<Anomaly> _detectPrivilegeEscalation(List<AuditEvent> events) {
    final anomalies = <Anomaly>[];

    for (final event in events) {
      if (event.action == AuditAction.admin &&
          event.result == AuditResult.denied) {
        anomalies.add(Anomaly(
          type: 'privilege_escalation',
          description:
              'Privilege escalation attempt: ${event.actor} tried to perform admin action on ${event.resource}',
          severity: AnomalySeverity.high,
          relatedEvents: [event],
          detectedAt: DateTime.now(),
        ));
      }
    }

    return anomalies;
  }

  /// Detect off-hours access (outside 9am-5pm)
  List<Anomaly> _detectOffHoursAccess(List<AuditEvent> events) {
    final anomalies = <Anomaly>[];
    final offHoursByActor = <String, List<AuditEvent>>{};

    for (final event in events) {
      final hour = event.timestamp.hour;
      if (hour < 9 || hour >= 17) {
        offHoursByActor.putIfAbsent(event.actor, () => []).add(event);
      }
    }

    for (final entry in offHoursByActor.entries) {
      if (entry.value.length >= 10) {
        anomalies.add(Anomaly(
          type: 'off_hours_access',
          description:
              'Unusual off-hours activity: ${entry.key} made ${entry.value.length} accesses outside business hours',
          severity: AnomalySeverity.medium,
          relatedEvents: entry.value,
          detectedAt: DateTime.now(),
        ));
      }
    }

    return anomalies;
  }

  /// Detect mass deletion attempts (10+ deletes in 1 minute)
  List<Anomaly> _detectMassDeletion(List<AuditEvent> events) {
    final anomalies = <Anomaly>[];
    final deletionsByActor = <String, List<AuditEvent>>{};

    for (final event in events) {
      if (event.action == AuditAction.delete) {
        deletionsByActor.putIfAbsent(event.actor, () => []).add(event);
      }
    }

    for (final entry in deletionsByActor.entries) {
      final deletions = entry.value;

      if (deletions.length >= 10) {
        deletions.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        final first = deletions.first.timestamp;
        final last = deletions.last.timestamp;
        final duration = last.difference(first);

        if (duration.inMinutes <= 1) {
          anomalies.add(Anomaly(
            type: 'mass_deletion',
            description:
                'Mass deletion detected: ${entry.key} deleted ${deletions.length} resources in ${duration.inSeconds} seconds',
            severity: AnomalySeverity.high,
            relatedEvents: deletions,
            detectedAt: DateTime.now(),
          ));
        }
      }
    }

    return anomalies;
  }
}
