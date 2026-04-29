import 'package:meta/meta.dart';

/// Audit event representing a security-relevant action in the system
///
/// All audit events are immutable and contain complete information about:
/// - Who performed the action (actor)
/// - What action was performed (action)
/// - What resource was affected (resource)
/// - When it happened (timestamp with microsecond precision)
/// - What was the result (result)
/// - Additional context (metadata)
@immutable
class AuditEvent {
  /// Unique identifier for this audit event
  final String id;

  /// Timestamp when the event occurred (microsecond precision)
  final DateTime timestamp;

  /// Who performed the action (user ID, service name, or 'system')
  final String actor;

  /// Type of action performed
  final AuditAction action;

  /// Resource that was affected (e.g., 'user:123', 'project:abc')
  final String resource;

  /// Result of the action
  final AuditResult result;

  /// Severity level of the event
  final AuditSeverity severity;

  /// IP address of the actor (if applicable)
  final String? ipAddress;

  /// User agent string (if applicable)
  final String? userAgent;

  /// Additional context as key-value pairs
  final Map<String, dynamic> metadata;

  /// Error message (if result is FAILURE or ERROR)
  final String? errorMessage;

  const AuditEvent({
    required this.id,
    required this.timestamp,
    required this.actor,
    required this.action,
    required this.resource,
    required this.result,
    this.severity = AuditSeverity.info,
    this.ipAddress,
    this.userAgent,
    this.metadata = const {},
    this.errorMessage,
  });

  /// Create audit event from JSON
  factory AuditEvent.fromJson(Map<String, dynamic> json) {
    return AuditEvent(
      id: json['id'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      actor: json['actor'] as String,
      action: AuditAction.values.byName(json['action'] as String),
      resource: json['resource'] as String,
      result: AuditResult.values.byName(json['result'] as String),
      severity: AuditSeverity.values.byName(
        json['severity'] as String? ?? 'info',
      ),
      ipAddress: json['ip_address'] as String?,
      userAgent: json['user_agent'] as String?,
      metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? {}),
      errorMessage: json['error_message'] as String?,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'timestamp': timestamp.toIso8601String(),
      'actor': actor,
      'action': action.name,
      'resource': resource,
      'result': result.name,
      'severity': severity.name,
      if (ipAddress != null) 'ip_address': ipAddress,
      if (userAgent != null) 'user_agent': userAgent,
      'metadata': metadata,
      if (errorMessage != null) 'error_message': errorMessage,
    };
  }

  @override
  String toString() {
    return 'AuditEvent(${timestamp.toIso8601String()}, $actor, ${action.name}, $resource, ${result.name})';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AuditEvent && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// Type of action performed
enum AuditAction {
  /// Create a new resource
  create,

  /// Read/access a resource
  read,

  /// Update an existing resource
  update,

  /// Delete a resource
  delete,

  /// Authentication action (login, logout, token refresh)
  auth,

  /// Authorization check (permission check)
  authz,

  /// Administrative action (user management, config change)
  admin,

  /// Secret access (read/write secret)
  secret,

  /// Secret rotation
  rotate,

  /// Export data
  export,

  /// Import data
  import_,
}

/// Result of the action
enum AuditResult {
  /// Action completed successfully
  success,

  /// Action failed (expected failure, e.g., wrong password)
  failure,

  /// Action resulted in error (unexpected failure, e.g., database error)
  error,

  /// Action was denied by authorization
  denied,
}

/// Severity level of the audit event
enum AuditSeverity {
  /// Informational event (normal operation)
  info,

  /// Warning event (unusual but not critical)
  warning,

  /// Critical event (security-relevant, requires attention)
  critical,
}
