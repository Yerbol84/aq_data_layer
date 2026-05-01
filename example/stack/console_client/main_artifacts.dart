/// AQ Data Layer — Artifacts Scenarios
///
/// Требует: сервер запущен с ARTIFACT_PATH=/data/artifacts
///
/// Сценарии:
///   1. Upload — загрузить markdown файл (байты + метаданные)
///   2. Find   — найти артефакт по метаданным
///   3. Annotate (user) — добавить highlight аннотацию от пользователя
///   4. Annotate (LLM)  — добавить vectorRef аннотацию от LLM
///   5. History — получить историю изменений аннотации
///   6. Download — скачать байты и проверить контент
library;

import 'dart:convert';
import 'dart:io';
import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

final _endpoint =
    Platform.environment['VAULT_ENDPOINT'] ?? 'http://localhost:8765';

void main() async {
  print('═══════════════════════════════════════════════════════════');
  print('  AQ Data Layer — Artifacts Scenarios');
  print('═══════════════════════════════════════════════════════════\n');

  int passed = 0;
  int failed = 0;

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

  await run('1. Upload artifact', _scenarioUpload);
  await run('2. Find artifact by metadata', _scenarioFind);
  await run('3. User annotation (highlight)', _scenarioUserAnnotation);
  await run('4. LLM annotation (vectorRef)', _scenarioLlmAnnotation);
  await run('5. Annotation history', _scenarioHistory);
  await run('6. Download and verify bytes', _scenarioDownload);

  print('\n═══════════════════════════════════════════════════════════');
  print('  Results: $passed passed, $failed failed');
  print('═══════════════════════════════════════════════════════════');

  if (failed > 0) exit(1);
}

// ── Shared state ──────────────────────────────────────────────────────────────

const _tenantId = 'tenant-artifacts-test';
const _ownerId = 'user-001';
const _artifactId = 'artifact-doc-001';
const _annotationId = 'annotation-user-001';
const _llmAnnotationId = 'annotation-llm-001';

final _docContent = utf8.encode('''# Test Document

This is a **test markdown** document for artifact storage scenarios.

## Section 1

Lorem ipsum dolor sit amet, consectetur adipiscing elit.
Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.

## Section 2

Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris.
''');

Future<(RemoteVaultStorage, RemoteArtifactStorage)> _connect() async {
  final remote = RemoteVaultStorage(
    endpoint: _endpoint,
    tenantId: _tenantId,
    authToken: 'test-admin-token',
  );
  await remote.connect();
  final artifacts = RemoteArtifactStorage(remote: remote);
  return (remote, artifacts);
}

// ── 1. Upload ─────────────────────────────────────────────────────────────────

Future<void> _scenarioUpload() async {
  await initializeDataLayer(
    endpoint: _endpoint,
    tenantId: _tenantId,
    useBuffer: false,
    authToken: 'test-admin-token',
  );

  final (_, artifacts) = await _connect();

  // Upload bytes
  final key = '$_tenantId/$_artifactId/content.md';
  await artifacts.put(key, _docContent, contentType: 'text/markdown');
  print('  ✅ Bytes uploaded: ${_docContent.length} bytes → $key');

  // Save metadata
  final repo = IDataLayer.instance.direct<StoredArtifact>(
    collection: StoredArtifact.kCollection,
    fromMap: StoredArtifact.fromMap,
  );

  final artifact = StoredArtifact(
    id: _artifactId,
    tenantId: _tenantId,
    ownerId: _ownerId,
    storageKey: key,
    fileName: 'test-document.md',
    contentType: 'text/markdown',
    sizeBytes: _docContent.length,
    checksum: _docContent.length.toString(), // simplified checksum
    createdAt: DateTime.now().toUtc(),
    meta: {'source': 'scenario-test', 'version': '1'},
  );

  await repo.save(artifact);
  print('  ✅ Metadata saved: ${artifact.id} (${artifact.sizeBytes} bytes)');
}

// ── 2. Find ───────────────────────────────────────────────────────────────────

