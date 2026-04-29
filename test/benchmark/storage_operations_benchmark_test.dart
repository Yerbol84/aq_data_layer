/// Performance benchmarks for low-level storage operations.
///
/// Establishes baseline metrics for:
/// - VaultStorage put/get/delete operations
/// - VectorStorage upsert/search operations
/// - Concurrent operations
///
/// Target: < 5ms for single storage ops, < 100ms for vector ops
library storage_operations_benchmark;

import 'package:test/test.dart';
import 'package:dart_vault/storage/in_memory_vault_storage.dart';
import 'package:dart_vault/storage/in_memory_vector_storage.dart';
import 'package:aq_schema/aq_schema.dart';

void main() {
  group('VaultStorage Benchmarks', () {
    late InMemoryVaultStorage storage;

    setUp(() {
      storage = InMemoryVaultStorage();
    });

    test('put() single document completes within 5ms', () async {
      final doc = {
        'id': 'doc-1',
        'title': 'Test Document',
        'content': 'Lorem ipsum dolor sit amet',
      };

      final stopwatch = Stopwatch()..start();
      await storage.put('docs', 'doc-1', doc);
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(elapsedMs, lessThan(5),
          reason: 'put() took ${elapsedMs}ms, expected < 5ms');
    });

    test('get() single document completes within 3ms', () async {
      final doc = {
        'id': 'doc-1',
        'title': 'Test Document',
      };
      await storage.put('docs', 'doc-1', doc);

      final stopwatch = Stopwatch()..start();
      final result = await storage.get('docs', 'doc-1');
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(result, isNotNull);
      expect(elapsedMs, lessThan(3),
          reason: 'get() took ${elapsedMs}ms, expected < 3ms');
    });

    test('delete() single document completes within 3ms', () async {
      final doc = {'id': 'doc-1'};
      await storage.put('docs', 'doc-1', doc);

      final stopwatch = Stopwatch()..start();
      await storage.delete('docs', 'doc-1');
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(elapsedMs, lessThan(3),
          reason: 'delete() took ${elapsedMs}ms, expected < 3ms');
    });

    test('batch put of 100 documents completes within 50ms', () async {
      final stopwatch = Stopwatch()..start();
      for (int i = 0; i < 100; i++) {
        await storage.put('docs', 'doc-$i', {'id': 'doc-$i', 'index': i});
      }
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(elapsedMs, lessThan(50),
          reason: 'Batch put(100) took ${elapsedMs}ms, expected < 50ms');
    });

    test('query() with 1000 documents completes within 30ms', () async {
      // Setup: put 1000 docs
      for (int i = 0; i < 1000; i++) {
        await storage.put('docs', 'doc-$i', {'id': 'doc-$i', 'index': i});
      }

      final stopwatch = Stopwatch()..start();
      final results = await storage.query('docs', VaultQuery());
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(results.length, equals(1000));
      expect(elapsedMs, lessThan(30),
          reason: 'query(1000) took ${elapsedMs}ms, expected < 30ms');
    });
  });

  group('VectorStorage Benchmarks', () {
    late InMemoryVectorStorage vectorStorage;

    setUp(() async {
      vectorStorage = InMemoryVectorStorage();
      await vectorStorage.ensureCollection('embeddings', vectorSize: 384);
    });

    test('upsert() single vector completes within 10ms', () async {
      final vector = List.generate(384, (i) => i / 384.0);
      final entry = VectorEntry(
        id: 'vec-1',
        vector: vector,
        payload: {'text': 'Sample text'},
      );

      final stopwatch = Stopwatch()..start();
      await vectorStorage.upsert('embeddings', entry);
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(elapsedMs, lessThan(10),
          reason: 'upsert() took ${elapsedMs}ms, expected < 10ms');
    });

    test('search() with 100 vectors completes within 100ms', () async {
      // Setup: upsert 100 vectors
      for (int i = 0; i < 100; i++) {
        final vector = List.generate(384, (j) => (i + j) / 384.0);
        final entry = VectorEntry(
          id: 'vec-$i',
          vector: vector,
          payload: {'index': i},
        );
        await vectorStorage.upsert('embeddings', entry);
      }

      final queryVector = List.generate(384, (i) => i / 384.0);

      final stopwatch = Stopwatch()..start();
      final results = await vectorStorage.search(
        'embeddings',
        queryVector,
        limit: 10,
      );
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(results.length, lessThanOrEqualTo(10));
      expect(elapsedMs, lessThan(100),
          reason: 'search(100 vectors) took ${elapsedMs}ms, expected < 100ms');
    });

    test('batch upsert of 50 vectors completes within 100ms', () async {
      final entries = <VectorEntry>[];
      for (int i = 0; i < 50; i++) {
        final vector = List.generate(384, (j) => (i + j) / 384.0);
        entries.add(VectorEntry(
          id: 'vec-$i',
          vector: vector,
          payload: {'index': i},
        ));
      }

      final stopwatch = Stopwatch()..start();
      await vectorStorage.upsertAll('embeddings', entries);
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(elapsedMs, lessThan(100),
          reason: 'Batch upsert(50) took ${elapsedMs}ms, expected < 100ms');
    });
  });

  group('Concurrent Operations Benchmarks', () {
    late InMemoryVaultStorage storage;

    setUp(() {
      storage = InMemoryVaultStorage();
    });

    test('10 concurrent puts complete within 20ms', () async {
      final stopwatch = Stopwatch()..start();
      await Future.wait([
        for (int i = 0; i < 10; i++)
          storage.put('docs', 'doc-$i', {'id': 'doc-$i', 'index': i}),
      ]);
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(elapsedMs, lessThan(20),
          reason: '10 concurrent puts took ${elapsedMs}ms, expected < 20ms');
    });

    test('10 concurrent gets complete within 15ms', () async {
      // Setup: put 10 docs
      for (int i = 0; i < 10; i++) {
        await storage.put('docs', 'doc-$i', {'id': 'doc-$i'});
      }

      final stopwatch = Stopwatch()..start();
      await Future.wait([
        for (int i = 0; i < 10; i++) storage.get('docs', 'doc-$i'),
      ]);
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(elapsedMs, lessThan(15),
          reason: '10 concurrent gets took ${elapsedMs}ms, expected < 15ms');
    });

    test('mixed operations (get/put/delete) complete within 30ms', () async {
      // Setup: put some docs
      for (int i = 0; i < 5; i++) {
        await storage.put('docs', 'doc-$i', {'id': 'doc-$i'});
      }

      final stopwatch = Stopwatch()..start();
      await Future.wait([
        // 5 gets
        for (int i = 0; i < 5; i++) storage.get('docs', 'doc-$i'),
        // 5 puts
        for (int i = 5; i < 10; i++)
          storage.put('docs', 'doc-$i', {'id': 'doc-$i'}),
        // 3 deletes
        for (int i = 0; i < 3; i++) storage.delete('docs', 'doc-$i'),
      ]);
      stopwatch.stop();

      final elapsedMs = stopwatch.elapsedMilliseconds;

      expect(elapsedMs, lessThan(30),
          reason: 'Mixed operations took ${elapsedMs}ms, expected < 30ms');
    });
  });
}
