import 'sql_safety_validator.dart';

/// Safe SQL query builder with parameterized queries
///
/// Provides a fluent API for building SQL queries that are safe from
/// SQL injection by design. All user input is automatically parameterized.
class SafeQueryBuilder {
  final List<dynamic> _parameters = [];
  final StringBuffer _sql = StringBuffer();
  int _parameterIndex = 1;

  /// Get the built SQL query
  String get sql => _sql.toString();

  /// Get the parameters for the query
  List<dynamic> get parameters => List.unmodifiable(_parameters);

  /// Build a SELECT query
  ///
  /// Example:
  /// ```dart
  /// final builder = SafeQueryBuilder()
  ///   .select('users', ['id', 'name', 'email'])
  ///   .where('status', '=', 'active')
  ///   .orderBy('created_at', descending: true)
  ///   .limit(10);
  /// ```
  SafeQueryBuilder select(String table, List<String> columns) {
    if (!SqlSafetyValidator.isValidIdentifier(table)) {
      throw ArgumentError('Invalid table name: $table');
    }

    for (final column in columns) {
      if (!SqlSafetyValidator.isValidIdentifier(column)) {
        throw ArgumentError('Invalid column name: $column');
      }
    }

    _sql.write('SELECT ${columns.join(', ')} FROM $table');
    return this;
  }

  /// Add WHERE clause
  SafeQueryBuilder where(String column, String operator, dynamic value) {
    if (!SqlSafetyValidator.isValidIdentifier(column)) {
      throw ArgumentError('Invalid column name: $column');
    }

    if (!_isValidOperator(operator)) {
      throw ArgumentError('Invalid operator: $operator');
    }

    if (_sql.toString().contains('WHERE')) {
      _sql.write(' AND');
    } else {
      _sql.write(' WHERE');
    }

    _sql.write(' $column $operator \$${_parameterIndex++}');
    _parameters.add(value);
    return this;
  }

  /// Add OR WHERE clause
  SafeQueryBuilder orWhere(String column, String operator, dynamic value) {
    if (!SqlSafetyValidator.isValidIdentifier(column)) {
      throw ArgumentError('Invalid column name: $column');
    }

    if (!_isValidOperator(operator)) {
      throw ArgumentError('Invalid operator: $operator');
    }

    if (_sql.toString().contains('WHERE')) {
      _sql.write(' OR');
    } else {
      _sql.write(' WHERE');
    }

    _sql.write(' $column $operator \$${_parameterIndex++}');
    _parameters.add(value);
    return this;
  }

  /// Add WHERE IN clause
  SafeQueryBuilder whereIn(String column, List<dynamic> values) {
    if (!SqlSafetyValidator.isValidIdentifier(column)) {
      throw ArgumentError('Invalid column name: $column');
    }

    if (values.isEmpty) {
      throw ArgumentError('Values list cannot be empty');
    }

    if (_sql.toString().contains('WHERE')) {
      _sql.write(' AND');
    } else {
      _sql.write(' WHERE');
    }

    final placeholders = <String>[];
    for (final value in values) {
      placeholders.add('\$${_parameterIndex++}');
      _parameters.add(value);
    }

    _sql.write(' $column IN (${placeholders.join(', ')})');
    return this;
  }

  /// Add ORDER BY clause
  SafeQueryBuilder orderBy(String column, {bool descending = false}) {
    if (!SqlSafetyValidator.isValidIdentifier(column)) {
      throw ArgumentError('Invalid column name: $column');
    }

    _sql.write(' ORDER BY $column');
    if (descending) {
      _sql.write(' DESC');
    }
    return this;
  }

  /// Add LIMIT clause
  SafeQueryBuilder limit(int count) {
    if (count <= 0) {
      throw ArgumentError('Limit must be positive');
    }

    _sql.write(' LIMIT \$${_parameterIndex++}');
    _parameters.add(count);
    return this;
  }

  /// Add OFFSET clause
  SafeQueryBuilder offset(int count) {
    if (count < 0) {
      throw ArgumentError('Offset cannot be negative');
    }

    _sql.write(' OFFSET \$${_parameterIndex++}');
    _parameters.add(count);
    return this;
  }

  /// Build an INSERT query
  ///
  /// Example:
  /// ```dart
  /// final builder = SafeQueryBuilder()
  ///   .insert('users', {
  ///     'name': 'John Doe',
  ///     'email': 'john@example.com',
  ///     'status': 'active',
  ///   });
  /// ```
  SafeQueryBuilder insert(String table, Map<String, dynamic> data) {
    if (!SqlSafetyValidator.isValidIdentifier(table)) {
      throw ArgumentError('Invalid table name: $table');
    }

    if (data.isEmpty) {
      throw ArgumentError('Data cannot be empty');
    }

    final columns = <String>[];
    final placeholders = <String>[];

    for (final entry in data.entries) {
      if (!SqlSafetyValidator.isValidIdentifier(entry.key)) {
        throw ArgumentError('Invalid column name: ${entry.key}');
      }

      columns.add(entry.key);
      placeholders.add('\$${_parameterIndex++}');
      _parameters.add(entry.value);
    }

    _sql.write('INSERT INTO $table (${columns.join(', ')}) VALUES (${placeholders.join(', ')})');
    return this;
  }

  /// Add RETURNING clause
  SafeQueryBuilder returning(List<String> columns) {
    for (final column in columns) {
      if (!SqlSafetyValidator.isValidIdentifier(column)) {
        throw ArgumentError('Invalid column name: $column');
      }
    }

    _sql.write(' RETURNING ${columns.join(', ')}');
    return this;
  }

  /// Build an UPDATE query
  ///
  /// Example:
  /// ```dart
  /// final builder = SafeQueryBuilder()
  ///   .update('users', {'status': 'inactive'})
  ///   .where('id', '=', userId);
  /// ```
  SafeQueryBuilder update(String table, Map<String, dynamic> data) {
    if (!SqlSafetyValidator.isValidIdentifier(table)) {
      throw ArgumentError('Invalid table name: $table');
    }

    if (data.isEmpty) {
      throw ArgumentError('Data cannot be empty');
    }

    final sets = <String>[];

    for (final entry in data.entries) {
      if (!SqlSafetyValidator.isValidIdentifier(entry.key)) {
        throw ArgumentError('Invalid column name: ${entry.key}');
      }

      sets.add('${entry.key} = \$${_parameterIndex++}');
      _parameters.add(entry.value);
    }

    _sql.write('UPDATE $table SET ${sets.join(', ')}');
    return this;
  }

  /// Build a DELETE query
  ///
  /// Example:
  /// ```dart
  /// final builder = SafeQueryBuilder()
  ///   .delete('users')
  ///   .where('status', '=', 'deleted')
  ///   .where('created_at', '<', cutoffDate);
  /// ```
  SafeQueryBuilder delete(String table) {
    if (!SqlSafetyValidator.isValidIdentifier(table)) {
      throw ArgumentError('Invalid table name: $table');
    }

    _sql.write('DELETE FROM $table');
    return this;
  }

  /// Validate allowed SQL operators
  bool _isValidOperator(String operator) {
    const allowedOperators = {
      '=', '!=', '<>', '<', '>', '<=', '>=',
      'LIKE', 'ILIKE', 'NOT LIKE', 'NOT ILIKE',
      'IS', 'IS NOT', 'IS NULL', 'IS NOT NULL',
    };

    return allowedOperators.contains(operator.toUpperCase());
  }

  /// Reset the builder
  void reset() {
    _sql.clear();
    _parameters.clear();
    _parameterIndex = 1;
  }
}
