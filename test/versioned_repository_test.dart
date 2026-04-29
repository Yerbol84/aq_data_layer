import 'dart:async';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/storage/in_memory_vault_storage.dart';
import 'package:test/test.dart';
import 'package:dart_vault/dart_vault.dart';
import 'test_helpers.dart';

void main() {
  group('VersionedRepository', () {
    late Vault vault;
    late VersionedRepository<Doc> repo;

    setUp(() {
      vault = Vault(tenantId: 'alice');
      repo = vault.versioned<Doc>(
        collection: 'docs',
        fromMap: Doc.fromMap,
      );
    });

    tearDown(() => vault.dispose());

    Doc _doc(String id, String title) =>
        Doc(id: id, tenantId: 'system', ownerId: 'alice', title: title);

    // ── Create ───────────────────────────────────────────────────────────────

    test('createEntity produces a DRAFT node', () async {
      final node = await repo.createEntity(_doc('doc-1', 'Hello'));
      expect(node.status, VersionStatus.draft);
      expect(node.version, isNull);
      expect(node.branch, 'main');
      expect(node.isCurrent, isFalse);
    });

    test('getCurrent returns null before any publish', () async {
      await repo.createEntity(_doc('doc-1', 'Hello'));
      expect(await repo.getCurrent('doc-1'), isNull);
    });

    // ── updateDraft ──────────────────────────────────────────────────────────

    test('updateDraft changes data of a draft node', () async {
      final node = await repo.createEntity(_doc('doc-1', 'Original'));
      await repo.updateDraft(node.nodeId, _doc('doc-1', 'Updated'));

      final versions = await repo.listVersions('doc-1');
      expect(versions.first.data['title'], 'Updated');
    });

    test('updateDraft throws on non-draft node', () async {
      final node = await repo.createEntity(_doc('doc-1', 'Hello'));
      await repo.publishDraft(node.nodeId, increment: IncrementType.major);

      await expectLater(
        repo.updateDraft(node.nodeId, _doc('doc-1', 'X')),
        throwsA(isA<VaultStateException>()),
      );
    });

    // ── Publish ──────────────────────────────────────────────────────────────

    test('publishDraft assigns correct semver — major', () async {
      final node = await repo.createEntity(_doc('doc-1', 'V1'));
      final published = await repo.publishDraft(
        node.nodeId,
        increment: IncrementType.major,
      );
      expect(published.status, VersionStatus.published);
      expect(published.version, Semver(1, 0, 0));
      expect(published.isCurrent, isTrue);
    });

    test('publishDraft minor increment from 1.0.0 → 1.1.0', () async {
      final n1 = await repo.createEntity(_doc('doc-1', 'V1'));
      await repo.publishDraft(n1.nodeId, increment: IncrementType.major);

      final draft =
          await repo.createDraftFrom(n1.nodeId, _doc('doc-1', 'V1.1'));
      final published = await repo.publishDraft(
        draft.nodeId,
        increment: IncrementType.minor,
      );
      expect(published.version, Semver(1, 1, 0));
    });

    test('publishDraft patch increment 1.1.0 → 1.1.1', () async {
      final n1 = await repo.createEntity(_doc('doc-1', 'V1'));
      final p1 =
          await repo.publishDraft(n1.nodeId, increment: IncrementType.major);

      final n2 = await repo.createDraftFrom(p1.nodeId, _doc('doc-1', 'V1.1'));
      final p2 =
          await repo.publishDraft(n2.nodeId, increment: IncrementType.minor);

      final n3 = await repo.createDraftFrom(p2.nodeId, _doc('doc-1', 'V1.1.1'));
      final p3 =
          await repo.publishDraft(n3.nodeId, increment: IncrementType.patch);
      expect(p3.version, Semver(1, 1, 1));
    });

    test('publishDraft non-draft throws', () async {
      final n1 = await repo.createEntity(_doc('doc-1', 'V1'));
      final p1 =
          await repo.publishDraft(n1.nodeId, increment: IncrementType.major);
      await expectLater(
        repo.publishDraft(p1.nodeId, increment: IncrementType.patch),
        throwsA(isA<VaultStateException>()),
      );
    });

    test('getCurrent returns published data', () async {
      final n1 = await repo.createEntity(_doc('doc-1', 'Published Title'));
      await repo.publishDraft(n1.nodeId, increment: IncrementType.major);
      final current = await repo.getCurrent('doc-1');
      expect(current, isNotNull);
      expect(current!.title, 'Published Title');
    });

    test('setCurrentVersion switches current to another published node',
        () async {
      final n1 = await repo.createEntity(_doc('doc-1', 'V1'));
      final p1 =
          await repo.publishDraft(n1.nodeId, increment: IncrementType.major);

      final n2 = await repo.createDraftFrom(p1.nodeId, _doc('doc-1', 'V2'));
      await repo.publishDraft(n2.nodeId, increment: IncrementType.minor);

      // Downgrade back to v1.0.0
      await repo.setCurrentVersion('doc-1', p1.nodeId, requesterId: 'alice');
      final current = await repo.getCurrent('doc-1');
      expect(current!.title, 'V1');
    });

    test('setCurrentVersion draft throws', () async {
      final n1 = await repo.createEntity(_doc('doc-1', 'draft'));
      await expectLater(
        repo.setCurrentVersion('doc-1', n1.nodeId, requesterId: 'alice'),
        throwsA(isA<VaultInvalidTransitionException>()),
      );
    });

    // ── Snapshot ─────────────────────────────────────────────────────────────

    test('snapshotVersion makes node immutable', () async {
      final n1 = await repo.createEntity(_doc('doc-1', 'V1'));
      final p1 =
          await repo.publishDraft(n1.nodeId, increment: IncrementType.major);
      final snap = await repo.snapshotVersion(p1.nodeId);
      expect(snap.status, VersionStatus.snapshot);
    });

    test('snapshotVersion on draft throws', () async {
      final n1 = await repo.createEntity(_doc('doc-1', 'V1'));
      await expectLater(
        repo.snapshotVersion(n1.nodeId),
        throwsA(isA<VaultStateException>()),
      );
    });

    // ── Delete ───────────────────────────────────────────────────────────────

    test('deleteVersion marks node as deleted', () async {
      final n1 = await repo.createEntity(_doc('doc-1', 'V1'));
      final p1 =
          await repo.publishDraft(n1.nodeId, increment: IncrementType.major);
      await repo.deleteVersion(p1.nodeId);

      final versions = await repo.listVersions('doc-1');
      expect(versions.first.status, VersionStatus.deleted);
    });

    test('getVersion returns null for deleted node', () async {
      final n1 = await repo.createEntity(_doc('doc-1', 'V1'));
      final p1 =
          await repo.publishDraft(n1.nodeId, increment: IncrementType.major);
      await repo.deleteVersion(p1.nodeId);
      expect(await repo.getVersion(p1.nodeId), isNull);
    });

    // ── Branching ────────────────────────────────────────────────────────────

    test('createBranch creates draft on named branch', () async {
      final n1 = await repo.createEntity(_doc('doc-1', 'Main'));
      final p1 =
          await repo.publishDraft(n1.nodeId, increment: IncrementType.major);

      final branch = await repo.createBranch(
        p1.nodeId,
        branchName: 'feature/x',
        model: _doc('doc-1', 'Feature X'),
      );
      expect(branch.branch, 'feature/x');
      expect(branch.status, VersionStatus.draft);
    });

    test('listBranches returns all unique branch names', () async {
      final n1 = await repo.createEntity(_doc('doc-1', 'Main'));
      final p1 =
          await repo.publishDraft(n1.nodeId, increment: IncrementType.major);

      await repo.createBranch(p1.nodeId,
          branchName: 'feature/a', model: _doc('doc-1', 'A'));
      await repo.createBranch(p1.nodeId,
          branchName: 'feature/b', model: _doc('doc-1', 'B'));

      final branches = await repo.listBranches('doc-1');
      expect(branches, containsAll(['main', 'feature/a', 'feature/b']));
    });

    test('mergeToMain creates new draft on main branch', () async {
      final n1 = await repo.createEntity(_doc('doc-1', 'Main'));
      final p1 =
          await repo.publishDraft(n1.nodeId, increment: IncrementType.major);

      await repo.createBranch(p1.nodeId,
          branchName: 'feature/x', model: _doc('doc-1', 'From Feature'));

      final merged = await repo.mergeToMain(
        'doc-1',
        sourceBranch: 'feature/x',
        requesterId: 'alice',
        fromMap: Doc.fromMap,
      );
      expect(merged.branch, 'main');
      expect(merged.status, VersionStatus.draft);
    });

    test('listVersions filter by status', () async {
      final n1 = await repo.createEntity(_doc('doc-1', 'V1'));
      final p1 =
          await repo.publishDraft(n1.nodeId, increment: IncrementType.major);
      final n2 = await repo.createDraftFrom(p1.nodeId, _doc('doc-1', 'V2'));
      // ignore: unused_local_variable
      final _ = n2; // suppress warning

      final drafts =
          await repo.listVersions('doc-1', status: VersionStatus.draft);
      final published =
          await repo.listVersions('doc-1', status: VersionStatus.published);

      expect(drafts.length, 1);
      expect(published.length, 1);
    });

    test('getLatestPublished returns node with highest version', () async {
      final n1 = await repo.createEntity(_doc('doc-1', 'V1'));
      final p1 =
          await repo.publishDraft(n1.nodeId, increment: IncrementType.major);
      final n2 = await repo.createDraftFrom(p1.nodeId, _doc('doc-1', 'V2'));
      await repo.publishDraft(n2.nodeId, increment: IncrementType.minor);

      final latest = await repo.getLatestPublished('doc-1');
      expect(latest?.version, Semver(1, 1, 0));
    });

    test('getLatestPublished returns null when nothing published', () async {
      await repo.createEntity(_doc('doc-1', 'draft'));
      expect(await repo.getLatestPublished('doc-1'), isNull);
    });

    // ── Access Control ───────────────────────────────────────────────────────

    test('owner has admin access by default', () async {
      await repo.createEntity(_doc('doc-1', 'V1'));
      final ok = await repo.hasAccess('doc-1',
          actorId: 'alice', minimumLevel: AccessLevel.admin);
      expect(ok, isTrue);
    });

    test('unknown actor has no access', () async {
      await repo.createEntity(_doc('doc-1', 'V1'));
      final ok = await repo.hasAccess('doc-1',
          actorId: 'charlie', minimumLevel: AccessLevel.read);
      expect(ok, isFalse);
    });

    test('grantAccess then hasAccess for grantee', () async {
      await repo.createEntity(_doc('doc-1', 'V1'));
      await repo.grantAccess('doc-1',
          actorId: 'bob', level: AccessLevel.read, requesterId: 'alice');

      expect(
        await repo.hasAccess('doc-1',
            actorId: 'bob', minimumLevel: AccessLevel.read),
        isTrue,
      );
      expect(
        await repo.hasAccess('doc-1',
            actorId: 'bob', minimumLevel: AccessLevel.write),
        isFalse,
      );
    });

    test('revokeAccess removes grant', () async {
      await repo.createEntity(_doc('doc-1', 'V1'));
      await repo.grantAccess('doc-1',
          actorId: 'bob', level: AccessLevel.read, requesterId: 'alice');
      await repo.revokeAccess('doc-1', actorId: 'bob', requesterId: 'alice');

      expect(
        await repo.hasAccess('doc-1',
            actorId: 'bob', minimumLevel: AccessLevel.read),
        isFalse,
      );
    });

    test('non-admin cannot grant access', () async {
      await repo.createEntity(_doc('doc-1', 'V1'));
      await repo.grantAccess('doc-1',
          actorId: 'bob', level: AccessLevel.read, requesterId: 'alice');

      await expectLater(
        repo.grantAccess('doc-1',
            actorId: 'charlie', level: AccessLevel.read, requesterId: 'bob'),
        throwsA(isA<VaultAccessDeniedException>()),
      );
    });

    test('listGrants returns current grants', () async {
      await repo.createEntity(_doc('doc-1', 'V1'));
      await repo.grantAccess('doc-1',
          actorId: 'bob', level: AccessLevel.write, requesterId: 'alice');

      final grants = await repo.listGrants('doc-1');
      expect(grants.length, 1);
      // expect(grants.first.actorId, 'bob');
      // expect(grants.first.level, AccessLevel.write);
    });

    // ── Pagination ───────────────────────────────────────────────────────────

    test('findNodesPage paginates version nodes', () async {
      for (var i = 1; i <= 3; i++) {
        final n = await repo.createEntity(_doc('doc-$i', 'Doc $i'));
        await repo.publishDraft(n.nodeId, increment: IncrementType.major);
      }

      final page = await repo.findNodesPage(
        VaultQuery()
            .where('status', VaultOperator.equals, 'published')
            .page(limit: 2, offset: 0),
      );
      expect(page.items.length, 2);
      expect(page.total, 3);
      expect(page.hasMore, isTrue);
    });

    // ── Watch streams ────────────────────────────────────────────────────────

    test('watchVersions emits when version is published', () async {
      final node = await repo.createEntity(_doc('doc-1', 'V1'));

      final snapshots = <List<VersionNode>>[];
      final done = Completer<void>();
      final sub = repo.watchVersions('doc-1').listen((list) {
        snapshots.add(list);
        if (snapshots.length >= 2) done.complete();
      });

      await repo.publishDraft(node.nodeId, increment: IncrementType.major);
      await done.future.timeout(const Duration(seconds: 2));
      await sub.cancel();

      expect(snapshots.length, greaterThanOrEqualTo(2));
      expect(snapshots.last.any((n) => n.status == VersionStatus.published),
          isTrue);
    });

    test('watchAllEntities emits for any entity change', () async {
      final counts = <int>[];
      final done = Completer<void>();
      final sub = repo.watchAllEntities().listen((list) {
        counts.add(list.length);
        if (counts.length >= 3) done.complete();
      });

      await repo.createEntity(_doc('doc-1', 'First'));
      await repo.createEntity(_doc('doc-2', 'Second'));

      await done.future.timeout(const Duration(seconds: 2));
      await sub.cancel();

      expect(counts, [0, 1, 2]);
    });

    // ── Multi-tenancy ────────────────────────────────────────────────────────

    test('alice and bob vaults are isolated', () async {
      // Each tenant needs its own VaultStorage with correct tenantId
      final storageAlice = InMemoryVaultStorage(tenantId: 'alice');
      final storageBob = InMemoryVaultStorage(tenantId: 'bob');
      final va = Vault(storage: storageAlice, tenantId: 'alice');
      final vb = Vault(storage: storageBob, tenantId: 'bob');

      final ra = va.versioned<Doc>(collection: 'docs', fromMap: Doc.fromMap);
      final rb = vb.versioned<Doc>(collection: 'docs', fromMap: Doc.fromMap);

      await ra.createEntity(Doc(
          id: 'x', tenantId: 'system', ownerId: 'alice', title: 'Alice Doc'));
      await rb.createEntity(
          Doc(id: 'x', tenantId: 'system', ownerId: 'bob', title: 'Bob Doc'));

      final aliceCurrent = await ra.listVersions('x');
      final bobCurrent = await rb.listVersions('x');

      expect(aliceCurrent.first.data['title'], 'Alice Doc');
      expect(bobCurrent.first.data['title'], 'Bob Doc');

      await va.dispose();
      await vb.dispose();
    });

    test('cross-tenant access via grants works', () async {
      final shared = InMemoryVaultStorage();
      final va = Vault(storage: shared, tenantId: 'alice');

      // Both use alice's vault namespace — simulates a shared resource link
      final ra = va.versioned<Doc>(collection: 'docs', fromMap: Doc.fromMap);

      final n1 = await ra.createEntity(Doc(
          id: 'shared-1',
          tenantId: 'system',
          ownerId: 'alice',
          title: 'Shared'));
      await ra.publishDraft(n1.nodeId, increment: IncrementType.major);
      await ra.grantAccess('shared-1',
          actorId: 'bob', level: AccessLevel.read, requesterId: 'alice');

      final bobCanRead = await ra.hasAccess('shared-1',
          actorId: 'bob', minimumLevel: AccessLevel.read);
      final bobCanAdmin = await ra.hasAccess('shared-1',
          actorId: 'bob', minimumLevel: AccessLevel.admin);

      expect(bobCanRead, isTrue);
      expect(bobCanAdmin, isFalse);

      await va.dispose();
    });
  });
}
