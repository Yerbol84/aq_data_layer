import 'package:aq_schema/aq_schema.dart';

/// Simple fixed-size chunker for testing pipeline mechanics.
final class MockChunker implements IChunker {
  @override
  final String id = 'mock-chunker-v1';
  @override
  final String version = '1';

  final int maxChunkSize;

  MockChunker({this.maxChunkSize = 200});

  @override
  List<ContentChunk> chunk(ExtractedContent content) {
    final text = content.text;
    if (text.isEmpty) return [];
    final chunks = <ContentChunk>[];
    var start = 0;
    var index = 0;
    while (start < text.length) {
      final end = (start + maxChunkSize).clamp(0, text.length);
      chunks.add(ContentChunk(
        artifactId: content.artifactId,
        text: text.substring(start, end),
        span: ChunkSpan(
          chunkIndex: index++,
          startOffset: start,
          endOffset: end,
        ),
      ));
      start = end;
    }
    return chunks;
  }
}
