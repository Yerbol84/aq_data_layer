/// Base class for all dart_vault exceptions.
sealed class VaultException implements Exception {
  final String message;
  const VaultException(this.message);

  @override
  String toString() => '${runtimeType}: $message';
}

/// Thrown when an entity or version node is not found.
final class VaultNotFoundException extends VaultException {
  const VaultNotFoundException(super.message);
}

/// Thrown when a requester does not have sufficient access rights.
final class VaultAccessDeniedException extends VaultException {
  const VaultAccessDeniedException(super.message);
}

/// Thrown when an invalid state transition is attempted
/// (e.g. editing a SNAPSHOT, or operating on a DELETED node).
final class VaultStateException extends VaultException {
  const VaultStateException(super.message);
}

/// Thrown when an invalid transition is requested
/// (e.g. setting a DRAFT as currentVersion without publishing first).
final class VaultInvalidTransitionException extends VaultException {
  const VaultInvalidTransitionException(super.message);
}

/// Thrown when the underlying storage backend reports an error.
final class VaultStorageException extends VaultException {
  final Object? cause;
  const VaultStorageException(super.message, {this.cause});

  @override
  String toString() =>
      'VaultStorageException: $message'
      '${cause != null ? ' (cause: $cause)' : ''}';
}

/// Thrown when a unique index constraint is violated.
final class VaultUniqueConstraintException extends VaultException {
  final String field;
  const VaultUniqueConstraintException(super.message, {required this.field});
}
