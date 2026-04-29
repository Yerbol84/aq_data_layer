import 'dart:async';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/storage/in_memory_vault_storage.dart';
import 'package:test/test.dart';
import 'package:dart_vault/dart_vault.dart';
import 'test_helpers.dart';

void main() {
  group('DirectRepository', () {
    late Vault vault;
    late DirectRepository<Item> repo;

    setUp(() {
      vault = Vault();
      repo = vault.direct<Item>(
        collection: 'items',
        fromMap: Item.fromMap,
        indexes: [VaultIndex(name: 'idx_name', field: 'name', unique: false)],
      );
    });

    tearDown(() => vault.dispose());

    // ── Empty state ─────────────────────────────────────────────────────────

    test('empty state — findAll returns []', () async {
      final all = await repo.findAll();
      expect(all, isEmpty);
    });

    test('empty state — count returns 0', () async {
      expect(await repo.count(), 0);
    });

    test('empty state — findById returns null', () async {
      expect(await repo.findById('ghost'), isNull);
    });

    test('empty state — exists returns false', () async {
      expect(await repo.exists('ghost'), isFalse);
    });

    // ── Save & Read ─────────────────────────────────────────────────────────

    test('save then findById', () async {
      final item = Item(id: 'a', name: 'Alpha', score: 10);
      await repo.save(item);
      final found = await repo.findById('a');
      expect(found, isNotNull);
      expect(found!.name, 'Alpha');
      expect(found.score, 10);
    });

    test('save overwrites existing record', () async {
      await repo.save(Item(id: 'a', name: 'Alpha', score: 10));
      await repo.save(Item(id: 'a', name: 'Alpha', score: 99));
      final found = await repo.findById('a');
      expect(found!.score, 99);
    });

    test('saveAll saves multiple items', () async {
      await repo.saveAll([
        Item(id: 'a', name: 'Alpha', score: 1),
        Item(id: 'b', name: 'Beta', score: 2),
        Item(id: 'c', name: 'Gamma', score: 3),
      ]);
      expect(await repo.count(), 3);
    });

    test('exists returns true after save', () async {
      await repo.save(Item(id: 'x', name: 'X', score: 0));
      expect(await repo.exists('x'), isTrue);
    });

    // ── Delete ──────────────────────────────────────────────────────────────

    test('delete removes record', () async {
      await repo.save(Item(id: 'a', name: 'A', score: 1));
      await repo.delete('a');
      expect(await repo.exists('a'), isFalse);
      expect(await repo.count(), 0);
    });

    test('delete non-existent id does not throw', () async {
      await expectLater(repo.delete('ghost'), completes);
    });

    // ── Queries ─────────────────────────────────────────────────────────────

    test('findAll with equality filter', () async {
      await repo.saveAll([
        Item(id: 'a', name: 'Alpha', score: 10),
        Item(id: 'b', name: 'Beta', score: 20),
        Item(id: 'c', name: 'Alpha', score: 30),
      ]);
      final alphas = await repo.findAll(
        query: VaultQuery().where('name', VaultOperator.equals, 'Alpha'),
      );
      expect(alphas.length, 2);
      expect(alphas.every((i) => i.name == 'Alpha'), isTrue);
    });

    test('findAll with greaterThan filter', () async {
      await repo.saveAll([
        Item(id: 'a', name: 'A', score: 5),
        Item(id: 'b', name: 'B', score: 15),
        Item(id: 'c', name: 'C', score: 25),
      ]);
      final high = await repo.findAll(
        query: VaultQuery().where('score', VaultOperator.greaterThan, 10),
      );
      expect(high.length, 2);
      expect(high.every((i) => i.score > 10), isTrue);
    });

    test('findAll with sort descending', () async {
      await repo.saveAll([
        Item(id: 'a', name: 'A', score: 3),
        Item(id: 'b', name: 'B', score: 1),
        Item(id: 'c', name: 'C', score: 2),
      ]);
      final sorted = await repo.findAll(
        query: VaultQuery().orderBy('score', descending: true),
      );
      expect(sorted.map((i) => i.score).toList(), [3, 2, 1]);
    });

    test('count with filter', () async {
      await repo.saveAll([
        Item(id: 'a', name: 'Alpha', score: 1),
        Item(id: 'b', name: 'Beta', score: 2),
      ]);
      final count = await repo.count(
        query: VaultQuery().where('name', VaultOperator.equals, 'Alpha'),
      );
      expect(count, 1);
    });

    // ── Pagination ───────────────────────────────────────────────────────────

    test('findPage returns correct page and total', () async {
      await repo.saveAll(List.generate(
        5,
        (i) => Item(id: 'item-$i', name: 'Item $i', score: i),
      ));

      final page1 = await repo.findPage(
        VaultQuery().orderBy('id').page(limit: 2, offset: 0),
      );
      expect(page1.items.length, 2);
      expect(page1.total, 5);
      expect(page1.hasMore, isTrue);
      expect(page1.page, 1);
      expect(page1.totalPages, 3);

      final page2 = await repo.findPage(
        VaultQuery().orderBy('id').page(limit: 2, offset: 2),
      );
      expect(page2.items.length, 2);
      expect(page2.page, 2);

      final page3 = await repo.findPage(
        VaultQuery().orderBy('id').page(limit: 2, offset: 4),
      );
      expect(page3.items.length, 1);
      expect(page3.hasMore, isFalse);
    });

    // ── Watch stream (race-condition fixed) ──────────────────────────────────

    test('watchAll emits initial snapshot and subsequent saves', () async {
      final received = <int>[];
      final completer = Completer<void>();

      final sub = repo.watchAll().listen((list) {
        received.add(list.length);
        if (received.length == 3) completer.complete();
      });

      await repo.save(Item(id: 'a', name: 'A', score: 1));
      await repo.save(Item(id: 'b', name: 'B', score: 2));

      await completer.future.timeout(const Duration(seconds: 2));
      await sub.cancel();

      // Initial snapshot (0) + after first save (1) + after second save (2)
      expect(received, [0, 1, 2]);
    });

    test('watchAll does not miss event fired immediately after subscribe',
        () async {
      // This is the race condition test
      final counts = <int>[];
      final done = Completer<void>();

      final sub = repo.watchAll().listen((list) {
        counts.add(list.length);
        if (counts.length >= 2) done.complete();
      });

      // Fire immediately — no await before save
      await repo.save(Item(id: 'a', name: 'A', score: 0));

      await done.future.timeout(const Duration(seconds: 2));
      await sub.cancel();

      expect(counts, contains(1)); // must have seen the new item
    });

    // ── Multi-tenancy ────────────────────────────────────────────────────────

    test('two vaults with different tenantIds are isolated', () async {
      // Each tenant needs its own VaultStorage with correct tenantId
      final storageAlice = InMemoryVaultStorage(tenantId: 'alice');
      final storageBob = InMemoryVaultStorage(tenantId: 'bob');
      final va = Vault(storage: storageAlice, tenantId: 'alice');
      final vb = Vault(storage: storageBob, tenantId: 'bob');

      final ra = va.direct<Item>(collection: 'items', fromMap: Item.fromMap);
      final rb = vb.direct<Item>(collection: 'items', fromMap: Item.fromMap);

      await ra.save(Item(id: 'a', name: 'AliceItem', score: 1));
      await rb.save(Item(id: 'a', name: 'BobItem', score: 2));

      final alice = await ra.findById('a');
      final bob = await rb.findById('a');

      expect(alice!.name, 'AliceItem');
      expect(bob!.name, 'BobItem');

      expect(await ra.count(), 1);
      expect(await rb.count(), 1);

      await va.dispose();
      await vb.dispose();
    });
  });
}
