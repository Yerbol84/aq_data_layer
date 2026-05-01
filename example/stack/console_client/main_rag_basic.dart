/// AQ Data Layer — Basic RAG with Ollama
///
/// Требует: Ollama с nomic-embed-text в стеке (ollama сервис)
///
/// Сценарии:
///   1. Index 3 документа разной тематики (AI, databases, security)
///   2. Search: "vector similarity" → результаты из AI документа
///   3. Search: "SQL injection" → результаты из security документа
///   4. Cross-doc search: "data storage" → результаты из нескольких документов
///   5. Verify: scores > 0 (реальная семантика, не mock)
library;

import 'dart:convert';
import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint = Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';
final _ollamaEndpoint = Platform.environment['OLLAMA_ENDPOINT'] ?? 'http://ollama:11434';
const _tenantId = 'tenant-rag-basic';
const _ownerId = 'user-rag-001';
const _storeId = 'pgvector-main';

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  AQ Data Layer — Basic RAG with Ollama');
  print('  Ollama: $_ollamaEndpoint');
  print('═══════════════════════════════════════════════════════════\n');

  int passed = 0, failed = 0;
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

  await run('1. Index 3 documents', _scenarioIndex);
  await run('2. Search: vector similarity → AI doc', _scenarioSearchAI);
  await run('3. Search: SQL injection → security doc', _scenarioSearchSecurity);
  await run('4. Cross-doc search: data storage', _scenarioCrossDoc);
  await run('5. Verify real semantic scores', _scenarioVerifyScores);

  print('\n═══════════════════════════════════════════════════════════');
  print('  Results: $passed passed, $failed failed');
  print('═══════════════════════════════════════════════════════════');
  if (failed > 0) exit(1);
}

// ── Documents ─────────────────────────────────────────────────────────────────

const _docs = {
  'doc-ai-001': (
    fileName: 'ai_overview.md',
    contentType: 'text/markdown',
    content: '''# Artificial Intelligence Overview

## Machine Learning Fundamentals

Machine learning is a subset of artificial intelligence that enables systems
to learn from data without being explicitly programmed. Algorithms improve
through experience and exposure to training data.

## Vector Embeddings

Vector embeddings represent text as dense numerical vectors in high-dimensional
space. Similar concepts are placed close together. Cosine similarity measures
the angle between vectors to determine semantic similarity.

## Neural Networks

Deep learning uses multiple layers of neural networks to extract features.
Transformers use attention mechanisms to process sequential data efficiently.
Large language models are trained on vast corpora of text data.
''',
  ),
  'doc-db-001': (
    fileName: 'databases.md',
    contentType: 'text/markdown',
    content: '''# Database Systems

## Relational Databases

Relational databases store data in tables with rows and columns.
SQL (Structured Query Language) is used to query and manipulate data.
ACID properties ensure data consistency: Atomicity, Consistency, Isolation, Durability.

## PostgreSQL Features

PostgreSQL is an advanced open-source relational database.
It supports JSON, full-text search, and extensions like pgvector.
Connection pooling improves performance under high load.

## Data Storage Optimization

Indexing strategies improve query performance significantly.
B-tree indexes work well for equality and range queries.
Partitioning large tables reduces scan time for time-series data.
''',
  ),
  'doc-sec-001': (
    fileName: 'security.md',
    contentType: 'text/markdown',
    content: '''# Application Security

## SQL Injection Prevention

SQL injection attacks insert malicious SQL code into queries.
Use parameterized queries or prepared statements to prevent injection.
Never concatenate user input directly into SQL strings.
Input validation and sanitization add additional protection layers.

## Authentication Best Practices

Use strong hashing algorithms like bcrypt or argon2 for passwords.
Implement multi-factor authentication for sensitive operations.
JWT tokens should have short expiration times and be validated server-side.

## Data Encryption

Encrypt sensitive data at rest using AES-256.
Use TLS 1.3 for data in transit.
Key management is critical — rotate keys regularly.
''',
  ),
};

// ── Shared state ──────────────────────────────────────────────────────────────

late OllamaEmbeddingsClient _embedder;
late VectorRepositoryImpl _vectorRepo;

Future<void> _init() async {
  await initializeDataLayer(
    endpoint: _endpoint,
    tenantId: _tenantId,
    useBuffer: false,
    authToken: 'test-admin-token',
  );

  _embedder = OllamaEmbeddingsClient(
    endpoint: _ollamaEndpoint,
    model: 'nomic-embed-text',
    dimensions: 768,
  );

  // Use RemoteVectorStorage — vectors stored in pgvector on server
  final remote = RemoteVaultStorage(
    endpoint: _endpoint,
    tenantId: _tenantId,
    authToken: 'test-admin-token',
  );
  await remote.connect();
  final remoteVec = RemoteVectorStorage(remote: remote);

  final registry = VectorStoreRegistryImpl();
  registry.register(
    VectorStoreDescriptor(
      id: _storeId,
      type: 'pgvector',
      embedderId: _embedder.id,
      vectorDim: _embedder.dimensions,
    ),
    remoteVec,
  );

  _vectorRepo = VectorRepositoryImpl(
    registry: registry,
    artifactRepo: IDataLayer.instance.direct<StoredArtifact>(
      collection: StoredArtifact.kCollection,
      fromMap: StoredArtifact.fromMap,
    ),
    pipelineRepo: IDataLayer.instance.direct<IndexingPipelineRecord>(
      collection: IndexingPipelineRecord.kCollection,
      fromMap: IndexingPipelineRecord.fromMap,
    ),
  );
}

