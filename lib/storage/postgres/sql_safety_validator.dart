/// SQL injection detection and prevention
///
/// Detects common SQL injection patterns and validates query safety.
/// This is a defense-in-depth layer - parameterized queries are still
/// the primary defense.
class SqlSafetyValidator {
  /// Common SQL injection patterns
  static final _injectionPatterns = [
    // Classic injection
    RegExp(r"'\s*OR\s*'1'\s*=\s*'1", caseSensitive: false),
    RegExp(r"'\s*OR\s*1\s*=\s*1", caseSensitive: false),
    RegExp(r"'\s*OR\s*'a'\s*=\s*'a", caseSensitive: false),
    RegExp(r"admin'\s*--", caseSensitive: false),
    RegExp(r"admin'\s*#", caseSensitive: false),

    // UNION-based injection
    RegExp(r"'\s*UNION\s+SELECT", caseSensitive: false),
    RegExp(r"'\s*UNION\s+ALL\s+SELECT", caseSensitive: false),

    // Boolean-based blind injection
    RegExp(r"'\s*AND\s+1\s*=\s*1\s*--", caseSensitive: false),
    RegExp(r"'\s*AND\s+1\s*=\s*2\s*--", caseSensitive: false),
    RegExp(r"'\s*AND\s+SUBSTRING", caseSensitive: false),

    // Time-based blind injection
    RegExp(r"WAITFOR\s+DELAY", caseSensitive: false),
    RegExp(r"SELECT\s+SLEEP\s*\(", caseSensitive: false),
    RegExp(r"BENCHMARK\s*\(", caseSensitive: false),
    RegExp(r"pg_sleep\s*\(", caseSensitive: false),

    // Stacked queries
    RegExp(r";\s*DROP\s+TABLE", caseSensitive: false),
    RegExp(r";\s*DELETE\s+FROM", caseSensitive: false),
    RegExp(r";\s*UPDATE\s+\w+\s+SET", caseSensitive: false),
    RegExp(r";\s*INSERT\s+INTO", caseSensitive: false),

    // Comment-based injection
    RegExp(r"--\s*$", caseSensitive: false),
    RegExp(r"/\*.*\*/", caseSensitive: false),
    RegExp(r"#.*$", caseSensitive: false),

    // Hex encoding
    RegExp(r"0x[0-9a-fA-F]+", caseSensitive: false),

    // Char encoding
    RegExp(r"CHAR\s*\(", caseSensitive: false),
    RegExp(r"CHR\s*\(", caseSensitive: false),

    // Information schema access
    RegExp(r"information_schema", caseSensitive: false),
    RegExp(r"pg_catalog", caseSensitive: false),
    RegExp(r"sys\.", caseSensitive: false),

    // Command execution
    RegExp(r"xp_cmdshell", caseSensitive: false),
    RegExp(r"exec\s*\(", caseSensitive: false),
    RegExp(r"execute\s*\(", caseSensitive: false),
  ];

  /// SQL keywords that should not appear in user input
  static final _sqlKeywords = {
    'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'DROP', 'CREATE', 'ALTER',
    'TRUNCATE', 'UNION', 'JOIN', 'WHERE', 'FROM', 'INTO', 'VALUES',
    'TABLE', 'DATABASE', 'SCHEMA', 'INDEX', 'VIEW', 'PROCEDURE',
    'FUNCTION', 'TRIGGER', 'GRANT', 'REVOKE', 'EXEC', 'EXECUTE',
  };

  /// Detect SQL injection patterns in input
  ///
  /// Returns true if injection pattern detected, false otherwise.
  static bool detectInjection(String input) {
    if (input.isEmpty) return false;

    // Check against known patterns
    for (final pattern in _injectionPatterns) {
      if (pattern.hasMatch(input)) {
        return true;
      }
    }

    // Check for SQL keywords (case-insensitive)
    final upperInput = input.toUpperCase();
    for (final keyword in _sqlKeywords) {
      if (upperInput.contains(keyword)) {
        // Allow keywords in quoted strings
        if (!_isInQuotedString(input, keyword)) {
          return true;
        }
      }
    }

    return false;
  }