Future<void> _scenarioFind() async {
  final repo = IDataLayer.instance.direct<StoredArtifact>(
    collection: StoredArtifact.kCollection,
    fromMap: StoredArtifact.fromMap,
  );

  // Find by id
  final found = await repo.findById(_artifactId);
  if (found == null) throw StateError('Artifact not found: $_artifactId');
  print('  ✅ Found by id: ${found.fileName} (${found.sizeBytes} bytes)');

  // Find by query
  final results = await repo.findAll(
    query: VaultQuery(
      filters: [VaultFilter('contentType', VaultOperator.equals, 'text/markdown')],
    ),
  );
  if (results.isEmpty) throw StateError('No artifacts found by contentType');
  print('  ✅ Found by contentType: ${results.length} artifact(s)');
}

// ── 3. User annotation ────────────────────────────────────────────────────────

Future<void> _scenarioUserAnnotation() async {
  final repo = IDataLayer.instance.logged<DocumentAnnotation>(
    collection: DocumentAnnotation.kCollection,
    fromMap: DocumentAnnotation.fromMap,
  );

  final annotation = DocumentAnnotation(
    id: _annotationId,
    tenantId: _tenantId,
    ownerId: _ownerId,
    artifactId: _artifactId,
    actorType: AnnotationActorType.user,
    actorId: _ownerId,
    type: AnnotationType.highlight,
    range: const AnnotationRange(startOffset: 18, endOffset: 33),
    content: 'Important section',
    createdAt: DateTime.now().toUtc(),
  );

  await repo.save(annotation, actorId: _ownerId);
  print('  ✅ User annotation saved: ${annotation.id} [${annotation.type.value}]');

  // Update content to generate history
  final updated = DocumentAnnotation(
    id: _annotationId,
    tenantId: _tenantId,
    ownerId: _ownerId,
    artifactId: _artifactId,
    actorType: AnnotationActorType.user,
    actorId: _ownerId,
    type: AnnotationType.highlight,
    range: const AnnotationRange(startOffset: 18, endOffset: 33),
    content: 'Very important section — updated',
    createdAt: annotation.createdAt,
  );
  await repo.save(updated, actorId: _ownerId);
  print('  ✅ User annotation updated (history entry created)');
}

// ── 4. LLM annotation ─────────────────────────────────────────────────────────

Future<void> _scenarioLlmAnnotation() async {
  final repo = IDataLayer.instance.logged<DocumentAnnotation>(
    collection: DocumentAnnotation.kCollection,
    fromMap: DocumentAnnotation.fromMap,
  );

  final annotation = DocumentAnnotation(
    id: _llmAnnotationId,
    tenantId: _tenantId,
    ownerId: _ownerId,
    artifactId: _artifactId,
    actorType: AnnotationActorType.llm,
    actorId: 'gpt-4o',
    type: AnnotationType.vectorRef,
    range: const AnnotationRange(startOffset: 0, endOffset: 100),
    content: 'Semantic chunk: introduction paragraph',
    meta: {
      'chunkId': 'chunk-abc-123',
      'score': 0.92,
      'query': 'test document overview',
    },
    createdAt: DateTime.now().toUtc(),
  );

  await repo.save(annotation, actorId: annotation.actorId);
  print('  ✅ LLM annotation saved: ${annotation.id} [${annotation.type.value}] actor=${annotation.actorId}');
}

// ── 5. History ────────────────────────────────────────────────────────────────

Future<void> _scenarioHistory() async {
  final repo = IDataLayer.instance.logged<DocumentAnnotation>(
    collection: DocumentAnnotation.kCollection,
    fromMap: DocumentAnnotation.fromMap,
  );

  final history = await repo.getHistory(_annotationId);
  if (history.isEmpty) throw StateError('No history for annotation $_annotationId');
  print('  ✅ History entries: ${history.length}');
  for (final entry in history) {
    print('     • [${entry.changedAt.toIso8601String()}] ${entry.diff.keys.toList()}');
  }
}

// ── 6. Download ───────────────────────────────────────────────────────────────

Future<void> _scenarioDownload() async {
  final (_, artifacts) = await _connect();

  final key = '$_tenantId/$_artifactId/content.md';
  final bytes = await artifacts.get(key);
  if (bytes == null) throw StateError('Bytes not found for key: $key');
  if (bytes.length != _docContent.length) {
    throw StateError('Size mismatch: got ${bytes.length}, expected ${_docContent.length}');
  }

  final content = utf8.decode(bytes);
  if (!content.contains('# Test Document')) {
    throw StateError('Content mismatch: expected markdown header');
  }
  print('  ✅ Downloaded: ${bytes.length} bytes, content verified');
}
