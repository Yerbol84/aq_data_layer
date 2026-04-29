import 'dart:convert';

/// Input sanitization for different data types
///
/// Provides type-specific sanitization and validation.
class InputSanitizer {
  /// Sanitize string input
  static String sanitizeString(
    String input, {
    int? maxLength,
    bool allowSpecialChars = false,
  }) {
    if (input.isEmpty) return input;

    var sanitized = input.trim();

    // Apply length limit
    if (maxLength != null && sanitized.length > maxLength) {
      sanitized = sanitized.substring(0, maxLength);
    }

    // Remove control characters
    sanitized = sanitized.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');

    // Remove special characters if not allowed
    if (!allowSpecialChars) {
      sanitized = sanitized.replaceAll(RegExp(r'[<>{}[\]\\]'), '');
    }

    return sanitized;
  }

  /// Sanitize and validate integer
  static int? sanitizeInt(
    dynamic input, {
    int? min,
    int? max,
  }) {
    if (input == null) return null;

    int? value;

    if (input is int) {
      value = input;
    } else if (input is String) {
      value = int.tryParse(input);
    } else {
      return null;
    }

    if (value == null) return null;

    // Apply bounds
    if (min != null && value < min) return null;
    if (max != null && value > max) return null;

    return value;
  }

  /// Sanitize and validate double
  static double? sanitizeDouble(
    dynamic input, {
    double? min,
    double? max,
  }) {
    if (input == null) return null;

    double? value;

    if (input is double) {
      value = input;
    } else if (input is int) {
      value = input.toDouble();
    } else if (input is String) {
      value = double.tryParse(input);
    } else {
      return null;
    }

    if (value == null) return null;

    // Apply bounds
    if (min != null && value < min) return null;
    if (max != null && value > max) return null;

    return value;
  }

  /// Validate email format
  static bool isValidEmail(String email) {
    if (email.isEmpty) return false;

    final emailRegex = RegExp(
      r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
    );

    return emailRegex.hasMatch(email) && email.length <= 254;
  }

  /// Validate UUID format
  static bool isValidUuid(String uuid) {
    if (uuid.isEmpty) return false;

    final uuidRegex = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );

    return uuidRegex.hasMatch(uuid);
  }

  /// Validate URL format
  static bool isValidUrl(String url) {
    if (url.isEmpty) return false;

    try {
      final uri = Uri.parse(url);
      return uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https');
    } catch (e) {
      return false;
    }
  }

  /// Sanitize HTML (remove tags)
  static String sanitizeHtml(String input) {
    if (input.isEmpty) return input;

    // Remove HTML tags
    var sanitized = input.replaceAll(RegExp(r'<[^>]*>'), '');

    // Decode HTML entities
    sanitized = sanitized
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");

    return sanitized;
  }

  /// Validate and sanitize JSON
  static String? sanitizeJson(String input) {
    if (input.isEmpty) return null;

    try {
      // Try to parse as JSON
      final decoded = jsonDecode(input);
      // Re-encode to ensure valid JSON
      return jsonEncode(decoded);
    } catch (e) {
      return null;
    }
  }

  /// Sanitize path (prevent directory traversal)
  static String? sanitizePath(String path) {
    if (path.isEmpty) return null;

    // Remove directory traversal attempts
    if (path.contains('..') || path.contains('~')) {
      return null;
    }

    // Remove leading/trailing slashes
    var sanitized = path.trim();
    while (sanitized.startsWith('/')) {
      sanitized = sanitized.substring(1);
    }
    while (sanitized.endsWith('/')) {
      sanitized = sanitized.substring(0, sanitized.length - 1);
    }

    // Only allow alphanumeric, dash, underscore, dot, slash
    if (!RegExp(r'^[a-zA-Z0-9._/-]+$').hasMatch(sanitized)) {
      return null;
    }

    return sanitized;
  }

  /// Validate date format (ISO 8601)
  static DateTime? sanitizeDate(String input) {
    if (input.isEmpty) return null;

    try {
      return DateTime.parse(input);
    } catch (e) {
      return null;
    }
  }

  /// Sanitize boolean
  static bool? sanitizeBool(dynamic input) {
    if (input == null) return null;

    if (input is bool) return input;

    if (input is String) {
      final lower = input.toLowerCase();
      if (lower == 'true' || lower == '1' || lower == 'yes') return true;
      if (lower == 'false' || lower == '0' || lower == 'no') return false;
    }

    if (input is int) {
      if (input == 1) return true;
      if (input == 0) return false;
    }

    return null;
  }

  /// Validate phone number (basic)
  static bool isValidPhone(String phone) {
    if (phone.isEmpty) return false;

    // Remove common separators
    final cleaned = phone.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');

    // Must be 10-15 digits
    return RegExp(r'^\d{10,15}$').hasMatch(cleaned);
  }

  /// Sanitize alphanumeric only
  static String sanitizeAlphanumeric(String input) {
    if (input.isEmpty) return input;
    return input.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
  }

  /// Validate credit card number (Luhn algorithm)
  static bool isValidCreditCard(String cardNumber) {
    if (cardNumber.isEmpty) return false;

    // Remove spaces and dashes
    final cleaned = cardNumber.replaceAll(RegExp(r'[\s\-]'), '');

    // Must be 13-19 digits
    if (!RegExp(r'^\d{13,19}$').hasMatch(cleaned)) {
      return false;
    }

    // Luhn algorithm
    var sum = 0;
    var alternate = false;

    for (var i = cleaned.length - 1; i >= 0; i--) {
      var digit = int.parse(cleaned[i]);

      if (alternate) {
        digit *= 2;
        if (digit > 9) {
          digit -= 9;
        }
      }

      sum += digit;
      alternate = !alternate;
    }

    return sum % 10 == 0;
  }
}
