import 'sql_safety_validator.dart';

/// Query validation for detecting unsafe SQL patterns
///
/// Analyzes SQL queries for common security issues and anti-patterns.
class QueryValidator {
  /// Validate a query for safety issues
  ///
  /// Returns a ValidationResult with any detected issues.
  static ValidationResult validate(String sql, List<dynamic> parameters) {
    final issues = <String>[];

    // Check for string concatenation
    issues.addAll(_checkStringConcatenation(sql));

    // Check for hardcoded values
    issues.addAll(_checkHardcodedValues(sql));

    // Check parameter count
    issues.addAll(_checkParameterCount(sql, parameters));

    // Check for dynamic identifiers
    issues.addAll(_checkDynamicIdentifiers(sql));

    // Check for SQL injection patterns
    issues.addAll(_checkInjectionPatterns(sql));

    // Check for unsafe operators
    issues.addAll(_checkUnsafeOperators(sql));

    return ValidationResult(
      isValid: issues.isEmpty,
      issues: issues,
    );
  }

  /// Check for string concatenation patterns
  static List<String> _checkStringConcatenation(String sql) {
    final issues = <String>[];

    // Check for + operator (common in many languages)
    if (sql.contains("' + ") || sql.contains(" + '")) {
      issues.add('String concatenation detected with + operator - use parameterized queries');
    }

    // Check for || operator (PostgreSQL, Oracle)
    if (sql.contains("' || ") || sql.contains(" || '")) {
      issues.add('String concatenation detected with || operator - use parameterized queries');
    }

    // Check for CONCAT function
    if (RegExp(r'CONCAT\s*\(', caseSensitive: false).hasMatch(sql)) {
      issues.add('CONCAT function detected - use parameterized queries instead');
    }

    return issues;
  }

  /// Check for hardcoded string values
  static List<String> _checkHardcodedValues(String sql) {
    final issues = <String>[];

    // Check for hardcoded strings in WHERE clauses
    if (RegExp(r"WHERE\s+\w+\s*=\s*'[^']*'", caseSensitive: false).hasMatch(sql)) {
      issues.add('Hardcoded string value in WHERE clause - use parameters');
    }

    // Check for hardcoded strings in INSERT VALUES
    if (RegExp(r"VALUES\s*\([^)]*'[^']*'[^)]*\)", caseSensitive: false).hasMatch(sql)) {
      issues.add('Hardcoded string value in INSERT - use parameters');
    }

    // Check for hardcoded strings in UPDATE SET
    if (RegExp(r"SET\s+\w+\s*=\s*'[^']*'", caseSensitive: false).hasMatch(sql)) {
      issues.add('Hardcoded string value in UPDATE - use parameters');
    }

    return issues;
  }

  /// Check parameter count matches placeholders
  static List<String> _checkParameterCount(String sql, List<dynamic> parameters) {
    final issues = <String>[];

    // Count $ placeholders (PostgreSQL style)
    final dollarMatches = RegExp(r'\$\d+').allMatches(sql);
    final maxPlaceholder = dollarMatches.fold<int>(0, (max, match) {
      final num = int.parse(match.group(0)!.substring(1));
      return num > max ? num : max;
    });

    if (maxPlaceholder != parameters.length) {
      issues.add(
        'Parameter count mismatch: $maxPlaceholder placeholders, ${parameters.length} parameters',
      );
    }

    // Count ? placeholders (MySQL, SQLite style)
    final questionMatches = '?'.allMatches(sql).length;
    if (questionMatches > 0 && questionMatches != parameters.length) {
      issues.add(
        'Parameter count mismatch: $questionMatches placeholders, ${parameters.length} parameters',
      );
    }

    return issues;
  }

  /// Check for dynamic table/column names
  static List<String> _checkDynamicIdentifiers(String sql) {
    final issues = <String>[];

    // Check for string interpolation patterns
    if (sql.contains('\${')) {
      issues.add('String interpolation detected - validate table/column names separately');
    }

    // Check for common dynamic identifier patterns
    if (sql.contains('\$table') || sql.contains('\$column')) {
      issues.add('Dynamic identifier detected - validate with isValidIdentifier()');
    }

    return issues;
  }

  /// Check for SQL injection patterns in the query itself
  static List<String> _checkInjectionPatterns(String sql) {
    final issues = <String>[];

    // Check for comment patterns (should not be in legitimate queries)
    if (RegExp(r'--\s*$', multiLine: true).hasMatch(sql)) {
      issues.add('SQL comment detected (--) - potential injection attempt');
    }

    if (sql.contains('/*') || sql.contains('*/')) {
      issues.add('Block comment detected (/* */) - potential injection attempt');
    }

    // Check for stacked queries (multiple statements)
    if (RegExp(r';\s*\w+', caseSensitive: false).hasMatch(sql)) {
      issues.add('Multiple statements detected - potential stacked query injection');
    }

    // Check for UNION (should be explicit, not from user input)
    if (RegExp(r'UNION\s+(ALL\s+)?SELECT', caseSensitive: false).hasMatch(sql)) {
      issues.add('UNION SELECT detected - ensure this is intentional, not from user input');
    }

    return issues;
  }

  /// Check for unsafe operators or functions
  static List<String> _checkUnsafeOperators(String sql) {
    final issues = <String>[];

    // Check for EXECUTE/EXEC (dynamic SQL execution)
    if (RegExp(r'\bEXEC(UTE)?\s*\(', caseSensitive: false).hasMatch(sql)) {
      issues.add('EXECUTE/EXEC detected - avoid dynamic SQL execution');
    }

    // Check for xp_cmdshell (command execution)
    if (RegExp(r'xp_cmdshell', caseSensitive: false).hasMatch(sql)) {
      issues.add('xp_cmdshell detected - command execution not allowed');
    }

    // Check for INTO OUTFILE (file writing)
    if (RegExp(r'INTO\s+OUTFILE', caseSensitive: false).hasMatch(sql)) {
      issues.add('INTO OUTFILE detected - file writing not allowed');
    }

    // Check for LOAD_FILE (file reading)
    if (RegExp(r'LOAD_FILE\s*\(', caseSensitive: false).hasMatch(sql)) {
      issues.add('LOAD_FILE detected - file reading not allowed');
    }

    return issues;
  }

  /// Validate a batch of queries
  static List<ValidationResult> validateBatch(
    List<String> queries,
    List<List<dynamic>> parametersList,
  ) {
    if (queries.length != parametersList.length) {
      throw ArgumentError('Queries and parameters lists must have same length');
    }

    final results = <ValidationResult>[];
    for (var i = 0; i < queries.length; i++) {
      results.add(validate(queries[i], parametersList[i]));
    }

    return results;
  }

  /// Check if a query is safe (no issues)
  static bool isSafe(String sql, List<dynamic> parameters) {
    return validate(sql, parameters).isValid;
  }
}