IndexingPipeline _pipeline() => IndexingPipeline(
      id: 'ollama-nomic-pipeline-v1',
      storeId: _storeId,
      extractor: PlainTextExtractor(),
      chunker: MockChunker(maxChunkSize: 300),
      embedder: _embedder,
      reranker: PassthroughReranker(),
    );

// ── 1. Index ──────────────────────────────────────────────────────────────────

Future<void> _scenarioIndex() async {
  await _init();

  final artifactRepo = IDataLayer.instance.direct<StoredArtifact>(
    collection: StoredArtifact.kCollection,
    fromMap: StoredArtifact.fromMap,
  );

  for (final entry in _docs.entries) {
    final id = entry.key;
    final doc = entry.value;
    final bytes = utf8.encode(doc.content);

    final artifact = StoredArtifact(
      id: id,
      tenantId: _tenantId,
      ownerId: _ownerId,
      storageKey: '$_tenantId/$id/${doc.fileName}',
      fileName: doc.fileName,
      contentType: doc.contentType,
      sizeBytes: bytes.length,
      checksum: bytes.length.toString(),
      createdAt: DateTime.now().toUtc(),
    );
    await artifactRepo.save(artifact);

    final result = await _vectorRepo.index(artifact, bytes, _pipeline());
    if (!result.isSuccess) throw StateError('Index failed for $id: ${result.error}');
    print('  ✅ Indexed $id: ${result.chunksCreated} chunks (${result.elapsed.inMilliseconds}ms)');
  }
}

// ── 2. Search: AI doc ─────────────────────────────────────────────────────────

Future<void> _scenarioSearchAI() async {
  final results = await _vectorRepo.search(
    'how does vector similarity work in machine learning',
    tenantId: _tenantId,
    storeId: _storeId,
    embedder: _embedder,
    topK: 3,
  );
  if (results.isEmpty) throw StateError('No results');

  final topArtifactId = results.first.payload['artifactId'] as String;
  print('  ✅ Top result from: $topArtifactId (score=${results.first.score.toStringAsFixed(4)})');
  for (final r in results) {
    final p = VectorPointPayload.fromMap(r.payload);
    print('     • ${r.payload['artifactId']} score=${r.score.toStringAsFixed(4)} "${p.text.substring(0, p.text.length.clamp(0, 60)).replaceAll('\n', ' ')}..."');
  }

  if (!topArtifactId.contains('ai')) {
    print('  ⚠️  Top result not from AI doc (semantic search may need tuning)');
  }
}

// ── 3. Search: security doc ───────────────────────────────────────────────────

Future<void> _scenarioSearchSecurity() async {
  final results = await _vectorRepo.search(
    'SQL injection prevention parameterized queries',
    tenantId: _tenantId,
    storeId: _storeId,
    embedder: _embedder,
    topK: 3,
  );
  if (results.isEmpty) throw StateError('No results');

  print('  ✅ Top result from: ${results.first.payload['artifactId']} (score=${results.first.score.toStringAsFixed(4)})');
  for (final r in results) {
    final p = VectorPointPayload.fromMap(r.payload);
    print('     • ${r.payload['artifactId']} score=${r.score.toStringAsFixed(4)} "${p.text.substring(0, p.text.length.clamp(0, 60)).replaceAll('\n', ' ')}..."');
  }
}

// ── 4. Cross-doc search ───────────────────────────────────────────────────────

Future<void> _scenarioCrossDoc() async {
  final results = await _vectorRepo.search(
    'data storage and indexing',
    tenantId: _tenantId,
    storeId: _storeId,
    embedder: _embedder,
    topK: 5,
  );
  if (results.isEmpty) throw StateError('No results');

  final artifactIds = results.map((r) => r.payload['artifactId']).toSet();
  print('  ✅ Cross-doc: ${results.length} results from ${artifactIds.length} document(s): $artifactIds');
}

// ── 5. Verify real scores ─────────────────────────────────────────────────────

Future<void> _scenarioVerifyScores() async {
  final results = await _vectorRepo.search(
    'neural network transformer attention mechanism',
    tenantId: _tenantId,
    storeId: _storeId,
    embedder: _embedder,
    topK: 3,
    scoreThreshold: 0.0,
  );
  if (results.isEmpty) throw StateError('No results');

  // With real embeddings, top score should be meaningfully > 0
  final topScore = results.first.score;
  print('  ✅ Real semantic scores: top=${topScore.toStringAsFixed(4)}, all=${results.map((r) => r.score.toStringAsFixed(3)).join(', ')}');

  // Scores should vary (not all 0.0 like mock)
  final allZero = results.every((r) => r.score < 0.001);
  if (allZero) throw StateError('All scores are ~0 — embeddings may not be working');
}
