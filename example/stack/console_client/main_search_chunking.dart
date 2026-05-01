/// S-06: Chunking strategy comparison
/// MockChunker(200) vs MockChunker(500) vs SentenceChunker
library;

import 'dart:convert';
import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint = Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';
final _ollamaEndpoint = Platform.environment['OLLAMA_ENDPOINT'] ?? 'http://ollama:11434';
const _storeId = 'pgvector-main';

const _docText = '''
Vector search enables semantic retrieval of documents based on meaning rather than keywords.
Embeddings capture the semantic content of text in a dense numerical representation.
Cosine similarity measures the angle between two vectors to determine their relatedness.

Traditional keyword search relies on exact term matching and inverted indexes.
BM25 scoring ranks documents by term frequency and inverse document frequency.
Hybrid search combines dense vector similarity with sparse keyword matching for better results.

Chunking strategies affect the quality of vector search significantly.
Sentence-level chunking preserves semantic coherence within each chunk.
Fixed-size chunking may split sentences mid-way reducing retrieval quality.
Overlap between chunks ensures boundary content is captured in multiple chunks.
''';

const _query = 'how does chunking affect vector search quality';

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  S-06: Chunking Strategy Comparison');
  print('═══════════════════════════════════════════════════════════\n');

  int passed = 0, failed = 0;
  Future<void> run(String name, Future<void> Function() fn) async {
    try { await fn(); passed++; }
    catch (e, st) { print('  ❌ $name: $e\n     $st'); failed++; }
  }

  await run('S-06-1: MockChunker(200) — fixed small', () => _runStrategy('mock-200', MockChunker(maxChunkSize: 200)));
  await run('S-06-2: MockChunker(500) — fixed large', () => _runStrategy('mock-500', MockChunker(maxChunkSize: 500)));
  await run('S-06-3: SentenceChunker — sentence boundary', () => _runStrategy('sentence', SentenceChunker(maxChunkChars: 300, overlap: true)));
  await run('S-06-4: SentenceChunker score ≥ MockChunker score', _s06CompareScores);

  print('\n═══════════════════════════════════════════════════════════');
  print('  Results: $passed passed, $failed failed');
  print('═══════════════════════════════════════════════════════════');
  if (failed > 0) exit(1);
}

late OllamaEmbeddingsClient _embedder;
final _scores = <String, double>{};
bool _initialized = false;

Future<void> _init() async {
  if (_initialized) return;
  _initialized = true;
  await initializeDataLayer(endpoint: _endpoint, tenantId: 'ck-tenant', useBuffer: false, authToken: 'test-admin-token');
  _embedder = OllamaEmbeddingsClient(endpoint: _ollamaEndpoint, model: 'nomic-embed-text', dimensions: 768);
}

Future<void> _runStrategy(String name, IChunker chunker) async {
  await _init();
  final tenantId = 'ck-$name';
  final artId = 'ck-$name-doc';
  final bytes = utf8.encode(_docText);

  // Use InMemory for isolation between strategies
  final store = InMemoryVectorStorage();
  final registry = VectorStoreRegistryImpl();
  registry.register(VectorStoreDescriptor(id: 'mem-store', type: 'in_memory', embedderId: _embedder.id, vectorDim: _embedder.dimensions), store);

  final repo = VectorRepositoryImpl(registry: registry);
  final artifact = StoredArtifact(id: artId, tenantId: tenantId, ownerId: 'ck-owner', storageKey: '$tenantId/$artId.txt', fileName: '$artId.txt', contentType: 'text/plain', sizeBytes: bytes.length, checksum: bytes.length.toString(), createdAt: DateTime.now().toUtc());

  final result = await repo.index(artifact, bytes, IndexingPipeline(id: 'ck-$name-pipeline', storeId: 'mem-store', extractor: PlainTextExtractor(), chunker: chunker, embedder: _embedder, reranker: PassthroughReranker()));

  final results = await repo.search(_query, tenantId: tenantId, storeId: 'mem-store', embedder: _embedder, topK: 3, scoreThreshold: 0.0);
  final topScore = results.isEmpty ? 0.0 : results.first.score;
  _scores[name] = topScore;

  print('  ✅ $name: ${result.chunksCreated} chunks, top score=${topScore.toStringAsFixed(4)}');
  for (final r in results.take(2)) {
    final p = VectorPointPayload.fromMap(r.payload);
    print('     score=${r.score.toStringAsFixed(4)} "${p.text.substring(0, p.text.length.clamp(0, 70)).replaceAll('\n', ' ')}..."');
  }
}

Future<void> _s06CompareScores() async {
  final sentenceScore = _scores['sentence'] ?? 0.0;
  final mock200Score = _scores['mock-200'] ?? 0.0;
  final mock500Score = _scores['mock-500'] ?? 0.0;
  print('  ✅ Scores: sentence=${sentenceScore.toStringAsFixed(4)} mock-200=${mock200Score.toStringAsFixed(4)} mock-500=${mock500Score.toStringAsFixed(4)}');
  // SentenceChunker should be at least as good as best fixed-size
  final bestFixed = mock200Score > mock500Score ? mock200Score : mock500Score;
  if (sentenceScore < bestFixed - 0.1) {
    throw StateError('SentenceChunker score $sentenceScore significantly worse than fixed $bestFixed');
  }
}
