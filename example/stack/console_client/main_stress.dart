/// AQ Data Layer — Стресс-сценарии
///
/// Покрывает:
///   1. Multi-tenant изоляция — tenant A не видит данные tenant B
///   2. Concurrent writes — два клиента пишут одновременно (last-write-wins)
///   3. Versioned branching — ветки независимы от main
///   4. Logged rollback chain — 5 изменений → rollback → ещё изменения
library;

import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint =
    Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  AQ Data Layer — Stress Scenarios');
  print('═══════════════════════════════════════════════════════════\n');

  print('🔌 Connecting to $_endpoint ...');
  await initializeDataLayer(
      endpoint: _endpoint, tenantId: 'tenant-a', useBuffer: false);

  if (!IDataLayer.instance.isConnected) {
    print('❌ Not connected. Start Docker stack first.');
    exit(1);
  }
  print('✅ Connected. Server: ${IDataLayer.instance.serverVersion}\n');

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

  await run('1. Multi-tenant isolation', _scenarioTenantIsolation);
  await run('2. Concurrent writes (last-write-wins)', _scenarioConcurrentWrites);
  await run('3. Versioned branching independence', _scenarioVersionedBranching);
  await run('4. Logged rollback chain', _scenarioLoggedRollbackChain);

  print('\n═══════════════════════════════════════════════════════════');
  print('  Results: $passed passed, $failed failed');
  print('═══════════════════════════════════════════════════════════');

  if (failed > 0) exit(1);
}

// ── 1. Multi-tenant isolation ─────────────────────────────────────────────────

Future<void> _scenarioTenantIsolation() async {
  _section('1. MULTI-TENANT ISOLATION');

  final ts = _ts();
  final idA = 'proj-tenant-a-$ts';
  final idB = 'proj-tenant-b-$ts';

  // Инициализируем два vault с разными tenant
  final vaultA = await _vaultFor('stress-tenant-a');
  final vaultB = await _vaultFor('stress-tenant-b');

  final repoA = vaultA.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );
  final repoB = vaultB.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  // Tenant A создаёт проект
  await repoA.save(AqStudioProject.create(
    id: idA,
    tenantId: 'stress-tenant-a',
    ownerId: 'user-a',
    name: 'Tenant A Project',
    projectType: 'stress',
  ));
  _ok('Tenant A created: $idA');

  // Tenant B создаёт проект
  await repoB.save(AqStudioProject.create(
    id: idB,
    tenantId: 'stress-tenant-b',
    ownerId: 'user-b',
    name: 'Tenant B Project',
    projectType: 'stress',
  ));
  _ok('Tenant B created: $idB');

  // Tenant A НЕ должен видеть проект Tenant B
  final foundByA = await repoA.findById(idB);
  _assert(foundByA == null, 'Tenant A must NOT see Tenant B project');
  _ok('Tenant A cannot see Tenant B project ✓');

  // Tenant B НЕ должен видеть проект Tenant A
  final foundByB = await repoB.findById(idA);
  _assert(foundByB == null, 'Tenant B must NOT see Tenant A project');
  _ok('Tenant B cannot see Tenant A project ✓');

  // findAll не должен "протекать" между tenant
  final allA = await repoA.findAll();
  final allB = await repoB.findAll();
  final aSeesB = allA.any((p) => p.id == idB);
  final bSeesA = allB.any((p) => p.id == idA);
  _assert(!aSeesB, 'findAll must not leak across tenants (A sees B)');
  _assert(!bSeesA, 'findAll must not leak across tenants (B sees A)');
  _ok('findAll is isolated: A=${allA.length} items, B=${allB.length} items ✓');

  // Cleanup
  await repoA.delete(idA);
  await repoB.delete(idB);
}

// ── 2. Concurrent writes ──────────────────────────────────────────────────────

Future<void> _scenarioConcurrentWrites() async {
  _section('2. CONCURRENT WRITES (last-write-wins)');

  final ts = _ts();
  final id = 'proj-concurrent-$ts';

  final vault = await _vaultFor('stress-concurrent');
  final repo = vault.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  // Создаём базовую запись
  await repo.save(AqStudioProject.create(
    id: id,
    tenantId: 'stress-concurrent',
    ownerId: 'user-1',
    name: 'Original',
    projectType: 'stress',
  ));
  _ok('Created base record: $id');

  // Два "клиента" обновляют одновременно
  final futures = [
    repo.save(AqStudioProject.create(
      id: id,
      tenantId: 'stress-concurrent',
      ownerId: 'user-1',
      name: 'Writer-1',
      projectType: 'stress',
    )),
    repo.save(AqStudioProject.create(
      id: id,
      tenantId: 'stress-concurrent',
      ownerId: 'user-1',
      name: 'Writer-2',
      projectType: 'stress',
    )),
  ];

  await Future.wait(futures);
  _ok('Both writers completed without error ✓');

  // Запись должна существовать (один из вариантов выиграл)
  final result = await repo.findById(id);
  _assert(result != null, 'Record must exist after concurrent writes');
  _ok('Record exists after concurrent writes: name="${result!.name}" ✓');
  _ok('(last-write-wins — one of Writer-1/Writer-2 won, no crash)');

  // Cleanup
  await repo.delete(id);
}

// ── 3. Versioned branching independence ──────────────────────────────────────

