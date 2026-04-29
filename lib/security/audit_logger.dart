import 'audit_event.dart';

/// Interface for audit logging
///
/// Provides methods to log security-relevant events and query audit history.
/// All implementations must ensure:
/// - Immutability: audit events cannot be modified after creation
/// - Completeness: all required fields are captured
/// - Accuracy: timestamps are precise (microseconds)
/// - Reliability: events are not lost
abstract interface class AuditLogger {
  /// Log an audit event
  ///
  /// This method must be non-blocking and should not throw exceptions.
  /// If logging fails, the error should be logged internally but not
  /// propagated to the caller.
  Future<void> log(AuditEvent event);

  /// Query audit events matching the filter
  ///
  /// Returns events in reverse chronological order (newest first).
  Future<List<AuditEvent>> query(AuditFilter filter);

  /// Count audit events matching the filter
  Future<int> count(AuditFilter filter);

  /// Get audit events for a specific actor
  Future<List<AuditEvent>> getByActor(
    String actor, {
    DateTime? from,
    DateTime? to,
    int? limit,
  });

  /// Get audit events for a specific resource
  Future<List<AuditEvent>> getByResource(
    String resource, {
    DateTime? from,
    DateTime? to,
    int? limit,
  });

  /// Get failed access attempts
  Future<List<AuditEvent>> getFailedAttempts({
    DateTime? from,
    DateTime? to,
    int? limit,
  });

  /// Get critical events
  Future<List<AuditEvent>> getCriticalEvents({
    DateTime? from,
    DateTime? to,
    int? limit,
  });

  /// Clear all audit events (for testing only)
  Future<void> clear();
}

/// Filter for querying audit events
class AuditFilter {
  /// Start of time range (inclusive)
  final DateTime? from;

  /// End of time range (inclusive)
  final DateTime? to;

  /// Filter by actor
  final String? actor;

  /// Filter by action
  final AuditAction? action;

  /// Filter by resource
  final String? resource;

  /// Filter by result
  final AuditResult? result;

  /// Filter by severity
  final AuditSeverity? severity;

  /// Filter by IP address
  final String? ipAddress;

  /// Maximum number of results
  final int? limit;

  /// Offset for pagination
  final int? offset;

  const AuditFilter({
    this.from,
    this.to,
    this.actor,
    this.action,
    this.resource,
    this.result,
    this.severity,
    this.ipAddress,
    this.limit,
    this.offset,
  });

  /// Create filter for time range
  factory AuditFilter.timeRange({
    required DateTime from,
    required DateTime to,
    int? limit,
  }) {
    return AuditFilter(from: from, to: to, limit: limit);
  }

  /// Create filter for actor
  factory AuditFilter.actor(String actor, {int? limit}) {
    return AuditFilter(actor: actor, limit: limit);
  }

  /// Create filter for resource
  factory AuditFilter.resource(String resource, {int? limit}) {
    return AuditFilter(resource: resource, limit: limit);
  }

  /// Create filter for failed attempts
  factory AuditFilter.failures({DateTime? from, DateTime? to, int? limit}) {
    return AuditFilter(
      from: from,
      to: to,
      result: AuditResult.failure,
      limit: limit,
    );
  }

  /// Create filter for critical events
  factory AuditFilter.critical({DateTime? from, DateTime? to, int? limit}) {
    return AuditFilter(
      from: from,
      to: to,
      severity: AuditSeverity.critical,
      limit: limit,
    );
  }

  /// Check if event matches this filter
  bool matches(AuditEvent event) {
    if (from != null && event.timestamp.isBefore(from!)) return false;
    if (to != null && event.timestamp.isAfter(to!)) return false;
    if (actor != null && event.actor != actor) return false;
    if (action != null && event.action != action) return false;
    if (resource != null && event.resource != resource) return false;
    if (result != null && event.result != result) return false;
    if (severity != null && event.severity != severity) return false;
    if (ipAddress != null && event.ipAddress != ipAddress) return false;
    return true;
  }

  @override
  String toString() {
    final parts = <String>[];
    if (from != null) parts.add('from: ${from!.toIso8601String()}');
    if (to != null) parts.add('to: ${to!.toIso8601String()}');
    if (actor != null) parts.add('actor: $actor');
    if (action != null) parts.add('action: ${action!.name}');
    if (resource != null) parts.add('resource: $resource');
    if (result != null) parts.add('result: ${result!.name}');
    if (severity != null) parts.add('severity: ${severity!.name}');
    if (limit != null) parts.add('limit: $limit');
    return 'AuditFilter(${parts.join(', ')})';
  }
}
