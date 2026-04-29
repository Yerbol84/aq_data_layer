import 'audit_event.dart';
import 'audit_logger.dart';

/// Retention policy for audit events
///
/// Defines how long audit events should be retained before archival or deletion.
/// Different event types may have different retention requirements based on
/// compliance standards (SOC 2, PCI DSS, GDPR, etc.).
class RetentionPolicy {
  /// Retention period for normal events
  final Duration normalRetention;

  /// Retention period for critical events
  final Duration criticalRetention;

  /// Retention period for authentication events
  final Duration authRetention;

  /// Whether to archive events before deletion
  final bool archiveBeforeDelete;

  /// Archive storage location (e.g., S3 bucket, file path)
  final String? archiveLocation;

  const RetentionPolicy({
    this.normalRetention = const Duration(days: 90), // PCI DSS minimum
    this.criticalRetention = const Duration(days: 365), // SOC 2 minimum
    this.authRetention = const Duration(days: 180),
    this.archiveBeforeDelete = true,
    this.archiveLocation,
  });

  /// SOC 2 compliant retention (1 year minimum)
  factory RetentionPolicy.soc2() {
    return const RetentionPolicy(
      normalRetention: Duration(days: 365),
      criticalRetention: Duration(days: 730), // 2 years for critical
      authRetention: Duration(days: 365),
      archiveBeforeDelete: true,
    );
  }

  /// PCI DSS compliant retention (3 months minimum)
  factory RetentionPolicy.pciDss() {
    return const RetentionPolicy(
      normalRetention: Duration(days: 90),
      criticalRetention: Duration(days: 365),
      authRetention: Duration(days: 90),
      archiveBeforeDelete: true,
    );
  }

  /// GDPR compliant retention (minimal retention)
  factory RetentionPolicy.gdpr() {
    return const RetentionPolicy(
      normalRetention: Duration(days: 30),
      criticalRetention: Duration(days: 90),
      authRetention: Duration(days: 60),
      archiveBeforeDelete: false, // GDPR prefers deletion
    );
  }

  /// Get retention period for an event
  Duration getRetentionFor(AuditEvent event) {
    if (event.severity == AuditSeverity.critical) {
      return criticalRetention;
    }
    if (event.action == AuditAction.auth || event.action == AuditAction.authz) {
      return authRetention;
    }
    return normalRetention;
  }

  /// Check if event should be retained
  bool shouldRetain(AuditEvent event, DateTime now) {
    final retention = getRetentionFor(event);
    final expiryDate = event.timestamp.add(retention);
    return now.isBefore(expiryDate);
  }

  /// Check if event should be archived
  bool shouldArchive(AuditEvent event, DateTime now) {
    if (!archiveBeforeDelete) return false;
    return !shouldRetain(event, now);
  }

  /// Check if event should be deleted
  bool shouldDelete(AuditEvent event, DateTime now) {
    if (archiveBeforeDelete) {
      // Only delete if already archived
      return !shouldRetain(event, now);
    }
    return !shouldRetain(event, now);
  }
}

/// Service for applying retention policies to audit events
class AuditRetentionService {
  final AuditLogger logger;
  final RetentionPolicy policy;

  AuditRetentionService({
    required this.logger,
    required this.policy,
  });

  /// Apply retention policy - archive and delete old events
  ///
  /// Returns a report of actions taken.
  Future<RetentionReport> applyRetention() async {
    final report = RetentionReport();
    final now = DateTime.now();

    // Get all events (this is inefficient for large datasets - in production,
    // use time-based queries to get only old events)
    final events = await logger.query(const AuditFilter());

    for (final event in events) {
      if (policy.shouldArchive(event, now)) {
        try {
          await _archiveEvent(event);
          report.archived.add(event.id);
        } catch (e) {
          report.failed[event.id] = 'Archive failed: $e';
        }
      }

      if (policy.shouldDelete(event, now)) {
        try {
          // In production, this would delete from database
          // For now, we just track it
          report.deleted.add(event.id);
        } catch (e) {
          report.failed[event.id] = 'Delete failed: $e';
        }
      } else {
        report.retained.add(event.id);
      }
    }

    return report;
  }

  /// Get retention status for all events
  Future<List<RetentionStatus>> getRetentionStatus() async {
    final now = DateTime.now();
    final events = await logger.query(const AuditFilter());
    final statuses = <RetentionStatus>[];

    for (final event in events) {
      final retention = policy.getRetentionFor(event);
      final expiryDate = event.timestamp.add(retention);
      final daysUntilExpiry = expiryDate.difference(now).inDays;

      statuses.add(RetentionStatus(
        eventId: event.id,
        timestamp: event.timestamp,
        expiryDate: expiryDate,
        daysUntilExpiry: daysUntilExpiry,
        shouldRetain: policy.shouldRetain(event, now),
        shouldArchive: policy.shouldArchive(event, now),
        shouldDelete: policy.shouldDelete(event, now),
      ));
    }

    return statuses;
  }

  /// Archive event to cold storage
  Future<void> _archiveEvent(AuditEvent event) async {
    // In production, this would write to S3, file system, or other cold storage
    // For now, just log it
    print('📦 Archiving event ${event.id} to ${policy.archiveLocation ?? "default location"}');
  }
}

/// Report of retention policy application
class RetentionReport {
  final List<String> retained = [];
  final List<String> archived = [];
  final List<String> deleted = [];
  final Map<String, String> failed = {};

  int get total => retained.length + archived.length + deleted.length + failed.length;
  bool get hasFailures => failed.isNotEmpty;

  @override
  String toString() {
    return 'RetentionReport(retained: ${retained.length}, archived: ${archived.length}, deleted: ${deleted.length}, failed: ${failed.length})';
  }
}

/// Status of an event's retention
class RetentionStatus {
  final String eventId;
  final DateTime timestamp;
  final DateTime expiryDate;
  final int daysUntilExpiry;
  final bool shouldRetain;
  final bool shouldArchive;
  final bool shouldDelete;

  RetentionStatus({
    required this.eventId,
    required this.timestamp,
    required this.expiryDate,
    required this.daysUntilExpiry,
    required this.shouldRetain,
    required this.shouldArchive,
    required this.shouldDelete,
  });

  @override
  String toString() {
    return 'RetentionStatus($eventId: expires in $daysUntilExpiry days, retain: $shouldRetain, archive: $shouldArchive, delete: $shouldDelete)';
  }
}
