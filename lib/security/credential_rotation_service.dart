import 'dart:async';
import 'secrets_manager.dart';

/// Automatic credential rotation service
///
/// Monitors secrets and automatically rotates them based on age.
/// Supports scheduled rotation and manual triggers.
class CredentialRotationService {
  final SecretsManager _secretsManager;
  final Duration _checkInterval;
  final Duration _maxAge;
  Timer? _timer;
  bool _isRunning = false;

  CredentialRotationService({
    required SecretsManager secretsManager,
    Duration checkInterval = const Duration(hours: 1),
    Duration maxAge = const Duration(days: 90),
  })  : _secretsManager = secretsManager,
        _checkInterval = checkInterval,
        _maxAge = maxAge;

  /// Start the rotation service
  void start() {
    if (_isRunning) return;

    _isRunning = true;
    _timer = Timer.periodic(_checkInterval, (_) => _checkRotations());
    print('🔄 Credential rotation service started');
  }

  /// Stop the rotation service
  void stop() {
    _timer?.cancel();
    _timer = null;
    _isRunning = false;
    print('⏹️  Credential rotation service stopped');
  }

  /// Check all secrets and rotate if needed
  Future<RotationReport> _checkRotations() async {
    final report = RotationReport();

    try {
      final secrets = await _secretsManager.listSecrets();
      print('🔍 Checking ${secrets.length} secrets for rotation...');

      for (final key in secrets) {
        try {
          final metadata = await _secretsManager.getMetadata(key);

          if (metadata.needsRotation(maxAge: _maxAge)) {
            print('🔄 Rotating secret: $key (age: ${metadata.daysUntilRotation(maxAge: _maxAge)} days)');
            await _rotateSecret(key, metadata);
            report.rotated.add(key);
          } else {
            report.skipped.add(key);
          }
        } catch (e) {
          print('❌ Failed to check/rotate secret $key: $e');
          report.failed[key] = e.toString();
        }
      }

      print('✅ Rotation check complete: ${report.rotated.length} rotated, ${report.skipped.length} skipped, ${report.failed.length} failed');
    } catch (e) {
      print('❌ Rotation check failed: $e');
    }

    return report;
  }

  /// Rotate a specific secret
  Future<void> _rotateSecret(String key, SecretMetadata metadata) async {
    try {
      // Rotate the secret
      await _secretsManager.rotateSecret(key);

      // Verify rotation
      final newMetadata = await _secretsManager.getMetadata(key);
      if (newMetadata.version <= metadata.version) {
        throw Exception('Rotation did not increment version');
      }

      print('✅ Secret rotated successfully: $key (v${metadata.version} → v${newMetadata.version})');
    } catch (e) {
      print('❌ Failed to rotate secret $key: $e');
      rethrow;
    }
  }

  /// Manually trigger rotation for a specific secret
  Future<void> rotateNow(String key) async {
    print('🔄 Manual rotation triggered for: $key');
    final metadata = await _secretsManager.getMetadata(key);
    await _rotateSecret(key, metadata);
  }

  /// Manually trigger rotation check for all secrets
  Future<RotationReport> checkNow() async {
    print('🔄 Manual rotation check triggered');
    return await _checkRotations();
  }

  /// Get rotation status for all secrets
  Future<List<SecretRotationStatus>> getStatus() async {
    final secrets = await _secretsManager.listSecrets();
    final statuses = <SecretRotationStatus>[];

    for (final key in secrets) {
      try {
        final metadata = await _secretsManager.getMetadata(key);
        statuses.add(SecretRotationStatus(
          key: key,
          version: metadata.version,
          createdAt: metadata.createdAt,
          lastRotated: metadata.lastRotated,
          needsRotation: metadata.needsRotation(maxAge: _maxAge),
          daysUntilRotation: metadata.daysUntilRotation(maxAge: _maxAge),
        ));
      } catch (e) {
        print('⚠️  Failed to get status for $key: $e');
      }
    }

    return statuses;
  }

  bool get isRunning => _isRunning;
}

/// Report of rotation check results
class RotationReport {
  final List<String> rotated = [];
  final List<String> skipped = [];
  final Map<String, String> failed = {};

  int get total => rotated.length + skipped.length + failed.length;
  bool get hasFailures => failed.isNotEmpty;

  @override
  String toString() {
    return 'RotationReport(rotated: ${rotated.length}, skipped: ${skipped.length}, failed: ${failed.length})';
  }
}

/// Status of a secret's rotation
class SecretRotationStatus {
  final String key;
  final int version;
  final DateTime createdAt;
  final DateTime? lastRotated;
  final bool needsRotation;
  final int daysUntilRotation;

  SecretRotationStatus({
    required this.key,
    required this.version,
    required this.createdAt,
    this.lastRotated,
    required this.needsRotation,
    required this.daysUntilRotation,
  });

  @override
  String toString() {
    return 'SecretRotationStatus($key: v$version, needs rotation: $needsRotation, days until: $daysUntilRotation)';
  }
}
