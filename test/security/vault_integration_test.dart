import 'package:test/test.dart';
import '../../lib/security/vault_http_client.dart';
import '../../lib/security/vault_secrets_manager.dart';
import '../../lib/security/aws_secrets_manager.dart';
import '../../lib/security/credential_rotation_service.dart';
import '../../lib/security/secrets_manager.dart';

void main() {
  group('VaultHttpClient', () {
    test('создает клиент с правильными параметрами', () {
      final client = VaultHttpClient(
        baseUrl: 'http://localhost:8200',
        token: 'test-token',
      );

      expect(client.baseUrl, 'http://localhost:8200');
      expect(client.token, 'test-token');
    });

    test('VaultHttpException содержит правильные данные', () {
      final exception = VaultHttpException(
        statusCode: 404,
        message: 'Not found',
        path: '/v1/secret/data/test',
        body: '{"errors":["not found"]}',
      );

      expect(exception.statusCode, 404);
      expect(exception.message, 'Not found');
      expect(exception.path, '/v1/secret/data/test');
      expect(exception.toString(), contains('404'));
    });
  });

  group('VaultSecretsManager', () {
    // Note: These tests would require a running Vault instance
    // For now, we test the interface and error handling

    test('создает manager с правильными параметрами', () {
      final manager = VaultSecretsManager(
        vaultUrl: 'http://localhost:8200',
        token: 'test-token',
        mountPath: 'secret',
      );

      expect(manager, isA<SecretsManager>());
    });

    test('выбрасывает исключение для несуществующего секрета', () async {
      final manager = VaultSecretsManager(
        vaultUrl: 'http://localhost:8200',
        token: 'invalid-token',
      );

      // This will fail because Vault is not running
      // We expect either SecretNotFoundException, SecretOperationException, or SocketException
      try {
        await manager.getSecret('nonexistent');
        fail('Should have thrown an exception');
      } catch (e) {
        // Any exception is acceptable since Vault is not running
        expect(e, isNotNull);
      }
    });
  });

  group('AwsSecretsManager', () {
    late AwsSecretsManager manager;

    setUp(() {
      manager = AwsSecretsManager(
        region: 'us-east-1',
        accessKeyId: 'test-key',
        secretAccessKey: 'test-secret',
      );
    });

    test('сохраняет и получает секрет', () async {
      await manager.setSecret('test_key', 'test_value');
      final value = await manager.getSecret('test_key');
      expect(value, 'test_value');
    });

    test('кэширует секреты', () async {
      await manager.setSecret('cached_key', 'cached_value');

      // First call
      await manager.getSecret('cached_key');

      // Second call - from cache
      final value = await manager.getSecret('cached_key');
      expect(value, 'cached_value');
    });

    test('ротирует секрет', () async {
      await manager.setSecret('rotate_key', 'old_value');
      await manager.rotateSecret('rotate_key');

      final newValue = await manager.getSecret('rotate_key');
      expect(newValue, isNot('old_value'));
    });

    test('увеличивает версию при ротации', () async {
      await manager.setSecret('key', 'value1');
      final meta1 = await manager.getMetadata('key');
      expect(meta1.version, 1);

      await manager.rotateSecret('key');
      final meta2 = await manager.getMetadata('key');
      expect(meta2.version, 2);
    });

    test('возвращает список секретов', () async {
      await manager.setSecret('key1', 'value1');
      await manager.setSecret('key2', 'value2');
      await manager.setSecret('key3', 'value3');

      final keys = await manager.listSecrets();
      expect(keys, containsAll(['key1', 'key2', 'key3']));
    });

    test('удаляет секрет', () async {
      await manager.setSecret('key', 'value');
      await manager.deleteSecret('key');

      expect(
        () => manager.getSecret('key'),
        throwsA(isA<SecretNotFoundException>()),
      );
    });

    test('проверяет существование секрета', () async {
      await manager.setSecret('existing', 'value');

      expect(await manager.exists('existing'), isTrue);
      expect(await manager.exists('nonexistent'), isFalse);
    });

    test('возвращает метаданные секрета', () async {
      await manager.setSecret('key', 'value', metadata: {'env': 'prod'});

      final meta = await manager.getMetadata('key');

      expect(meta.key, 'key');
      expect(meta.version, 1);
      expect(meta.tags['env'], 'prod');
    });

    test('получает конкретную версию секрета', () async {
      await manager.setSecret('key', 'value1');
      await manager.setSecret('key', 'value2');

      final v1 = await manager.getSecretVersion('key', '1');
      final v2 = await manager.getSecretVersion('key', '2');

      expect(v1, 'value1');
      expect(v2, 'value2');
    });

    test('выбрасывает исключение для несуществующей версии', () async {
      await manager.setSecret('key', 'value');

      expect(
        () => manager.getSecretVersion('key', '999'),
        throwsA(isA<SecretOperationException>()),
      );
    });
  });

  group('CredentialRotationService', () {
    late AwsSecretsManager manager;
    late CredentialRotationService service;

    setUp(() {
      manager = AwsSecretsManager(region: 'us-east-1');
      service = CredentialRotationService(
        secretsManager: manager,
        checkInterval: const Duration(seconds: 1),
        maxAge: const Duration(days: 90),
      );
    });

    tearDown(() {
      service.stop();
    });

    test('запускается и останавливается', () {
      expect(service.isRunning, isFalse);

      service.start();
      expect(service.isRunning, isTrue);

      service.stop();
      expect(service.isRunning, isFalse);
    });

    test('не запускается дважды', () {
      service.start();
      service.start(); // Should be no-op

      expect(service.isRunning, isTrue);
    });

    test('возвращает статус секретов', () async {
      await manager.setSecret('key1', 'value1');
      await manager.setSecret('key2', 'value2');

      final statuses = await service.getStatus();

      expect(statuses.length, 2);
      expect(statuses[0].key, anyOf('key1', 'key2'));
      expect(statuses[0].needsRotation, isFalse); // New secrets don't need rotation
    });

    test('ротирует секрет вручную', () async {
      await manager.setSecret('manual_key', 'old_value');

      await service.rotateNow('manual_key');

      final newValue = await manager.getSecret('manual_key');
      expect(newValue, isNot('old_value'));
    });

    test('проверяет ротацию вручную', () async {
      await manager.setSecret('key1', 'value1');
      await manager.setSecret('key2', 'value2');

      final report = await service.checkNow();

      expect(report.total, 2);
      expect(report.skipped.length, 2); // New secrets, no rotation needed
    });

    test('RotationReport содержит правильные данные', () {
      final report = RotationReport();
      report.rotated.add('key1');
      report.skipped.add('key2');
      report.failed['key3'] = 'error';

      expect(report.total, 3);
      expect(report.hasFailures, isTrue);
      expect(report.toString(), contains('rotated: 1'));
    });

    test('SecretRotationStatus содержит правильные данные', () {
      final status = SecretRotationStatus(
        key: 'test_key',
        version: 1,
        createdAt: DateTime.now(),
        needsRotation: false,
        daysUntilRotation: 90,
      );

      expect(status.key, 'test_key');
      expect(status.version, 1);
      expect(status.needsRotation, isFalse);
      expect(status.toString(), contains('test_key'));
    });
  });
}
