/// Performance benchmarks for core repository operations.
///
/// Establishes baseline metrics for:
/// - save() operations
/// - findById() lookups
/// - findAll() queries
///
/// Target: < 10ms for single operations, < 100ms for batch operations
library repository_operations_benchmark;

import 'package:test/test.dart';
import 'package:dart_vault/dart_vault.dart';
import 'package:aq_schema/aq_schema.dart';
import '../test_helpers.dart';

void main() {
  group('DirectRepository Benchmarks', () {
    late Vault vault;
    late DirectRepository<Item> repo;

    setUp(() {
      vault = Vault();
      repo = vault.direct<Item>(
        collection: 'items',
        fromMap: Item.fromMap,
      );
    });

    tearDown(() => vault.dispose());

    test('save() single item completes within 10ms', () async {
      final item = Item(id: 'item-1', name: 'Test Item', score: 100);

      final stopwatch = Stopwatch()..start();
      await repo.save(item);
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(elapsedMs, lessThan(10),
          reason: 'save() took ${elapsedMs}ms, expected < 10ms');
    });

    test('findById() completes within 5ms', () async {
      // Setup: save item first
      final item = Item(id: 'item-1', name: 'Test Item', score: 100);
      await repo.save(item);

      final stopwatch = Stopwatch()..start();
      final result = await repo.findById('item-1');
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(result, isNotNull);
      expect(elapsedMs, lessThan(5),
          reason: 'findById() took ${elapsedMs}ms, expected < 5ms');
    });

    test('findAll() with 100 items completes within 50ms', () async {
      // Setup: save 100 items
      for (int i = 0; i < 100; i++) {
        await repo.save(Item(
          id: 'item-$i',
          name: 'Item $i',
          score: i,
        ));
      }

      final stopwatch = Stopwatch()..start();
      final results = await repo.findAll();
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(results.length, equals(100));
      expect(elapsedMs, lessThan(50),
          reason: 'findAll(100 items) took ${elapsedMs}ms, expected < 50ms');
    });

    test('batch save() of 100 items completes within 100ms', () async {
      final items = List.generate(
        100,
        (i) => Item(id: 'item-$i', name: 'Item $i', score: i),
      );

      final stopwatch = Stopwatch()..start();
      for (final item in items) {
        await repo.save(item);
      }
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(elapsedMs, lessThan(100),
          reason: 'Batch save(100) took ${elapsedMs}ms, expected < 100ms');
    });
  });

  group('VersionedRepository Benchmarks', () {
    late Vault vault;
    late VersionedRepository<Doc> repo;

    setUp(() {
      vault = Vault(tenantId: 'bench-tenant');
      repo = vault.versioned<Doc>(
        collection: 'docs',
        fromMap: Doc.fromMap,
      );
    });

    tearDown(() => vault.dispose());

    test('createEntity + publishDraft completes within 35ms', () async {
      final doc = Doc(
        id: 'doc-1',
        tenantId: 'bench-tenant',
        ownerId: 'user-1',
        title: 'Test Document',
        body: 'Content',
      );

      final stopwatch = Stopwatch()..start();
      final node = await repo.createEntity(doc);
      await repo.publishDraft(node.nodeId, increment: IncrementType.major);
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(elapsedMs, lessThan(35),
          reason: 'Versioned create+publish took ${elapsedMs}ms, expected < 35ms');
    });

    test('getCurrent() completes within 10ms', () async {
      final doc = Doc(
        id: 'doc-1',
        tenantId: 'bench-tenant',
        ownerId: 'user-1',
        title: 'Test Document',
      );
      final node = await repo.createEntity(doc);
      await repo.publishDraft(node.nodeId, increment: IncrementType.major);

      final stopwatch = Stopwatch()..start();
      final result = await repo.getCurrent('doc-1');
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(result, isNotNull);
      expect(elapsedMs, lessThan(10),
          reason: 'getCurrent() took ${elapsedMs}ms, expected < 10ms');
    });
  });

  group('LoggedRepository Benchmarks', () {
    late Vault vault;
    late LoggedRepository<Task> repo;

    setUp(() {
      vault = Vault();
      repo = vault.logged<Task>(
        collection: 'tasks',
        fromMap: Task.fromMap,
      );
    });

    tearDown(() => vault.dispose());

    test('save() with audit log completes within 15ms', () async {
      final task = Task(
        id: 'task-1',
        title: 'Test Task',
        status: 'open',
        assigneeId: 'user-1',
      );

      final stopwatch = Stopwatch()..start();
      await repo.save(task, actorId: 'system');
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(elapsedMs, lessThan(15),
          reason: 'Logged save() took ${elapsedMs}ms, expected < 15ms');
    });

    test('findById() with log entries completes within 10ms', () async {
      final task = Task(
        id: 'task-1',
        title: 'Test Task',
        status: 'open',
        assigneeId: 'user-1',
      );
      await repo.save(task, actorId: 'system');

      final stopwatch = Stopwatch()..start();
      final result = await repo.findById('task-1');
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(result, isNotNull);
      expect(elapsedMs, lessThan(10),
          reason: 'Logged findById() took ${elapsedMs}ms, expected < 10ms');
    });
  });

  group('Query Performance Benchmarks', () {
    late Vault vault;
    late DirectRepository<Item> repo;

    setUp(() async {
      vault = Vault();
      repo = vault.direct<Item>(
        collection: 'items',
        fromMap: Item.fromMap,
      );

      // Setup: 1000 items for query testing
      for (int i = 0; i < 1000; i++) {
        await repo.save(Item(
          id: 'item-$i',
          name: 'Item ${i % 10}', // 10 unique names
          score: i % 100, // scores 0-99
        ));
      }
    });

    tearDown(() => vault.dispose());

    test('findAll() with 1000 items completes within 50ms', () async {
      final stopwatch = Stopwatch()..start();
      final results = await repo.findAll();
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(results.length, equals(1000));
      expect(elapsedMs, lessThan(50),
          reason: 'findAll(1000 items) took ${elapsedMs}ms, expected < 50ms');
    });

    test('count() with 1000 items completes within 20ms', () async {
      final stopwatch = Stopwatch()..start();
      final count = await repo.count();
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(count, equals(1000));
      expect(elapsedMs, lessThan(20),
          reason: 'count() took ${elapsedMs}ms, expected < 20ms');
    });

    test('exists() check completes within 5ms', () async {
      final stopwatch = Stopwatch()..start();
      final exists = await repo.exists('item-500');
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(exists, isTrue);
      expect(elapsedMs, lessThan(5),
          reason: 'exists() took ${elapsedMs}ms, expected < 5ms');
    });
  });
}
