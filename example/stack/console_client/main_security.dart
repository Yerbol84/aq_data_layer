/// AQ Data Layer — Security Gate Scenarios
///
/// Требует: сервер запущен с SECURITY_MODE=mock
///
/// Сценарии:
///   A. Dev mode (без security) — всё разрешено
///   B. Admin token — все операции разрешены
///   C. Readonly token — read OK, write/delete → SecurityException
///   D. Blocked token — все операции запрещены
library;

import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint =
    Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  AQ Data Layer — Security Gate Scenarios');
  print('═══════════════════════════════════════════════════════════\n');

  int passed = 0;
  int failed = 0;

  Future<void> run(String name, Future<void> Function() fn) async {
    try {
      await fn();
      passed++;
    } catch (e, st) {
      print('  ❌ FAILED: $e');
      print('     $st');
      failed++;
    }
  }

  await run('B. Admin token — all allowed', _scenarioAdmin);
  await run('C. Readonly token — write denied', _scenarioReadonly);
  await run('D. Blocked token — all denied', _scenarioBlocked);
  await run('E. No token — write denied', _scenarioAnonymous);

  print('\n═══════════════════════════════════════════════════════════');
  print('  Results: $passed passed, $failed failed');
  print('═══════════════════════════════════════════════════════════');

  if (failed > 0) exit(1);
}

// ── B. Admin token ────────────────────────────────────────────────────────────

Future<void> _scenarioAdmin() async {
  _section('B. ADMIN TOKEN — all operations allowed');

  final vault = await Vault.remote(
    endpoint: _endpoint,
    tenantId: 'test-tenant',
    useBuffer: false,
    failFast: true,
    authToken: TestTokens.admin,
  );

  final repo = vault.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  final id = 'sec-admin-${_ts()}';
  final project = AqStudioProject.create(
    id: id,
    tenantId: 'test-tenant',
    ownerId: 'admin-user-id',
    name: 'Admin Project',
    projectType: 'security-test',
  );

  await repo.save(project);
  _ok('save: allowed ✓');

  final found = await repo.findById(id);
  _assert(found != null, 'findById must return result');
  _ok('findById: allowed ✓');

  await repo.delete(id);
  _ok('delete: allowed ✓');
}

// ── C. Readonly token ─────────────────────────────────────────────────────────

Future<void> _scenarioReadonly() async {
  _section('C. READONLY TOKEN — read allowed, write/delete denied');

  // First create a record with admin token
  final adminVault = await Vault.remote(
    endpoint: _endpoint,
    tenantId: 'test-tenant',
    useBuffer: false,
    failFast: true,
    authToken: TestTokens.admin,
  );
  final adminRepo = adminVault.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );
  final id = 'sec-readonly-${_ts()}';
  await adminRepo.save(AqStudioProject.create(
    id: id,
    tenantId: 'test-tenant',
    ownerId: 'admin-user-id',
    name: 'Readonly Test Project',
    projectType: 'security-test',
  ));

  // Now use readonly token
  final roVault = await Vault.remote(
    endpoint: _endpoint,
    tenantId: 'test-tenant',
    useBuffer: false,
    failFast: true,
    authToken: TestTokens.readonly,
  );
  final roRepo = roVault.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  // Read should work
  final found = await roRepo.findById(id);
  _assert(found != null, 'findById must work for readonly user');
  _ok('findById: allowed ✓');

  final all = await roRepo.findAll();
  _assert(all.isNotEmpty, 'findAll must work for readonly user');
  _ok('findAll: allowed ✓');

  // Write should be denied
  bool writeDenied = false;
  try {
    await roRepo.save(AqStudioProject.create(
      id: 'sec-readonly-write-${_ts()}',
      tenantId: 'test-tenant',
      ownerId: 'readonly-user-id',
      name: 'Should Fail',
      projectType: 'security-test',
    ));
  } catch (e) {
    writeDenied = e.toString().contains('denied') ||
        e.toString().contains('ACCESS_DENIED') ||
        e.toString().contains('VaultAccessDenied');
  }
  _assert(writeDenied, 'write must be denied for readonly user');
  _ok('save: denied ✓');

  // Delete should be denied
  bool deleteDenied = false;
  try {
    await roRepo.delete(id);
  } catch (e) {
    deleteDenied = e.toString().contains('denied') ||
        e.toString().contains('ACCESS_DENIED') ||
        e.toString().contains('VaultAccessDenied');
  }
  _assert(deleteDenied, 'delete must be denied for readonly user');
  _ok('delete: denied ✓');

  // Cleanup with admin
  await adminRepo.delete(id);
}

// ── D. Blocked token ──────────────────────────────────────────────────────────

Future<void> _scenarioBlocked() async {
  _section('D. BLOCKED TOKEN — all operations denied');

  final vault = await Vault.remote(
    endpoint: _endpoint,
    tenantId: 'test-tenant',
    useBuffer: false,
    failFast: true,
    authToken: TestTokens.blocked,
  );
  final repo = vault.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  bool readDenied = false;
  try {
    await repo.findAll();
  } catch (e) {
    readDenied = e.toString().contains('denied') ||
        e.toString().contains('ACCESS_DENIED') ||
        e.toString().contains('VaultAccessDenied') ||
        e.toString().contains('blocked');
  }
  _assert(readDenied, 'findAll must be denied for blocked user');
  _ok('findAll: denied ✓');

  bool writeDenied = false;
  try {
    await repo.save(AqStudioProject.create(
      id: 'sec-blocked-${_ts()}',
      tenantId: 'test-tenant',
      ownerId: 'blocked-user-id',
      name: 'Should Fail',
      projectType: 'security-test',
    ));
  } catch (e) {
    writeDenied = e.toString().contains('denied') ||
        e.toString().contains('ACCESS_DENIED') ||
        e.toString().contains('VaultAccessDenied') ||
        e.toString().contains('blocked');
  }
  _assert(writeDenied, 'save must be denied for blocked user');
  _ok('save: denied ✓');
}

// ── E. No token (anonymous) ───────────────────────────────────────────────────

Future<void> _scenarioAnonymous() async {
  _section('E. NO TOKEN — write denied (anonymous)');

  final vault = await Vault.remote(
    endpoint: _endpoint,
    tenantId: 'test-tenant',
    useBuffer: false,
    failFast: true,
    // No authToken
  );
  final repo = vault.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  bool writeDenied = false;
  try {
    await repo.save(AqStudioProject.create(
      id: 'sec-anon-${_ts()}',
      tenantId: 'test-tenant',
      ownerId: 'anonymous',
      name: 'Should Fail',
      projectType: 'security-test',
    ));
  } catch (e) {
    writeDenied = e.toString().contains('denied') ||
        e.toString().contains('ACCESS_DENIED') ||
        e.toString().contains('VaultAccessDenied') ||
        e.toString().contains('Authentication');
  }
  _assert(writeDenied, 'write must be denied for anonymous user');
  _ok('save: denied ✓');
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _ts() => DateTime.now().millisecondsSinceEpoch.toString();

void _section(String title) {
  print('\n───────────────────────────────────────────────────────────');
  print('  $title');
  print('───────────────────────────────────────────────────────────');
}

void _ok(String msg) => print('  ✅ $msg');

void _assert(bool condition, String message) {
  if (!condition) throw AssertionError(message);
}