  /// Validate query safety
  ///
  /// Checks if query uses parameterized parameters correctly.
  static ValidationResult validateQuery(String sql, List<dynamic> parameters) {
    final issues = <String>[];

    // Check for string concatenation patterns
    if (sql.contains("' + ") || sql.contains("' || ")) {
      issues.add('String concatenation detected - use parameterized queries');
    }

    // Check for unparameterized values
    if (RegExp(r"=\s*'[^']*'").hasMatch(sql)) {
      issues.add('Hardcoded string value detected - use parameters');
    }

    // Count parameter placeholders
    final placeholderCount = '\$'.allMatches(sql).length;
    if (placeholderCount != parameters.length) {
      issues.add(
        'Parameter count mismatch: $placeholderCount placeholders, ${parameters.length} parameters',
      );
    }

    // Check for dynamic table/column names
    if (sql.contains('\${') || sql.contains('\$table') || sql.contains('\$column')) {
      issues.add('Dynamic table/column names detected - validate separately');
    }

    return ValidationResult(
      isValid: issues.isEmpty,
      issues: issues,
    );
  }

  /// Sanitize user input
  ///
  /// Removes or escapes potentially dangerous characters.
  /// NOTE: This is NOT a substitute for parameterized queries!
  static String sanitizeInput(String input, {bool strict = false}) {
    if (input.isEmpty) return input;

    var sanitized = input;

    if (strict) {
      // Strict mode: remove all special characters (keep only alphanumeric, space, dot, dash)
      sanitized = sanitized.replaceAll(RegExp(r"[^\w\s.-]"), '');
    } else {
      // Normal mode: escape dangerous characters
      sanitized = sanitized
          .replaceAll("'", "''") // Escape single quotes
          .replaceAll('"', '""') // Escape double quotes
          .replaceAll('\\', '\\\\') // Escape backslashes
          .replaceAll(';', '') // Remove semicolons
          .replaceAll('--', '') // Remove SQL comments
          .replaceAll('/*', '') // Remove block comments
          .replaceAll('*/', '')
          .replaceAll('#', ''); // Remove hash comments
    }

    return sanitized;
  }

  /// Validate table or column name
  ///
  /// Table/column names cannot be parameterized, so they need
  /// special validation.
  static bool isValidIdentifier(String identifier) {
    if (identifier.isEmpty) return false;

    // Must start with letter or underscore
    if (!RegExp(r'^[a-zA-Z_]').hasMatch(identifier)) {
      return false;
    }

    // Can only contain alphanumeric and underscore
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(identifier)) {
      return false;
    }

    // Cannot be a SQL keyword
    if (_sqlKeywords.contains(identifier.toUpperCase())) {
      return false;
    }

    // Length limit
    if (identifier.length > 63) {
      // PostgreSQL limit
      return false;
    }

    return true;
  }

  /// Check if keyword is inside a quoted string
  static bool _isInQuotedString(String input, String keyword) {
    final keywordIndex = input.toUpperCase().indexOf(keyword);
    if (keywordIndex == -1) return false;

    var inSingleQuote = false;
    var inDoubleQuote = false;

    for (var i = 0; i < keywordIndex; i++) {
      if (input[i] == "'" && (i == 0 || input[i - 1] != '\\')) {
        inSingleQuote = !inSingleQuote;
      } else if (input[i] == '"' && (i == 0 || input[i - 1] != '\\')) {
        inDoubleQuote = !inDoubleQuote;
      }
    }

    return inSingleQuote || inDoubleQuote;
  }
}

/// Result of query validation
class ValidationResult {
  final bool isValid;
  final List<String> issues;

  ValidationResult({
    required this.isValid,
    required this.issues,
  });

  @override
  String toString() {
    if (isValid) return 'ValidationResult(valid)';
    return 'ValidationResult(invalid: ${issues.join(', ')})';
  }
}

/// SQL injection attempt detected
class SqlInjectionException implements Exception {
  final String message;
  final String input;

  SqlInjectionException(this.message, this.input);

  @override
  String toString() => 'SqlInjectionException: $message (input: $input)';
}
