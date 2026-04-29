import 'package:postgres/postgres.dart';
import 'audit_event.dart';
import 'audit_logger.dart';

/// PostgreSQL implementation of AuditLogger
///
/// Features:
/// - Append-only storage (no updates/deletes)
/// - Efficient indexing (timestamp, actor, action, resource)
/// - Time-based partitioning (monthly)
/// - RLS for tenant isolation
/// - Microsecond timestamp precision
///
/// ## Table Schema
///
/// ```sql
/// CREATE TABLE audit_events (
///   id TEXT NOT NULL,
///   timestamp TIMESTAMPTZ NOT NULL,
///   tenant_id TEXT NOT NULL,
///   actor TEXT NOT NULL,
///   action TEXT NOT NULL,
///   resource TEXT NOT NULL,
///   result TEXT NOT NULL,
///   severity TEXT NOT NULL,
///   ip_address TEXT,
///   user_agent TEXT,
///   metadata JSONB,
///   error_message TEXT,
///   PRIMARY KEY (id, tenant_id, timestamp)
/// ) PARTITION BY RANGE (timestamp);
///
/// CREATE INDEX idx_audit_timestamp ON audit_events (timestamp DESC);
/// CREATE INDEX idx_audit_actor ON audit_events (actor, timestamp DESC);
/// CREATE INDEX idx_audit_resource ON audit_events (resource, timestamp DESC);
/// CREATE INDEX idx_audit_action ON audit_events (action, timestamp DESC);
/// CREATE INDEX idx_audit_result ON audit_events (result, timestamp DESC);
/// ```
class PostgresAuditLogger implements AuditLogger {
  final Connection connection;
  final String tenantId;

  PostgresAuditLogger({
    required this.connection,
    required this.tenantId,
  });

  @override
  Future<void> log(AuditEvent event) async {
    try {
      await connection.execute(
        '''
        INSERT INTO audit_events (
          id, timestamp, tenant_id, actor, action, resource, result, severity,
          ip_address, user_agent, metadata, error_message
        ) VALUES (
          \$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12
        )
        ''',
        parameters: [
          event.id,
          event.timestamp,
          tenantId,
          event.actor,
          event.action.name,
          event.resource,
          event.result.name,
          event.severity.name,
          event.ipAddress,
          event.userAgent,
          event.metadata,
          event.errorMessage,
        ],
      );
    } catch (e) {
      // Log error but don't throw - audit logging must not break application
      print('⚠️  Failed to log audit event: $e');
    }
  }

  @override
  Future<List<AuditEvent>> query(AuditFilter filter) async {
    final sql = StringBuffer('SELECT * FROM audit_events WHERE tenant_id = \$1');
    final params = <dynamic>[tenantId];
    var paramIndex = 2;

    // Build WHERE clause
    if (filter.from != null) {
      sql.write(' AND timestamp >= \$$paramIndex');
      params.add(filter.from);
      paramIndex++;
    }

    if (filter.to != null) {
      sql.write(' AND timestamp <= \$$paramIndex');
      params.add(filter.to);
      paramIndex++;
    }

    if (filter.actor != null) {
      sql.write(' AND actor = \$$paramIndex');
      params.add(filter.actor);
      paramIndex++;
    }

    if (filter.action != null) {
      sql.write(' AND action = \$$paramIndex');
      params.add(filter.action!.name);
      paramIndex++;
    }

    if (filter.resource != null) {
      sql.write(' AND resource = \$$paramIndex');
      params.add(filter.resource);
      paramIndex++;
    }

    if (filter.result != null) {
      sql.write(' AND result = \$$paramIndex');
      params.add(filter.result!.name);
      paramIndex++;
    }

    if (filter.severity != null) {
      sql.write(' AND severity = \$$paramIndex');
      params.add(filter.severity!.name);
      paramIndex++;
    }

    if (filter.ipAddress != null) {
      sql.write(' AND ip_address = \$$paramIndex');
      params.add(filter.ipAddress);
      paramIndex++;
    }

    // Order by timestamp DESC (newest first)
    sql.write(' ORDER BY timestamp DESC');

    // Pagination
    if (filter.limit != null) {
      sql.write(' LIMIT \$$paramIndex');
      params.add(filter.limit);
      paramIndex++;
    }

    if (filter.offset != null) {
      sql.write(' OFFSET \$$paramIndex');
      params.add(filter.offset);
      paramIndex++;
    }

    final result = await connection.execute(sql.toString(), parameters: params);

    return result.map((row) => _rowToEvent(row)).toList();
  }

  @override
  Future<int> count(AuditFilter filter) async {
    final sql = StringBuffer('SELECT COUNT(*) FROM audit_events WHERE tenant_id = \$1');
    final params = <dynamic>[tenantId];
    var paramIndex = 2;

    // Build WHERE clause (same as query)
    if (filter.from != null) {
      sql.write(' AND timestamp >= \$$paramIndex');
      params.add(filter.from);
      paramIndex++;
    }

    if (filter.to != null) {
      sql.write(' AND timestamp <= \$$paramIndex');
      params.add(filter.to);
      paramIndex++;
    }

    if (filter.actor != null) {
      sql.write(' AND actor = \$$paramIndex');
      params.add(filter.actor);
      paramIndex++;
    }

    if (filter.action != null) {
      sql.write(' AND action = \$$paramIndex');
      params.add(filter.action!.name);
      paramIndex++;
    }

    if (filter.resource != null) {
      sql.write(' AND resource = \$$paramIndex');
      params.add(filter.resource);
      paramIndex++;
    }

    if (filter.result != null) {
      sql.write(' AND result = \$$paramIndex');
      params.add(filter.result!.name);
      paramIndex++;
    }

    if (filter.severity != null) {
      sql.write(' AND severity = \$$paramIndex');
      params.add(filter.severity!.name);
      paramIndex++;
    }

    if (filter.ipAddress != null) {
      sql.write(' AND ip_address = \$$paramIndex');
      params.add(filter.ipAddress);
      paramIndex++;
    }

    final result = await connection.execute(sql.toString(), parameters: params);
    return result.first[0] as int;
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
    // Only for testing - delete all events for this tenant
    await connection.execute(
      'DELETE FROM audit_events WHERE tenant_id = \$1',
      parameters: [tenantId],
    );
  }

  /// Convert database row to AuditEvent
  AuditEvent _rowToEvent(ResultRow row) {
    return AuditEvent(
      id: row[0] as String,
      timestamp: row[1] as DateTime,
      actor: row[3] as String,
      action: AuditAction.values.byName(row[4] as String),
      resource: row[5] as String,
      result: AuditResult.values.byName(row[6] as String),
      severity: AuditSeverity.values.byName(row[7] as String),
      ipAddress: row[8] as String?,
      userAgent: row[9] as String?,
      metadata: Map<String, dynamic>.from(row[10] as Map? ?? {}),
      errorMessage: row[11] as String?,
    );
  }
}
