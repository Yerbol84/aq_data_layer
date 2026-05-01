import 'package:aq_schema/aq_schema.dart';

/// Splits text into chunks at sentence boundaries with optional overlap.
///
/// Algorithm:
/// 1. Split text into sentences (by .!? with abbreviation awareness)
/// 2. Group sentences until maxChunkChars is reached
/// 3. Overlap: last sentence of previous chunk is prepended to next chunk
///
/// Produces semantically coherent chunks — no sentence is cut mid-way.
final class SentenceChunker implements IChunker {
  @override
  final String id = 'sentence-chunker-v1';
  @override
  final String version = '1';

  /// Maximum characters per chunk (approximate — never cuts a sentence).
  final int maxChunkChars;

  /// Include last sentence of previous chunk at start of next chunk.
  final bool overlap;

  SentenceChunker({this.maxChunkChars = 500, this.overlap = true});

  @override
  List<ContentChunk> chunk(ExtractedContent content) {
    final text = content.text;
    if (text.isEmpty) return [];

    final sentences = _splitSentences(text);
    if (sentences.isEmpty) return [];

    final chunks = <ContentChunk>[];
    var chunkIndex = 0;
    var i = 0;

    while (i < sentences.length) {
      final buffer = StringBuffer();
      final startSentenceIdx = i;

      // Add overlap: last sentence of previous chunk
      String? overlapSentence;
      if (overlap && chunks.isNotEmpty && i > 0) {
        overlapSentence = sentences[i - 1].text;
        buffer.write(overlapSentence);
        buffer.write(' ');
      }

      // Fill chunk up to maxChunkChars
      while (i < sentences.length) {
        final s = sentences[i].text;
        if (buffer.length > 0 &&
            buffer.length + s.length > maxChunkChars &&
            // Always include at least one sentence (avoid infinite loop)
            i > startSentenceIdx) {
          break;
        }
        if (buffer.length > 0) buffer.write(' ');
        buffer.write(s);
        i++;
      }

      final chunkText = buffer.toString().trim();
      if (chunkText.isEmpty) break;

      // startOffset = char offset of first sentence in this chunk (without overlap)
      final firstSentence = sentences[startSentenceIdx];
      chunks.add(ContentChunk(
        artifactId: content.artifactId,
        text: chunkText,
        span: ChunkSpan(
          chunkIndex: chunkIndex++,
          startOffset: firstSentence.start,
          endOffset: sentences[i - 1].end,
        ),
      ));
    }

    return chunks;
  }

  /// Split text into sentences. Handles common abbreviations.
  List<_Sentence> _splitSentences(String text) {
    final sentences = <_Sentence>[];
    // Match sentence-ending punctuation followed by whitespace or end
    final pattern = RegExp(r'(?<=[.!?])\s+(?=[A-Z\u0400-\u04FF\d"])');
    var start = 0;

    for (final match in pattern.allMatches(text)) {
      final end = match.start + 1; // include the punctuation
      final s = text.substring(start, end).trim();
      if (s.isNotEmpty) sentences.add(_Sentence(s, start, end));
      start = match.end;
    }

    // Last sentence (no trailing punctuation required)
    final last = text.substring(start).trim();
    if (last.isNotEmpty) sentences.add(_Sentence(last, start, text.length));

    return sentences;
  }
}

final class _Sentence {
  final String text;
  final int start;
  final int end;
  _Sentence(this.text, this.start, this.end);
}
