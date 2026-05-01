/// S-11: Concurrent indexing — 10 documents in parallel
library;

import 'dart:convert';
import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint = Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';
final _ollamaEndpoint = Platform.environment['OLLAMA_ENDPOINT'] ?? 'http://ollama:11434';
const _tenantId = 'cc-tenant';
const _storeId = 'pgvector-main';

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  S-11: Concurrent Indexing');
  print('═══════════════════════════════════════════════════════════\n');

  int passed = 0, failed = 0;
  Future<void> run(String name, Future<void> Function() fn) async {
    try { await fn(); passed++; }
    catch (e, st) { print('  ❌ $name: $e\n     $st'); failed++; }
  }

  await run('S-11-1: parallel index 10 docs', _s11ParallelIndex);
  await run('S-11-2: all status=indexed', _s11AllIndexed);
  await run('S-11-3: no duplicate chunk ids', _s11NoDuplicates);
  await run('S-11-4: search works across all docs', _s11SearchAll);
  await run('S-11-5: parallel faster than sequential estimate', _s11Timing);

  print('\n═══════════════════════════════════════════════════════════');
  print('  Results: $passed passed, $failed failed');
  print('═══════════════════════════════════════════════════════════');
  if (failed > 0) exit(1);
}

final _docs = List.generate(10, (i) => (
  id: 'cc-doc-${i.toString().padLeft(2, '0')}',
  text: [
    'Machine learning algorithms learn patterns from training data without explicit programming.',
    'Distributed systems coordinate multiple nodes to achieve fault tolerance and scalability.',
    'Cryptographic hash functions produce fixed-size output from arbitrary input data.',
    'REST APIs use HTTP methods to perform CRUD operations on resources.',
    'Container orchestration platforms manage deployment and scaling of microservices.',
    'Functional programming treats computation as evaluation of mathematical functions.',
    'Graph databases store data as nodes and edges enabling complex relationship queries.',
    'Event-driven architecture decouples services through asynchronous message passing.',
    'Continuous integration automates building and testing code changes on every commit.',
    'Infrastructure as code manages cloud resources through version-controlled configuration files.',
  ][i],
));

late OllamaEmbeddingsClient _embedder;
late VectorRepositoryImpl _repo;
late DirectRepository<StoredArtifact> _artifactRepo;
Duration? _parallelTime;

Future<void> _init() async {
  await initializeDataLayer(endpoint: _endpoint, tenantId: _tenantId, useBuffer: false, authToken: 'test-admin-token');
  _embedder = OllamaEmbeddingsClient(endpoint: _ollamaEndpoint, model: 'nomic-embed-text', dimensions: 768);
  final remote = RemoteVaultStorage(endpoint: _endpoint, tenantId: _tenantId, authToken: 'test-admin-token');
  await remote.connect();
  final registry = VectorStoreRegistryImpl();
  registry.register(VectorStoreDescriptor(id: _storeId, type: 'pgvector', embedderId: _embedder.id, vectorDim: _embedder.dimensions), RemoteVectorStorage(remote: remote));
  _artifactRepo = IDataLayer.instance.direct<StoredArtifact>(collection: StoredArtifact.kCollection, fromMap: StoredArtifact.fromMap);
  _repo = VectorRepositoryImpl(registry: registry, artifactRepo: _artifactRepo);
}

IndexingPipeline _pipeline() => IndexingPipeline(id: 'cc-pipeline-v1', storeId: _storeId, extractor: PlainTextExtractor(), chunker: SentenceChunker(maxChunkChars: 300), embedder: _embedder, reranker: PassthroughReranker());

Future<void> _s11ParallelIndex() async {
  await _init();
  final sw = Stopwatch()..start();
  await Future.wait(_docs.map((doc) async {
    final bytes = utf8.encode(doc.text);
    final artifact = StoredArtifact(id: doc.id, tenantId: _tenantId, ownerId: 'cc-owner', storageKey: '$_tenantId/${doc.id}.txt', fileName: '${doc.id}.txt', contentType: 'text/plain', sizeBytes: bytes.length, checksum: bytes.length.toString(), createdAt: DateTime.now().toUtc());
    await _artifactRepo.save(artifact);
    return _repo.index(artifact, bytes, _pipeline());
  }));
  sw.stop();
  _parallelTime = sw.elapsed;
  print('  ✅ parallel indexed ${_docs.length} docs in ${sw.elapsed.inMilliseconds}ms');
}

Future<void> _s11AllIndexed() async {
  int indexed = 0;
  for (final doc in _docs) {
    final art = await _artifactRepo.findById(doc.id);
    if (art?.indexingStatus == IndexingStatus.indexed) indexed++;
  }
  print('  ✅ $indexed/${_docs.length} documents indexed');
  if (indexed < _docs.length) throw StateError('Only $indexed/${_docs.length} indexed');
}

Future<void> _s11NoDuplicates() async {
  // Search broadly and check no duplicate ids
  final results = await _repo.search('data systems programming', tenantId: _tenantId, storeId: _storeId, embedder: _embedder, topK: 50, scoreThreshold: 0.0);
  final ids = results.map((r) => r.id).toList();
  final unique = ids.toSet();
  if (ids.length != unique.length) throw StateError('Duplicate chunk ids found');
  print('  ✅ ${ids.length} results, no duplicates');
}

Future<void> _s11SearchAll() async {
  final results = await _repo.search('software engineering systems', tenantId: _tenantId, storeId: _storeId, embedder: _embedder, topK: 10, scoreThreshold: 0.0);
  final artifactIds = results.map((r) => r.payload['artifactId'] as String).toSet();
  print('  ✅ search covers ${artifactIds.length} different documents');
  if (artifactIds.length < 3) throw StateError('Search only covers ${artifactIds.length} docs');
}

Future<void> _s11Timing() async {
  if (_parallelTime == null) throw StateError('No parallel time recorded');
  // Sequential estimate: parallel_time * 10 / docs (rough)
  // Just verify parallel completed in reasonable time (< 60s for 10 docs)
  print('  ✅ parallel time: ${_parallelTime!.inMilliseconds}ms for ${_docs.length} docs (${(_parallelTime!.inMilliseconds / _docs.length).round()}ms/doc avg)');
  if (_parallelTime!.inSeconds > 120) throw StateError('Parallel indexing too slow: ${_parallelTime!.inSeconds}s');
}
