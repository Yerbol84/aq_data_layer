/// AQ Data Layer — Полный пример всех сценариев хранения.
///
/// Запуск:
///   cd example/stack && docker compose up -d
///   dart run example/stack/console_client/main_scenarios.dart
library;

import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint = Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';
const _tenant = 'demo-tenant';
const _actor = 'user-demo';

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  AQ Data Layer — All Scenarios');
  print('═══════════════════════════════════════════════════════════\n');

  print('🔌 Connecting to $_endpoint ...');
  await initializeDataLayer(endpoint: _endpoint, tenantId: _tenant, useBuffer: false);

  if (!IDataLayer.instance.isConnected) {
    print('❌ Not connected. Start Docker stack:');
    print('   cd example/stack && docker compose up -d');
    exit(1);
  }
  print('✅ Connected. Server: ${IDataLayer.instance.serverVersion}\n');

  await _scenario1_direct_project();
  await _scenario2_direct_run_state();
  await _scenario3_versioned_workflow();
  await _scenario4_logged_run();

  print('\n═══════════════════════════════════════════════════════════');
  print('  ✅ All scenarios completed');
  print('═══════════════════════════════════════════════════════════');
}

// ── 1. Direct — AqStudioProject ──────────────────────────────────────────────

Future<void> _scenario1_direct_project() async {
  await _section('1. DIRECT — AqStudioProject');
  final repo = IDataLayer.instance.direct<AqStudioProject>(
    collection: AqStudioProject.kCollection,
    fromMap: AqStudioProject.fromMap,
  );

  final project = AqStudioProject.create(
    id: 'proj-${_ts()}',
    tenantId: _tenant,
    ownerId: _actor,
    name: 'Demo Project',
    projectType: 'workflow',
  );

  await repo.save(project);
  _ok('save: ${project.id}');

  final found = await repo.findById(project.id);
  assert(found != null);
  _ok('findById: ${found!.name}');

  final updated = AqStudioProject(
    id: project.id,
    tenantId: _tenant,
    ownerId: _actor,
    name: 'Demo Project (updated)',
    path: project.path,
    projectType: project.projectType,
    lastOpened: DateTime.now(),
  );
  await repo.save(updated);
  _ok('update: ${updated.name}');

  final list = await repo.findAll(
    query: VaultQuery().where('projectType', VaultOperator.equals, 'workflow'),
  );
  _ok('findAll (projectType=workflow): ${list.length} items');

  final page = await repo.findPage(VaultQuery(limit: 5, offset: 0));
  _ok('findPage: ${page.items.length} items, total=${page.total}');

  await repo.delete(project.id);
  final afterDelete = await repo.findById(project.id);
  _ok('delete → ${afterDelete == null ? "hard deleted" : "soft deleted"}');
}

// ── 2. Direct — GraphRunState ─────────────────────────────────────────────────

Future<void> _scenario2_direct_run_state() async {
  await _section('2. DIRECT — GraphRunState');
  final repo = IDataLayer.instance.direct<GraphRunState>(
    collection: 'graph_run_states',
    fromMap: GraphRunState.fromJson,
  );

  final state = GraphRunState(
    runId: 'run-${_ts()}',
    blueprintId: 'bp-001',
    projectId: 'proj-001',
    status: GraphRunStatus.running,
    startedAt: DateTime.now(),
  );

  await repo.save(state);
  _ok('save: ${state.runId}');

  final running = await repo.findAll(
    query: VaultQuery().where('status', VaultOperator.equals, 'running'),
  );
  _ok('findAll (status=running): ${running.length} items');

  final completed = GraphRunState(
    runId: state.runId,
    blueprintId: state.blueprintId,
    projectId: state.projectId,
    status: GraphRunStatus.completed,
    startedAt: state.startedAt,
    completedAt: DateTime.now(),
  );
  await repo.save(completed);
  _ok('update → completed');

  await repo.delete(state.runId);
  _ok('cleanup: deleted');
}

// ── 3. Versioned — WorkflowGraph ─────────────────────────────────────────────

