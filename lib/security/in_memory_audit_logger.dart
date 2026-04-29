import 'dart:math';
import 'audit_event.dart';
import 'audit_logger.dart';

/// In-memory implementation of AuditLogger for development and testing
///
/// This implementation stores audit events in memory and provides
/// simple filtering capabilities. It is NOT suitable for production
/// as events are lost when the process terminates.
class InMemoryAuditLogger implements AuditLogger {
  final List<AuditEvent> _events = [];
  final _random = Random.secure();
  int _counter = 0;

  @override
  Future<void> log(AuditEvent event) async {
    // Ensure event has an ID
    final eventWithId = event.id.isEmpty
        ? AuditEvent(
            id: _generateId(),
            timestamp: event.timestamp,
            actor: event.actor,
            action: event.action,
            resource: event.resource,
            result: event.result,
            severity: event.severity,
            ipAddress: event.ipAddress,
            userAgent: event.userAgent,
            metadata: event.metadata,
            errorMessage: event.errorMessage,
          )
        : event;

    _events.add(eventWithId);
  }

  @override
  Future<List<AuditEvent>> query(AuditFilter filter) async {
    var results = _events.where((event) => filter.matches(event)).toList();

    // Sort by timestamp descending (newest first)
    results.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    // Apply pagination
    if (filter.offset != null) {
      results = results.skip(filter.offset!).toList();
    }
    if (filter.limit != null) {
      results = results.take(filter.limit!).toList();
    }

    return results;
  }

  @override
  Future<int> count(AuditFilter filter) async {
    return _events.where((event) => filter.matches(event)).length;
  }

  @override
  Future<List<AuditEvent>> getByActor(
    String actor, {
    DateTime? from,
    DateTime? to,
    int? limit,
  }) async {
    return query(AuditFilter(
      actor: actor,
      from: from,
      to: to,
      limit: limit,
    ));
  }

  @override
  Future<List<AuditEvent>> getByResource(
    String resource, {
    DateTime? from,
    DateTime? to,
    int? limit,
  }) async {
    return query(AuditFilter(
      resource: resource,
      from: from,
      to: to,
      limit: limit,
    ));
  }

  @override
  Future<List<AuditEvent>> getFailedAttempts({
    DateTime? from,
    DateTime? to,
    int? limit,
  }) async {
    return query(AuditFilter.failures(
      from: from,
      to: to,
      limit: limit,
    ));
  }

  @override
  Future<List<AuditEvent>> getCriticalEvents({
    DateTime? from,
    DateTime? to,
    int? limit,
  }) async {
    return query(AuditFilter.critical(
      from: from,
      to: to,
      limit: limit,
    ));
  }

  @override
  Future<void> clear() async {
    _events.clear();
  }

  /// Get all events (for testing)
  List<AuditEvent> get events => List.unmodifiable(_events);

  /// Get event count (for testing)
  int get eventCount => _events.length;

  /// Generate unique event ID
  String _generateId() {
    _counter++;
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final random = _random.nextInt(0xFFFFFF);
    return 'evt_${timestamp}_${_counter}_${random.toRadixString(16)}';
  }
}