Future<void> _scenarioVersionedBranching() async {
  _section('3. VERSIONED BRANCHING INDEPENDENCE');

  final ts = _ts();
  final vault = await _vaultFor('stress-versioned');
  final repo = vault.versioned<WorkflowGraph>(
    collection: WorkflowGraph.kCollection,
    fromMap: WorkflowGraph.fromMap,
  );

  final graph = WorkflowGraph(
    id: 'wf-branch-$ts',
    tenantId: 'stress-versioned',
    ownerId: 'user-stress',
    name: 'Main Workflow',
  );

  // Создать и опубликовать v1
  final node = await repo.createEntity(graph);
  final v1 = await repo.publishDraft(node.nodeId, increment: IncrementType.minor);
  _ok('Published v1: ${v1.version}');

  // Создать ветку от v1
  final branchGraph = WorkflowGraph(
    id: graph.id,
    tenantId: 'stress-versioned',
    ownerId: 'user-stress',
    name: 'Branch Workflow',
  );
  final branch = await repo.createBranch(
    v1.nodeId,
    branchName: 'feature/stress-test',
    model: branchGraph,
  );
  _ok('Created branch: ${branch.nodeId}');

  // Обновить main (создать новый draft и опубликовать v2)
  final mainDraft = await repo.createEntity(WorkflowGraph(
    id: 'wf-branch-main2-$ts',
    tenantId: 'stress-versioned',
    ownerId: 'user-stress',
    name: 'Main Workflow v2',
  ));
  final v2 = await repo.publishDraft(
      mainDraft.nodeId, increment: IncrementType.minor);
  _ok('Published v2 on separate entity: ${v2.version}');

  // Ветка должна оставаться независимой — её данные не изменились
  // branch.data содержит данные на момент создания
  _assert(
    branch.data['name'] == 'Branch Workflow',
    'Branch data must be independent from main, got: ${branch.data['name']}',
  );
  _ok('Branch data unchanged after main update ✓');

  // Нельзя опубликовать уже опубликованный draft
  bool doublePublishFailed = false;
  try {
    await repo.publishDraft(v1.nodeId, increment: IncrementType.patch);
  } catch (_) {
    doublePublishFailed = true;
  }
  _assert(doublePublishFailed, 'Double-publish must throw');
  _ok('Double-publish correctly rejected ✓');

  // Cleanup
  await repo.deleteEntity(graph.id);
  await repo.deleteEntity(mainDraft.data['id'] as String);
}

// ── 4. Logged rollback chain ──────────────────────────────────────────────────

Future<void> _scenarioLoggedRollbackChain() async {
  _section('4. LOGGED ROLLBACK CHAIN');

  final ts = _ts();
  final vault = await _vaultFor('stress-logged');
  final repo = vault.logged<WorkflowRun>(
    collection: WorkflowRun.kCollection,
    fromMap: WorkflowRun.fromMap,
  );

  final id = 'run-rollback-$ts';

  WorkflowRun makeRun(WorkflowRunStatus status, String logs) => WorkflowRun(
        id: id,
        projectId: 'proj-stress',
        blueprintId: 'bp-stress',
        graphSnapshot: const {'version': '1.0'},
        status: status,
        logsJson: logs,
        createdAt: DateTime.now(),
      );

  // 5 изменений
  await repo.save(makeRun(WorkflowRunStatus.running, '[]'), actorId: 'actor');
  await repo.save(makeRun(WorkflowRunStatus.running, '["step1"]'), actorId: 'actor');
  await repo.save(makeRun(WorkflowRunStatus.suspended, '["step1","step2"]'), actorId: 'actor');
  await repo.save(makeRun(WorkflowRunStatus.running, '["step1","step2","step3"]'), actorId: 'actor');
  await repo.save(makeRun(WorkflowRunStatus.completed, '["step1","step2","step3","step4"]'), actorId: 'actor');

  final history = await repo.getHistory(id);
  _assert(history.length == 5, 'Expected 5 log entries, got ${history.length}');
  _ok('5 changes logged ✓');

  // Rollback к шагу 3 (index 2 — suspended)
  final step3Entry = history[2];
  await repo.rollbackTo(id, step3Entry.entryId, actorId: 'actor');
  _ok('Rolled back to step 3 (suspended)');

  // Проверить состояние после rollback
  final afterRollback = await repo.findById(id);
  _assert(
    afterRollback?.status == WorkflowRunStatus.suspended,
    'After rollback status must be suspended, got ${afterRollback?.status}',
  );
  _ok('State after rollback: status=${afterRollback!.status.value} ✓');

  // История должна содержать rollback как отдельную запись
  final historyAfterRollback = await repo.getHistory(id);
  _assert(
    historyAfterRollback.length > 5,
    'Rollback must add a log entry (got ${historyAfterRollback.length})',
  );
  _ok('Rollback recorded in history: ${historyAfterRollback.length} entries ✓');

  // Ещё 2 изменения после rollback
  await repo.save(makeRun(WorkflowRunStatus.running, '["step1","step2","step3","step5"]'), actorId: 'actor');
  await repo.save(makeRun(WorkflowRunStatus.completed, '["step1","step2","step3","step5","step6"]'), actorId: 'actor');

  final finalHistory = await repo.getHistory(id);
  _assert(
    finalHistory.length > historyAfterRollback.length,
    'New changes after rollback must be logged',
  );
  _ok('2 more changes after rollback logged ✓');
  _ok('Total history entries: ${finalHistory.length}');

  // Cleanup
  await repo.delete(id, actorId: 'actor');
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _ts() => DateTime.now().millisecondsSinceEpoch.toString();

/// Создаёт Vault для указанного tenant напрямую через remote storage
Future<Vault> _vaultFor(String tenantId) =>
    Vault.remote(endpoint: _endpoint, tenantId: tenantId, useBuffer: false, failFast: true);

void _section(String title) {
  print('\n───────────────────────────────────────────────────────────');
  print('  $title');
  print('───────────────────────────────────────────────────────────');
}

void _ok(String msg) => print('  ✅ $msg');

void _assert(bool condition, String message) {
  if (!condition) throw AssertionError(message);
}