Future<void> _scenario3_versioned_workflow() async {
  await _section('3. VERSIONED — WorkflowGraph');
  final repo = IDataLayer.instance.versioned<WorkflowGraph>(
    collection: WorkflowGraph.kCollection,
    fromMap: WorkflowGraph.fromMap,
  );

  final graph = WorkflowGraph(
    id: 'wf-${_ts()}',
    tenantId: _tenant,
    ownerId: _actor,
    name: 'Demo Workflow',
  );

  // Создать черновик
  final node = await repo.createEntity(graph);
  _ok('createEntity (draft): nodeId=${node.nodeId}, status=${node.status.name}');
  assert(node.status == VersionStatus.draft);

  // Редактировать черновик
  final v2 = WorkflowGraph(
    id: graph.id,
    tenantId: _tenant,
    ownerId: _actor,
    name: 'Demo Workflow v2',
  );
  await repo.updateDraft(node.nodeId, v2);
  _ok('updateDraft: name → ${v2.name}');

  // Опубликовать
  final published = await repo.publishDraft(
    node.nodeId,
    increment: IncrementType.minor,
  );
  _ok('publishDraft: version=${published.version}, status=${published.status.name}');
  assert(published.status == VersionStatus.published);

  // Создать ветку
  final branch = await repo.createBranch(
    published.nodeId,
    branchName: 'feature/new-step',
    model: v2,
  );
  _ok('createBranch: nodeId=${branch.nodeId}');

  // История версий
  final history = await repo.listVersions(graph.id);
  _ok('listVersions: ${history.length} nodes');

  // Последняя опубликованная
  final latest = await repo.getLatestPublished(graph.id);
  _ok('getLatestPublished: version=${latest?.version}');

  // Получить текущую версию
  final current = await repo.getCurrent(graph.id);
  _ok('getCurrent: ${current?.name}');

  // Выдать доступ
  await repo.grantAccess(
    graph.id,
    actorId: 'user-2',
    level: AccessLevel.read,
    requesterId: _actor,
  );
  _ok('grantAccess: user-2 → read');

  final grants = await repo.listGrants(graph.id);
  _ok('listGrants: ${grants.length} grants');

  await repo.revokeAccess(graph.id, actorId: 'user-2', requesterId: _actor);
  _ok('revokeAccess: user-2');

  // Удалить (soft delete для versioned)
  await repo.deleteEntity(graph.id);
  _ok('deleteEntity (soft delete)');
}

// ── 4. Logged — WorkflowRun ───────────────────────────────────────────────────

Future<void> _scenario4_logged_run() async {
  await _section('4. LOGGED — WorkflowRun');
  final repo = IDataLayer.instance.logged<WorkflowRun>(
    collection: WorkflowRun.kCollection,
    fromMap: WorkflowRun.fromMap,
  );

  final run = WorkflowRun(
    id: 'run-${_ts()}',
    projectId: 'proj-001',
    blueprintId: 'bp-001',
    graphSnapshot: const {'version': '1.0'},
    status: WorkflowRunStatus.running,
    logsJson: '[]',
    createdAt: DateTime.now(),
  );

  // Создать — автоматически логируется
  await repo.save(run, actorId: _actor);
  _ok('save (logged): ${run.id}');

  // Обновить статус — diff сохраняется в лог
  final completed = WorkflowRun(
    id: run.id,
    projectId: run.projectId,
    blueprintId: run.blueprintId,
    graphSnapshot: run.graphSnapshot,
    status: WorkflowRunStatus.completed,
    logsJson: '["step1 done","step2 done"]',
    createdAt: run.createdAt,
  );
  await repo.save(completed, actorId: _actor);
  _ok('update status → completed (logged)');

  // Получить историю изменений
  final history = await repo.getHistory(run.id);
  _ok('getHistory: ${history.length} entries');
  for (final entry in history) {
    print('     [${entry.operation.name}] by: ${entry.changedBy}, diff: ${entry.diff.keys.join(", ")}');
  }

  // Найти все completed
  final completedRuns = await repo.findAll(
    query: VaultQuery().where('status', VaultOperator.equals, 'completed'),
  );
  _ok('findAll (status=completed): ${completedRuns.length} items');

  // Rollback к первой записи
  if (history.length >= 2) {
    await repo.rollbackTo(run.id, history.first.entryId, actorId: _actor);
    _ok('rollbackTo: first entry');
  }

  // Удалить — лог сохраняется
  await repo.delete(run.id, actorId: _actor);
  _ok('delete (log preserved)');
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _ts() => DateTime.now().millisecondsSinceEpoch.toString();

Future<void> _section(String title) async {
  print('\n───────────────────────────────────────────────────────────');
  print('  $title');
  print('───────────────────────────────────────────────────────────');
}

void _ok(String msg) => print('  ✅ $msg');
