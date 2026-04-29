import 'dart:async';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/server.dart';
import 'package:test/test.dart';
import 'package:dart_vault/dart_vault.dart';
import 'test_helpers.dart';

void main() {
  group('LoggedRepository', () {
    late Vault vault;
    late LoggedRepository<Task> repo;

    setUp(() {
      vault = Vault();
      repo = vault.logged<Task>(
        collection: 'tasks',
        fromMap: Task.fromMap,
        captureFullSnapshot: true,
      );
    });

    tearDown(() => vault.dispose());

    Task _task(String id,
            {String status = 'open', String assignee = 'alice'}) =>
        Task(id: id, title: 'Task $id', status: status, assigneeId: assignee);

    // ── Save & Read ─────────────────────────────────────────────────────────

    test('save then findById', () async {
      await repo.save(_task('t1'), actorId: 'system');
      final found = await repo.findById('t1');
      expect(found, isNotNull);
      expect(found!.status, 'open');
    });

    test('save creates a log entry', () async {
      await repo.save(_task('t1'), actorId: 'system');
      final history = await repo.getHistory('t1');
      expect(history.length, 1);
      expect(history.first.operation, LogOperation.created);
      expect(history.first.changedBy, 'system');
    });

    test('update creates updated log entry with diff', () async {
      await repo.save(_task('t1', status: 'open'), actorId: 'system');
      await repo.save(_task('t1', status: 'inProgress'), actorId: 'alice');

      final history = await repo.getHistory('t1');
      expect(history.length, 2);

      final updateEntry = history[1];
      expect(updateEntry.operation, LogOperation.updated);
      expect(updateEntry.diff.containsKey('status'), isTrue);
      expect(updateEntry.diff['status']!.before, 'open');
      expect(updateEntry.diff['status']!.after, 'inProgress');
    });

    test('only tracked fields appear in diff', () async {
      // trackedFields = {'status', 'assigneeId'} — 'title' is not tracked
      await repo.save(_task('t1', status: 'open'), actorId: 'system');
      // Change title + status — only status diff should be recorded
      await repo.save(
        Task(
            id: 't1',
            title: 'Changed Title',
            status: 'done',
            assigneeId: 'alice'),
        actorId: 'alice',
      );
      final history = await repo.getHistory('t1');
      final diff = history.last.diff;
      expect(diff.containsKey('status'), isTrue);
      expect(diff.containsKey('title'), isFalse); // not in trackedFields
    });

    test('snapshot captured when captureFullSnapshot=true', () async {
      await repo.save(_task('t1', status: 'open'), actorId: 'system');
      final history = await repo.getHistory('t1');
      expect(history.first.snapshot, isNotNull);
      expect(history.first.snapshot!['status'], 'open');
    });

    // ── Delete ──────────────────────────────────────────────────────────────

    test('delete removes entity and records deleted entry', () async {
      await repo.save(_task('t1'), actorId: 'system');
      await repo.delete('t1', actorId: 'admin');

      expect(await repo.findById('t1'), isNull);
      final history = await repo.getHistory('t1');
      expect(history.last.operation, LogOperation.deleted);
    });

    // ── History ─────────────────────────────────────────────────────────────

    test('getHistory returns entries in chronological order', () async {
      await repo.save(_task('t1', status: 'open'), actorId: 'system');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await repo.save(_task('t1', status: 'inProgress'), actorId: 'alice');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await repo.save(_task('t1', status: 'done'), actorId: 'alice');

      final history = await repo.getHistory('t1');
      expect(history.length, 3);
      final ops = history.map((e) => e.operation).toList();
      expect(ops, [
        LogOperation.created,
        LogOperation.updated,
        LogOperation.updated,
      ]);
    });

    test('getLastEntry returns most recent log entry', () async {
      await repo.save(_task('t1', status: 'open'), actorId: 'system');
      await repo.save(_task('t1', status: 'done'), actorId: 'alice');

      final last = await repo.getLastEntry('t1');
      expect(last?.diff['status']?.after, 'done');
    });

    test('getHistory for unknown entity returns empty list', () async {
      final history = await repo.getHistory('ghost');
      expect(history, isEmpty);
    });

    // ── Time-travel ──────────────────────────────────────────────────────────

    test('getStateAt returns state at a given moment', () async {
      await repo.save(_task('t1', status: 'open'), actorId: 'system');
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final afterOpen = DateTime.now();
      await Future<void>.delayed(const Duration(milliseconds: 2));

      await repo.save(_task('t1', status: 'done'), actorId: 'alice');

      final state = await repo.getStateAt('t1', afterOpen);
      expect(state?.status, 'open');
    });

    test('getStateAt returns null before creation', () async {
      await repo.save(_task('t1'), actorId: 'system');
      final past = DateTime.now().subtract(const Duration(hours: 1));
      expect(await repo.getStateAt('t1', past), isNull);
    });

    // ── Rollback ─────────────────────────────────────────────────────────────

    test('rollbackTo restores entity to target entry state', () async {
      await repo.save(_task('t1', status: 'open'), actorId: 'system');
      await repo.save(_task('t1', status: 'inProgress'), actorId: 'alice');
      await repo.save(_task('t1', status: 'done'), actorId: 'alice');

      final history = await repo.getHistory('t1');
      final openEntry = history.first;

      await repo.rollbackTo('t1', openEntry.entryId, actorId: 'admin');

      final restored = await repo.findById('t1');
      expect(restored?.status, 'open');
    });

    test('rollbackTo preserves history — does not truncate', () async {
      await repo.save(_task('t1', status: 'open'), actorId: 'system');
      await repo.save(_task('t1', status: 'done'), actorId: 'alice');

      final before = (await repo.getHistory('t1')).length;
      final firstEntry = (await repo.getHistory('t1')).first;

      await repo.rollbackTo('t1', firstEntry.entryId, actorId: 'admin');

      final after = (await repo.getHistory('t1')).length;
      expect(after, before + 1); // rollback adds a new entry
    });

    test('rollback entry references original entry id', () async {
      await repo.save(_task('t1', status: 'open'), actorId: 'system');
      await repo.save(_task('t1', status: 'done'), actorId: 'alice');

      final history = await repo.getHistory('t1');
      await repo.rollbackTo('t1', history.first.entryId, actorId: 'admin');

      final fullHistory = await repo.getHistory('t1');
      final rollbackEntry = fullHistory.last;
      expect(rollbackEntry.operation, LogOperation.rollback);
      expect(rollbackEntry.rollbackToEntryId, history.first.entryId);
    });

    test('rollbackTo unknown entry throws VaultNotFoundException', () async {
      await repo.save(_task('t1'), actorId: 'system');
      await expectLater(
        repo.rollbackTo('t1', 'ghost-entry', actorId: 'admin'),
        throwsA(isA<VaultNotFoundException>()),
      );
    });

    // ── History Pagination ───────────────────────────────────────────────────

    test('getHistoryPage paginates history', () async {
      for (var i = 0; i < 5; i++) {
        await repo.save(_task('t1', status: 'status-$i'), actorId: 'user');
      }
      final page = await repo.getHistoryPage(
        't1',
        VaultQuery().page(limit: 2, offset: 0),
      );
      expect(page.items.length, 2);
      expect(page.total, 5);
      expect(page.hasMore, isTrue);
    });

    // ── Collection log ───────────────────────────────────────────────────────

    test('getCollectionLog returns all log entries across entities', () async {
      await repo.save(_task('t1', status: 'open'), actorId: 'system');
      await repo.save(_task('t2', status: 'open'), actorId: 'system');
      await repo.save(_task('t1', status: 'done'), actorId: 'alice');

      final log = await repo.getCollectionLog();
      expect(log.length, 3);
    });

    test('getCollectionLog date range filter', () async {
      await repo.save(_task('t1', status: 'open'), actorId: 'system');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final midpoint = DateTime.now();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await repo.save(_task('t2', status: 'open'), actorId: 'system');

      final recent = await repo.getCollectionLog(from: midpoint);
      expect(recent.length, 1);
    });

    // ── findAll / count / pagination ─────────────────────────────────────────

    test('findAll with filter', () async {
      await repo.save(_task('t1', status: 'open'), actorId: 'system');
      await repo.save(_task('t2', status: 'done'), actorId: 'system');
      await repo.save(_task('t3', status: 'open'), actorId: 'system');

      final open = await repo.findAll(
        query: VaultQuery().where('status', VaultOperator.equals, 'open'),
      );
      expect(open.length, 2);
    });

    test('findPage returns paged results', () async {
      for (var i = 1; i <= 4; i++) {
        await repo.save(_task('t$i'), actorId: 'system');
      }
      final page = await repo.findPage(VaultQuery().page(limit: 2, offset: 0));
      expect(page.items.length, 2);
      expect(page.total, 4);
    });

    // ── Watch streams ────────────────────────────────────────────────────────

    test('watchAll emits on save', () async {
      final counts = <int>[];
      final done = Completer<void>();
      final sub = repo.watchAll().listen((list) {
        counts.add(list.length);
        if (counts.length >= 2) done.complete();
      });

      await repo.save(_task('t1'), actorId: 'system');
      await done.future.timeout(const Duration(seconds: 2));
      await sub.cancel();

      expect(counts, [0, 1]);
    });

    test('watchHistory emits when history changes', () async {
      await repo.save(_task('t1', status: 'open'), actorId: 'system');

      final histLengths = <int>[];
      final done = Completer<void>();
      final sub = repo.watchHistory('t1').listen((hist) {
        histLengths.add(hist.length);
        if (histLengths.length >= 2) done.complete();
      });

      await repo.save(_task('t1', status: 'done'), actorId: 'alice');
      await done.future.timeout(const Duration(seconds: 2));
      await sub.cancel();

      expect(histLengths.last, 2);
    });

    // ── Multi-tenancy ────────────────────────────────────────────────────────

    test('tenant isolation in logged repository', () async {
      // Each tenant needs its own VaultStorage with correct tenantId
      final storageAlice = InMemoryVaultStorage(tenantId: 'alice');
      final storageBob = InMemoryVaultStorage(tenantId: 'bob');
      final va = Vault(storage: storageAlice, tenantId: 'alice');
      final vb = Vault(storage: storageBob, tenantId: 'bob');

      final ra = va.logged<Task>(collection: 'tasks', fromMap: Task.fromMap);
      final rb = vb.logged<Task>(collection: 'tasks', fromMap: Task.fromMap);

      await ra.save(
          Task(id: 't1', title: 'A-Task', status: 'open', assigneeId: 'alice'),
          actorId: 'alice');
      await rb.save(
          Task(id: 't1', title: 'B-Task', status: 'done', assigneeId: 'bob'),
          actorId: 'bob');

      final alice = await ra.findById('t1');
      final bob = await rb.findById('t1');

      expect(alice!.title, 'A-Task');
      expect(bob!.title, 'B-Task');

      // History is also isolated
      final aliceHist = await ra.getHistory('t1');
      final bobHist = await rb.getHistory('t1');
      expect(aliceHist.length, 1);
      expect(bobHist.length, 1);
      expect(aliceHist.first.changedBy, 'alice');
      expect(bobHist.first.changedBy, 'bob');

      await va.dispose();
      await vb.dispose();
    });
  });
}
