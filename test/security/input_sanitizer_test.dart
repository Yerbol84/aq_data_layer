import 'package:test/test.dart';
import '../../lib/security/input_sanitizer.dart';

void main() {
  group('InputSanitizer - String', () {
    test('sanitizeString удаляет control characters', () {
      expect(InputSanitizer.sanitizeString('test\x00\x01\x1F'), 'test');
      expect(InputSanitizer.sanitizeString('hello\x7Fworld'), 'helloworld');
    });

    test('sanitizeString применяет maxLength', () {
      expect(InputSanitizer.sanitizeString('hello world', maxLength: 5), 'hello');
      expect(InputSanitizer.sanitizeString('test', maxLength: 10), 'test');
    });

    test('sanitizeString удаляет special chars если не разрешены', () {
      expect(InputSanitizer.sanitizeString('test<script>'), 'testscript');
      expect(InputSanitizer.sanitizeString('test{data}'), 'testdata');
      expect(InputSanitizer.sanitizeString('test[0]'), 'test0');
    });

    test('sanitizeString сохраняет special chars если разрешены', () {
      expect(InputSanitizer.sanitizeString('test<data>', allowSpecialChars: true), 'test<data>');
    });

    test('sanitizeString trim whitespace', () {
      expect(InputSanitizer.sanitizeString('  test  '), 'test');
      expect(InputSanitizer.sanitizeString('\ttest\n'), 'test');
    });
  });

  group('InputSanitizer - Integer', () {
    test('sanitizeInt парсит int', () {
      expect(InputSanitizer.sanitizeInt(123), 123);
      expect(InputSanitizer.sanitizeInt('456'), 456);
      expect(InputSanitizer.sanitizeInt('-789'), -789);
    });

    test('sanitizeInt применяет min/max', () {
      expect(InputSanitizer.sanitizeInt(5, min: 10), isNull);
      expect(InputSanitizer.sanitizeInt(15, max: 10), isNull);
      expect(InputSanitizer.sanitizeInt(10, min: 5, max: 15), 10);
    });

    test('sanitizeInt возвращает null для invalid input', () {
      expect(InputSanitizer.sanitizeInt('abc'), isNull);
      expect(InputSanitizer.sanitizeInt('12.34'), isNull);
      expect(InputSanitizer.sanitizeInt(null), isNull);
    });
  });

  group('InputSanitizer - Double', () {
    test('sanitizeDouble парсит double', () {
      expect(InputSanitizer.sanitizeDouble(12.34), 12.34);
      expect(InputSanitizer.sanitizeDouble('56.78'), 56.78);
      expect(InputSanitizer.sanitizeDouble(100), 100.0);
    });

    test('sanitizeDouble применяет min/max', () {
      expect(InputSanitizer.sanitizeDouble(5.5, min: 10.0), isNull);
      expect(InputSanitizer.sanitizeDouble(15.5, max: 10.0), isNull);
      expect(InputSanitizer.sanitizeDouble(10.5, min: 5.0, max: 15.0), 10.5);
    });

    test('sanitizeDouble возвращает null для invalid input', () {
      expect(InputSanitizer.sanitizeDouble('abc'), isNull);
      expect(InputSanitizer.sanitizeDouble(null), isNull);
    });
  });

  group('InputSanitizer - Email', () {
    test('isValidEmail принимает правильные email', () {
      expect(InputSanitizer.isValidEmail('user@example.com'), isTrue);
      expect(InputSanitizer.isValidEmail('john.doe@example.co.uk'), isTrue);
      expect(InputSanitizer.isValidEmail('test+tag@example.com'), isTrue);
    });

    test('isValidEmail отклоняет неправильные email', () {
      expect(InputSanitizer.isValidEmail('invalid'), isFalse);
      expect(InputSanitizer.isValidEmail('@example.com'), isFalse);
      expect(InputSanitizer.isValidEmail('user@'), isFalse);
      expect(InputSanitizer.isValidEmail('user@.com'), isFalse);
      expect(InputSanitizer.isValidEmail(''), isFalse);
    });

    test('isValidEmail отклоняет слишком длинные email', () {
      final longEmail = '${'a' * 250}@example.com';
      expect(InputSanitizer.isValidEmail(longEmail), isFalse);
    });
  });

  group('InputSanitizer - UUID', () {
    test('isValidUuid принимает правильные UUID', () {
      expect(InputSanitizer.isValidUuid('550e8400-e29b-41d4-a716-446655440000'), isTrue);
      expect(InputSanitizer.isValidUuid('6ba7b810-9dad-11d1-80b4-00c04fd430c8'), isTrue);
    });

    test('isValidUuid отклоняет неправильные UUID', () {
      expect(InputSanitizer.isValidUuid('invalid'), isFalse);
      expect(InputSanitizer.isValidUuid('550e8400-e29b-41d4-a716'), isFalse);
      expect(InputSanitizer.isValidUuid('550e8400e29b41d4a716446655440000'), isFalse); // No dashes
      expect(InputSanitizer.isValidUuid(''), isFalse);
    });
  });

  group('InputSanitizer - URL', () {
    test('isValidUrl принимает правильные URL', () {
      expect(InputSanitizer.isValidUrl('http://example.com'), isTrue);
      expect(InputSanitizer.isValidUrl('https://example.com'), isTrue);
      expect(InputSanitizer.isValidUrl('https://example.com/path?query=value'), isTrue);
    });

    test('isValidUrl отклоняет неправильные URL', () {
      expect(InputSanitizer.isValidUrl('ftp://example.com'), isFalse); // Wrong scheme
      expect(InputSanitizer.isValidUrl('example.com'), isFalse); // No scheme
      expect(InputSanitizer.isValidUrl(''), isFalse);
    });
  });

  group('InputSanitizer - HTML', () {
    test('sanitizeHtml удаляет HTML tags', () {
      expect(InputSanitizer.sanitizeHtml('<script>alert("xss")</script>'), 'alert("xss")');
      expect(InputSanitizer.sanitizeHtml('<b>bold</b> text'), 'bold text');
      expect(InputSanitizer.sanitizeHtml('<div><p>nested</p></div>'), 'nested');
    });

    test('sanitizeHtml декодирует HTML entities', () {
      expect(InputSanitizer.sanitizeHtml('&lt;test&gt;'), '<test>');
      expect(InputSanitizer.sanitizeHtml('&amp;&quot;&#39;'), '&"\'');
    });
  });

  group('InputSanitizer - JSON', () {
    test('sanitizeJson валидирует и форматирует JSON', () {
      expect(InputSanitizer.sanitizeJson('{"name":"John"}'), '{"name":"John"}');
      expect(InputSanitizer.sanitizeJson('[1,2,3]'), '[1,2,3]');
    });

    test('sanitizeJson возвращает null для invalid JSON', () {
      expect(InputSanitizer.sanitizeJson('{invalid}'), isNull);
      expect(InputSanitizer.sanitizeJson(''), isNull);
    });
  });

  group('InputSanitizer - Path', () {
    test('sanitizePath удаляет directory traversal', () {
      expect(InputSanitizer.sanitizePath('../etc/passwd'), isNull);
      expect(InputSanitizer.sanitizePath('~/secret'), isNull);
      expect(InputSanitizer.sanitizePath('../../file'), isNull);
    });

    test('sanitizePath принимает правильные пути', () {
      expect(InputSanitizer.sanitizePath('path/to/file.txt'), 'path/to/file.txt');
      expect(InputSanitizer.sanitizePath('file.txt'), 'file.txt');
      expect(InputSanitizer.sanitizePath('dir/subdir/'), 'dir/subdir');
    });

    test('sanitizePath удаляет leading/trailing slashes', () {
      expect(InputSanitizer.sanitizePath('/path/to/file'), 'path/to/file');
      expect(InputSanitizer.sanitizePath('path/to/file/'), 'path/to/file');
    });

    test('sanitizePath отклоняет special characters', () {
      expect(InputSanitizer.sanitizePath('path;rm -rf'), isNull);
      expect(InputSanitizer.sanitizePath('path|cat'), isNull);
    });
  });

  group('InputSanitizer - Date', () {
    test('sanitizeDate парсит ISO 8601', () {
      final date = InputSanitizer.sanitizeDate('2026-04-10T12:00:00Z');
      expect(date, isNotNull);
      expect(date!.year, 2026);
      expect(date.month, 4);
      expect(date.day, 10);
    });

    test('sanitizeDate возвращает null для invalid date', () {
      expect(InputSanitizer.sanitizeDate('invalid'), isNull);
      expect(InputSanitizer.sanitizeDate('not-a-date'), isNull);
      expect(InputSanitizer.sanitizeDate(''), isNull);
    });
  });

  group('InputSanitizer - Boolean', () {
    test('sanitizeBool парсит boolean', () {
      expect(InputSanitizer.sanitizeBool(true), isTrue);
      expect(InputSanitizer.sanitizeBool(false), isFalse);
      expect(InputSanitizer.sanitizeBool('true'), isTrue);
      expect(InputSanitizer.sanitizeBool('false'), isFalse);
      expect(InputSanitizer.sanitizeBool('1'), isTrue);
      expect(InputSanitizer.sanitizeBool('0'), isFalse);
      expect(InputSanitizer.sanitizeBool(1), isTrue);
      expect(InputSanitizer.sanitizeBool(0), isFalse);
    });

    test('sanitizeBool case-insensitive', () {
      expect(InputSanitizer.sanitizeBool('TRUE'), isTrue);
      expect(InputSanitizer.sanitizeBool('False'), isFalse);
      expect(InputSanitizer.sanitizeBool('YES'), isTrue);
      expect(InputSanitizer.sanitizeBool('no'), isFalse);
    });

    test('sanitizeBool возвращает null для invalid input', () {
      expect(InputSanitizer.sanitizeBool('invalid'), isNull);
      expect(InputSanitizer.sanitizeBool(2), isNull);
      expect(InputSanitizer.sanitizeBool(null), isNull);
    });
  });

  group('InputSanitizer - Phone', () {
    test('isValidPhone принимает правильные номера', () {
      expect(InputSanitizer.isValidPhone('1234567890'), isTrue);
      expect(InputSanitizer.isValidPhone('+1-234-567-8900'), isTrue);
      expect(InputSanitizer.isValidPhone('(123) 456-7890'), isTrue);
    });

    test('isValidPhone отклоняет неправильные номера', () {
      expect(InputSanitizer.isValidPhone('123'), isFalse); // Too short
      expect(InputSanitizer.isValidPhone('12345678901234567890'), isFalse); // Too long
      expect(InputSanitizer.isValidPhone('abc-def-ghij'), isFalse);
      expect(InputSanitizer.isValidPhone(''), isFalse);
    });
  });

  group('InputSanitizer - Alphanumeric', () {
    test('sanitizeAlphanumeric удаляет все кроме букв и цифр', () {
      expect(InputSanitizer.sanitizeAlphanumeric('abc123'), 'abc123');
      expect(InputSanitizer.sanitizeAlphanumeric('test@example.com'), 'testexamplecom');
      expect(InputSanitizer.sanitizeAlphanumeric('hello-world!'), 'helloworld');
    });
  });

  group('InputSanitizer - Credit Card', () {
    test('isValidCreditCard валидирует по Luhn algorithm', () {
      // Valid test card numbers
      expect(InputSanitizer.isValidCreditCard('4532015112830366'), isTrue); // Visa
      expect(InputSanitizer.isValidCreditCard('5425233430109903'), isTrue); // Mastercard
      expect(InputSanitizer.isValidCreditCard('4532-0151-1283-0366'), isTrue); // With dashes
    });

    test('isValidCreditCard отклоняет invalid numbers', () {
      expect(InputSanitizer.isValidCreditCard('1234567890123456'), isFalse); // Fails Luhn
      expect(InputSanitizer.isValidCreditCard('123'), isFalse); // Too short
      expect(InputSanitizer.isValidCreditCard('12345678901234567890'), isFalse); // Too long
      expect(InputSanitizer.isValidCreditCard(''), isFalse);
    });
  });
}
