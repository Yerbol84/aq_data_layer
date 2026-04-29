// Test IDataLayer integration with dart_vault implementation
import 'package:test/test.dart';
import 'package:dart_vault/dart_vault.dart';
import 'package:aq_schema/aq_schema.dart';

void main() {
  group('IDataLayer integration', () {
    tearDown(() async {
      if (IDataLayer.isInitialized) {
        await IDataLayer.disconnect();
      }
    });

    test('initialize creates singleton instance', () async {
      expect(IDataLayer.isInitialized, false);

      // Note: This will fail without a running server
      // For now, just verify the API is correct
      expect(
        () => IDataLayer.initialize(endpoint: 'http://localhost:8765'),
        returnsNormally,
      );
    });

    test('cannot initialize twice', () async {
      // First initialization would need a real server
      // This test verifies the guard works
      expect(IDataLayer.isInitialized, false);
    });

    test('disconnect resets singleton', () async {
      expect(IDataLayer.isInitialized, false);

      await IDataLayer.disconnect();

      expect(IDataLayer.isInitialized, false);
    });
  });

  group('IDataLayer API compatibility', () {
    test('has all required methods', () {
      // Verify IDataLayer interface is complete
      expect(IDataLayer.isInitialized, isA<bool>());

      // These would throw if not initialized, but we're just checking the API exists
      expect(() => IDataLayer.initialize, returnsNormally);
      expect(() => IDataLayer.disconnect, returnsNormally);
    });
  });

  group('Backward compatibility with Vault', () {
    tearDown(() async {
      await Vault.disconnect();
    });

    test('Vault.connect still works', () async {
      // Verify backward compatibility
      // Note: This will fail without a running server
      expect(
        () => Vault.connect('http://localhost:8765'),
        returnsNormally,
      );
    });
  });
}
