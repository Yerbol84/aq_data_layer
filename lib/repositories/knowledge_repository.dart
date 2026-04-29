import 'package:aq_schema/aq_schema.dart';

/// A knowledge document as seen by the application layer.
/// It is simultaneously a file (raw bytes) and a set of vector chunks.
abstract interface class KnowledgeDocument implements ArtifactEntry {
  /// Unique knowledge base this document belongs to.
  String get knowledgeBaseId;

  /// Whether this document's vector index is current.
  /// False when the file was updated but re-indexing hasn't finished yet.
  bool get vectorsUpToDate;

  /// Number of indexed vector chunks.
  int get chunkCount;
}

/// Result of a semantic search across a knowledge base.
final class KnowledgeSearchResult {
  final String documentId;
  final String documentName;
  final String chunkId;
  final int chunkIndex;
  final String chunkText;
  final double score;

  const KnowledgeSearchResult({
    required this.documentId,
    required this.documentName,
    required this.chunkId,
    required this.chunkIndex,
    required this.chunkText,
    required this.score,
  });

  @override
  String toString() =>
      'KnowledgeSearchResult($documentName chunk#$chunkIndex score:${score.toStringAsFixed(3)})';
}

/// A chunk produced by the splitter, ready for embedding.
final class DocumentChunk {
  final int index;
  final String text;
  const DocumentChunk({required this.index, required this.text});
}

/// Strategy for splitting document text into chunks.
abstract interface class TextSplitter {
  List<DocumentChunk> split(String text);
}

/// Simple fixed-size splitter (characters, with overlap).
final class FixedSizeSplitter implements TextSplitter {
  final int chunkSize;
  final int overlap;

  const FixedSizeSplitter({this.chunkSize = 512, this.overlap = 64});

  @override
  List<DocumentChunk> split(String text) {
    if (text.isEmpty) return [];
    final chunks = <DocumentChunk>[];
    var start = 0;
    var index = 0;
    while (start < text.length) {
      final end = (start + chunkSize).clamp(0, text.length);
      chunks
          .add(DocumentChunk(index: index++, text: text.substring(start, end)));
      start += chunkSize - overlap;
      if (start >= text.length) break;
    }
    return chunks;
  }
}

/// Embed function type — produce a vector for a text chunk.
typedef EmbedFn = Future<List<double>> Function(String text);

/// Repository that treats a file and its vector index as ONE entity.
///
/// ## Design rationale
///
/// In isolation, files and vectors are managed by different backends.
/// But from the application's perspective, uploading a document, indexing it,
/// and searching it is one conceptual operation on one entity.
///
/// [KnowledgeRepository] orchestrates:
/// 1. [ArtifactStorage]  — stores the raw file bytes
/// 2. [VaultStorage]     — stores metadata ([KnowledgeDocument])
/// 3. [VectorStorage]    — stores the per-chunk embeddings
///
/// When a document is updated, the repository automatically re-indexes its
/// vectors via [embed] + [splitter], keeping both representations in sync.
///
/// ## Usage
///
/// ```dart
/// // In KnowledgeVault factory:
/// final kb = knowledgeVault.documents<MyDoc>(
///   kbId: 'kb-main',
///   fromMap: MyDoc.fromMap,
///   embed: (text) => llm.embedText(text),
/// );
///
/// // Save + index in one call
/// await kb.save(doc, fileBytes, rawText: extractedText);
///
/// // Semantic search
/// final results = await kb.search('What is the refund policy?', embed: llm.embedText);
/// ```
abstract interface class KnowledgeRepository<T extends KnowledgeDocument> {
  // ── Write ──────────────────────────────────────────────────────────────────

  /// Store the file and index its vectors in one atomic operation.
  ///
  /// [rawText] is the extracted text used for chunking + embedding.
  /// If [rawText] is null, only the file is stored (no vector index).
  Future<void> save(
    T document,
    List<int> fileBytes, {
    String? rawText,
  });

  /// Re-index only the vectors for an existing document.
  /// Use when the file has not changed but the embedding model was updated.
  Future<void> reIndex(String documentId, String rawText);

  /// Delete the document, its file, and all its vector chunks.
  Future<void> delete(String documentId);

  // ── Read ───────────────────────────────────────────────────────────────────

  Future<T?> findById(String documentId);
  Future<List<T>> findAll({VaultQuery? query});
  Future<PageResult<T>> findPage(VaultQuery query);
  Future<List<int>?> loadBytes(String documentId);

  // ── Search ─────────────────────────────────────────────────────────────────

  /// Semantic search: embed [query] and find the most relevant chunks.
  ///
  /// [filter] restricts results to documents matching metadata predicates
  /// (e.g. `VaultQuery().where('knowledgeBaseId', equals, 'kb-main')`).
  Future<List<KnowledgeSearchResult>> search(
    String query, {
    required EmbedFn embed,
    int limit = 10,
    double scoreThreshold = 0.3,
    VaultQuery? filter,
  });

  // ── Watch ──────────────────────────────────────────────────────────────────

  Stream<List<T>> watchAll({VaultQuery? query});
}
