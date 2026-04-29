import 'dart:async';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/artifact_vault.dart';
import 'package:dart_vault/knowledge_vault.dart';
import 'package:dart_vault/server.dart';
import 'package:dart_vault/storage/in_memory_artifact_storage.dart';
import 'package:dart_vault/storage/in_memory_vector_storage.dart';
import 'package:test/test.dart';
import 'package:dart_vault/dart_vault.dart';
import 'test_helpers.dart';

// ══════════════════════════════════════════════════════════════════════════════
// ARTIFACT TESTS
// ══════════════════════════════════════════════════════════════════════════════

void main() {
  group('ArtifactRepository', () {
    late ArtifactVault vault;
    late ArtifactRepository<FileEntry> repo;

    setUp(() {
      vault = ArtifactVault(tenantId: 'system');
      repo = vault.artifacts<FileEntry>(
        collection: 'files',
        fromMap: FileEntry.fromMap,
      );
    });

    tearDown(() => vault.dispose());

    FileEntry _entry(String id, String name, {String ct = 'text/plain'}) =>
        FileEntry(
          id: id,
          storageKey: '',
          fileName: name,
          contentType: ct,
          sizeBytes: 0,
          checksum: '',
          createdAt: DateTime.now(),
        );

    final _bytes = [104, 101, 108, 108, 111]; // "hello"

    // ── Save & Read ──────────────────────────────────────────────────────────

    test('save then findById returns metadata', () async {
      await repo.save(_entry('f1', 'report.txt'), _bytes);
      final found = await repo.findById('f1');
      expect(found, isNotNull);
      expect(found!.fileName, 'report.txt');
    });

    test('loadBytes returns stored bytes', () async {
      await repo.save(_entry('f1', 'report.txt'), _bytes);
      final loaded = await repo.loadBytes('f1');
      expect(loaded, _bytes);
    });

    test('save updates sizeBytes in metadata', () async {
      await repo.save(_entry('f1', 'a.txt'), _bytes);
      final meta = await repo.findById('f1');
      expect(meta!.sizeBytes, _bytes.length);
    });

    test('save updates checksum in metadata', () async {
      await repo.save(_entry('f1', 'a.txt'), _bytes);
      final meta = await repo.findById('f1');
      expect(meta!.checksum, isNotEmpty);
      expect(meta.checksum, startsWith('fnv1a-'));
    });

    test('loadBytes returns null for missing file', () async {
      expect(await repo.loadBytes('ghost'), isNull);
    });

    test('exists returns true after save', () async {
      await repo.save(_entry('f1', 'x.txt'), _bytes);
      expect(await repo.exists('f1'), isTrue);
    });

    // ── Stream bytes ─────────────────────────────────────────────────────────

    test('streamBytes yields the stored bytes', () async {
      await repo.save(_entry('f1', 'x.txt'), _bytes);
      final chunks = await repo.streamBytes('f1').toList();
      expect(chunks.expand((c) => c).toList(), _bytes);
    });

    // ── Delete ───────────────────────────────────────────────────────────────

    test('delete removes metadata and bytes', () async {
      await repo.save(_entry('f1', 'x.txt'), _bytes);
      await repo.delete('f1');
      expect(await repo.exists('f1'), isFalse);
      expect(await repo.loadBytes('f1'), isNull);
    });

    // ── findAll / findPage ───────────────────────────────────────────────────

    test('findAll returns all saved entries', () async {
      await repo.save(_entry('f1', 'a.txt'), _bytes);
      await repo.save(_entry('f2', 'b.pdf', ct: 'application/pdf'), _bytes);
      final all = await repo.findAll();
      expect(all.length, 2);
    });

    test('findAll with content-type filter', () async {
      await repo.save(_entry('f1', 'a.txt'), _bytes);
      await repo.save(_entry('f2', 'b.pdf', ct: 'application/pdf'), _bytes);
      final pdfs = await repo.findAll(
        query: VaultQuery()
            .where('contentType', VaultOperator.equals, 'application/pdf'),
      );
      expect(pdfs.length, 1);
      expect(pdfs.first.fileName, 'b.pdf');
    });

    test('findPage returns paged metadata', () async {
      for (var i = 1; i <= 5; i++) {
        await repo.save(_entry('f$i', 'file-$i.txt'), _bytes);
      }
      final page = await repo.findPage(
        VaultQuery().page(limit: 2, offset: 0),
      );
      expect(page.items.length, 2);
      expect(page.total, 5);
    });

    // ── Multi-tenancy ────────────────────────────────────────────────────────

    test('tenant isolation for artifacts', () async {
      // Each tenant needs its own VaultStorage with correct tenantId
      final storageAlice = InMemoryVaultStorage(tenantId: 'alice');
      final storageBob = InMemoryVaultStorage(tenantId: 'bob');
      final binaryShared = InMemoryArtifactStorage();

      final va = ArtifactVault(
        metaStorage: storageAlice,
        binaryStore: binaryShared,
        tenantId: 'alice',
      );
      final vb = ArtifactVault(
        metaStorage: storageBob,
        binaryStore: binaryShared,
        tenantId: 'bob',
      );

      final ra = va.artifacts<FileEntry>(
          collection: 'files', fromMap: FileEntry.fromMap);
      final rb = vb.artifacts<FileEntry>(
          collection: 'files', fromMap: FileEntry.fromMap);

      await ra.save(_entry('f1', 'alice.txt'), [65]); // 'A'
      await rb.save(_entry('f1', 'bob.txt'), [66]); // 'B'

      expect((await ra.findById('f1'))?.fileName, 'alice.txt');
      expect((await rb.findById('f1'))?.fileName, 'bob.txt');
      expect(await ra.loadBytes('f1'), [65]);
      expect(await rb.loadBytes('f1'), [66]);

      await va.dispose();
      await vb.dispose();
    });

    // ── Watch ────────────────────────────────────────────────────────────────

    test('watchAll emits on save', () async {
      final counts = <int>[];
      final done = Completer<void>();
      final sub = repo.watchAll().listen((list) {
        counts.add(list.length);
        if (counts.length >= 2) done.complete();
      });

      await repo.save(_entry('f1', 'x.txt'), _bytes);
      await done.future.timeout(const Duration(seconds: 2));
      await sub.cancel();

      expect(counts, [0, 1]);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // VECTOR TESTS
  // ══════════════════════════════════════════════════════════════════════════

  group('VectorRepository (InMemory)', () {
    late KnowledgeVault vault;
    late VectorRepository repo;

    setUp(() {
      vault = KnowledgeVault();
      repo = vault.vectors(collection: 'vecs', vectorSize: 3);
    });

    tearDown(() => vault.dispose());

    VectorEntry _entry(String id, List<double> vec,
            {Map<String, dynamic> payload = const {}}) =>
        VectorEntry(id: id, vector: vec, payload: payload);

    // ── Upsert & Read ────────────────────────────────────────────────────────

    test('upsert then getById returns entry', () async {
      await repo.upsert(_entry('v1', [1.0, 0.0, 0.0]));
      final found = await repo.getById('v1');
      expect(found, isNotNull);
      expect(found!.vector, [1.0, 0.0, 0.0]);
    });

    test('upsertAll stores multiple entries', () async {
      await repo.upsertAll([
        _entry('v1', [1.0, 0.0, 0.0]),
        _entry('v2', [0.0, 1.0, 0.0]),
        _entry('v3', [0.0, 0.0, 1.0]),
      ]);
      expect(await repo.count(), 3);
    });

    // ── Search ───────────────────────────────────────────────────────────────

    test('search returns results sorted by score descending', () async {
      await repo.upsertAll([
        _entry('v1', [1.0, 0.0, 0.0]),
        _entry('v2', [0.9, 0.1, 0.0]),
        _entry('v3', [0.0, 0.0, 1.0]),
      ]);

      final results = await repo.search([1.0, 0.0, 0.0], limit: 3);
      expect(results.first.id, 'v1');
      expect(results.first.score, closeTo(1.0, 0.001));
      expect(results[1].score, greaterThanOrEqualTo(results[2].score));
    });

    test('search respects limit', () async {
      await repo.upsertAll([
        _entry('v1', [1.0, 0.0, 0.0]),
        _entry('v2', [0.9, 0.1, 0.0]),
        _entry('v3', [0.8, 0.2, 0.0]),
      ]);
      final results = await repo.search([1.0, 0.0, 0.0], limit: 2);
      expect(results.length, 2);
    });

    test('search respects scoreThreshold', () async {
      await repo.upsertAll([
        _entry('v1', [1.0, 0.0, 0.0]), // score ~1.0
        _entry('v2', [0.0, 0.0, 1.0]), // score ~0.0
      ]);
      final results = await repo.search(
        [1.0, 0.0, 0.0],
        limit: 10,
        scoreThreshold: 0.5,
      );
      expect(results.length, 1);
      expect(results.first.id, 'v1');
    });

    test('search with payload filter', () async {
      await repo.upsertAll([
        _entry('v1', [1.0, 0.0, 0.0], payload: {'tag': 'A'}),
        _entry('v2', [0.9, 0.1, 0.0], payload: {'tag': 'B'}),
        _entry('v3', [0.8, 0.2, 0.0], payload: {'tag': 'A'}),
      ]);
      final results = await repo.search(
        [1.0, 0.0, 0.0],
        limit: 10,
        filter: VaultQuery().where('tag', VaultOperator.equals, 'A'),
      );
      expect(results.every((r) => r.payload['tag'] == 'A'), isTrue);
    });

    // ── Delete ───────────────────────────────────────────────────────────────

    test('delete removes entry', () async {
      await repo.upsert(_entry('v1', [1.0, 0.0, 0.0]));
      await repo.delete('v1');
      expect(await repo.getById('v1'), isNull);
    });

    test('deleteWhere removes matching entries', () async {
      await repo.upsertAll([
        _entry('v1', [1.0, 0.0, 0.0], payload: {'tag': 'A'}),
        _entry('v2', [0.0, 1.0, 0.0], payload: {'tag': 'B'}),
        _entry('v3', [0.0, 0.0, 1.0], payload: {'tag': 'A'}),
      ]);
      await repo.deleteWhere(
        VaultQuery().where('tag', VaultOperator.equals, 'A'),
      );
      expect(await repo.count(), 1);
      expect((await repo.getById('v2')), isNotNull);
    });

    // ── getAll with filter ───────────────────────────────────────────────────

    test('getAll with filter', () async {
      await repo.upsertAll([
        _entry('v1', [1.0, 0.0, 0.0], payload: {'kind': 'X'}),
        _entry('v2', [0.0, 1.0, 0.0], payload: {'kind': 'Y'}),
      ]);
      final xs = await repo.getAll(
        filter: VaultQuery().where('kind', VaultOperator.equals, 'X'),
      );
      expect(xs.length, 1);
      expect(xs.first.id, 'v1');
    });

    // ── Multi-tenancy ────────────────────────────────────────────────────────

    test('vector tenant isolation', () async {
      // VectorStorage can be shared - tenant isolation via collection prefix
      final sharedVec = InMemoryVectorStorage();
      final va = KnowledgeVault(vectorStorage: sharedVec, tenantId: 'alice');
      final vb = KnowledgeVault(vectorStorage: sharedVec, tenantId: 'bob');

      final ra = va.vectors(collection: 'vecs', vectorSize: 2);
      final rb = vb.vectors(collection: 'vecs', vectorSize: 2);

      await ra.upsert(
          VectorEntry(id: 'x', vector: [1.0, 0.0], payload: {'who': 'alice'}));
      await rb.upsert(
          VectorEntry(id: 'x', vector: [0.0, 1.0], payload: {'who': 'bob'}));

      final aVec = await ra.getById('x');
      final bVec = await rb.getById('x');

      expect(aVec!.vector, [1.0, 0.0]);
      expect(bVec!.vector, [0.0, 1.0]);

      await va.dispose();
      await vb.dispose();
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // KNOWLEDGE REPOSITORY TESTS
  // ══════════════════════════════════════════════════════════════════════════

  group('KnowledgeRepository', () {
    // Deterministic fake embed — maps every word to a random-but-stable vector
    List<double> _fakeEmbed(String text) {
      final hash = text.codeUnits.fold(0, (a, b) => a ^ b);
      return List.generate(4, (i) => (((hash >> i) & 0xFF) / 255.0));
    }

    late KnowledgeVault vault;
    late KnowledgeRepository<_KbDoc> repo;

    setUp(() {
      vault = KnowledgeVault(tenantId: 'project-1');
      repo = vault.documents<_KbDoc>(
        collection: 'docs',
        vectorSize: 4,
        fromMap: _KbDoc.fromMap,
        embed: (text) async => _fakeEmbed(text),
        splitter: FixedSizeSplitter(chunkSize: 20, overlap: 5),
      );
    });

    tearDown(() => vault.dispose());

    _KbDoc _doc(String id, String name) => _KbDoc(
          id: id,
          storageKey: '',
          fileName: name,
          contentType: 'text/plain',
          sizeBytes: 0,
          checksum: '',
          createdAt: DateTime.now(),
          knowledgeBaseId: 'kb-main',
          vectorsUpToDate: false,
          chunkCount: 0,
        );

    final _bytes = [116, 101, 115, 116]; // "test"

    // ── Save & Index ─────────────────────────────────────────────────────────

    test('save stores file bytes and metadata', () async {
      await repo.save(_doc('d1', 'a.txt'), _bytes);
      final found = await repo.findById('d1');
      expect(found, isNotNull);
      expect(found!.fileName, 'a.txt');
    });

    test('save with rawText indexes vectors', () async {
      await repo.save(_doc('d1', 'a.txt'), _bytes,
          rawText: 'Hello world this is a test document for indexing');

      final meta = await repo.findById('d1');
      expect(meta!.vectorsUpToDate, isTrue);
      expect(meta.chunkCount, greaterThan(0));
    });

    test('loadBytes returns original bytes', () async {
      await repo.save(_doc('d1', 'a.txt'), _bytes);
      expect(await repo.loadBytes('d1'), _bytes);
    });

    // ── Search ───────────────────────────────────────────────────────────────

    test('search returns results after indexing', () async {
      await repo.save(_doc('d1', 'manual.txt'), _bytes,
          rawText:
              'The quick brown fox jumps over the lazy dog. More text here.');

      final results = await repo.search(
        'fox jumps',
        embed: (text) async => _fakeEmbed(text),
        limit: 5,
        scoreThreshold: 0.0,
      );
      expect(results, isNotEmpty);
      expect(results.first.documentId, 'd1');
    });

    // ── reIndex ──────────────────────────────────────────────────────────────

    test('reIndex updates vector chunks', () async {
      await repo.save(_doc('d1', 'a.txt'), _bytes, rawText: 'Old content');
      final before = (await repo.findById('d1'))!.chunkCount;

      await repo.reIndex(
          'd1', 'New extended content with more words here to create chunks');
      final after = (await repo.findById('d1'))!.chunkCount;

      expect(after, greaterThanOrEqualTo(before));
      expect((await repo.findById('d1'))!.vectorsUpToDate, isTrue);
    });

    // ── Delete ───────────────────────────────────────────────────────────────

    test('delete removes file, metadata and vectors', () async {
      await repo.save(_doc('d1', 'a.txt'), _bytes,
          rawText: 'Some content to index');
      await repo.delete('d1');

      expect(await repo.findById('d1'), isNull);
      expect(await repo.loadBytes('d1'), isNull);
    });

    // ── Multi-tenancy ────────────────────────────────────────────────────────

    test('knowledge vault tenant isolation', () async {
      // Each tenant needs separate VaultStorage, but can share VectorStorage
      final metaA = InMemoryVaultStorage(tenantId: 'proj-a');
      final metaB = InMemoryVaultStorage(tenantId: 'proj-b');
      final sharedBin = InMemoryArtifactStorage();
      final sharedVec = InMemoryVectorStorage();

      final va = KnowledgeVault(
        metaStorage: metaA,
        binaryStore: sharedBin,
        vectorStorage: sharedVec,
        tenantId: 'proj-a',
      );
      final vb = KnowledgeVault(
        metaStorage: metaB,
        binaryStore: sharedBin,
        vectorStorage: sharedVec,
        tenantId: 'proj-b',
      );

      final embed = (String t) async => _fakeEmbed(t);

      final ra = va.documents<_KbDoc>(
        collection: 'docs',
        vectorSize: 4,
        fromMap: _KbDoc.fromMap,
        embed: embed,
      );
      final rb = vb.documents<_KbDoc>(
        collection: 'docs',
        vectorSize: 4,
        fromMap: _KbDoc.fromMap,
        embed: embed,
      );

      final mkDoc = (String id, String name) => _KbDoc(
            id: id,
            storageKey: '',
            fileName: name,
            contentType: 'text/plain',
            sizeBytes: 0,
            checksum: '',
            createdAt: DateTime.now(),
            knowledgeBaseId: 'kb',
            vectorsUpToDate: false,
            chunkCount: 0,
          );

      await ra.save(mkDoc('doc-1', 'proj-a-doc.txt'), [65],
          rawText: 'project A document');
      await rb.save(mkDoc('doc-1', 'proj-b-doc.txt'), [66],
          rawText: 'project B document');

      expect((await ra.findById('doc-1'))?.fileName, 'proj-a-doc.txt');
      expect((await rb.findById('doc-1'))?.fileName, 'proj-b-doc.txt');

      await va.dispose();
      await vb.dispose();
    });
  });
}

// ── Test KnowledgeDocument implementation ────────────────────────────────────

class _KbDoc implements KnowledgeDocument {
  @override
  final String id;
  @override
  final String storageKey;
  @override
  final String fileName;
  @override
  final String contentType;
  @override
  final int sizeBytes;
  @override
  final String checksum;
  @override
  final Map<String, String> meta;
  @override
  final DateTime createdAt;
  @override
  final String knowledgeBaseId;
  @override
  final bool vectorsUpToDate;
  @override
  final int chunkCount;

  const _KbDoc({
    required this.id,
    required this.storageKey,
    required this.fileName,
    required this.contentType,
    required this.sizeBytes,
    required this.checksum,
    this.meta = const {},
    required this.createdAt,
    required this.knowledgeBaseId,
    required this.vectorsUpToDate,
    required this.chunkCount,
  });

  @override
  Map<String, dynamic> toMap() => {
        'id': id,
        'storageKey': storageKey,
        'fileName': fileName,
        'contentType': contentType,
        'sizeBytes': sizeBytes,
        'checksum': checksum,
        'meta': meta,
        'createdAt': createdAt.toIso8601String(),
        'knowledgeBaseId': knowledgeBaseId,
        'vectorsUpToDate': vectorsUpToDate,
        'chunkCount': chunkCount,
      };

  @override
  Map<String, dynamic> get indexFields => {'knowledgeBaseId': knowledgeBaseId};

  factory _KbDoc.fromMap(Map<String, dynamic> m) => _KbDoc(
        id: m['id'] as String,
        storageKey: m['storageKey'] as String? ?? '',
        fileName: m['fileName'] as String? ?? '',
        contentType: m['contentType'] as String? ?? 'text/plain',
        sizeBytes: m['sizeBytes'] as int? ?? 0,
        checksum: m['checksum'] as String? ?? '',
        meta: ((m['meta'] as Map?) ?? {})
            .map((k, v) => MapEntry(k.toString(), v.toString())),
        createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ??
            DateTime.now(),
        knowledgeBaseId: m['knowledgeBaseId'] as String? ?? '',
        vectorsUpToDate: m['vectorsUpToDate'] as bool? ?? false,
        chunkCount: m['chunkCount'] as int? ?? 0,
      );

  @override
  // TODO: implement collectionName
  String get collectionName => throw UnimplementedError();

  @override
  // TODO: implement jsonSchema
  Map<String, dynamic> get jsonSchema => throw UnimplementedError();
}
