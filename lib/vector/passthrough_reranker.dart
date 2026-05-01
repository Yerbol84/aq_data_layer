import 'package:aq_schema/aq_schema.dart';

/// No-op reranker — returns candidates unchanged.
final class PassthroughReranker implements IReranker {
  @override
  final String id = 'passthrough-v1';

  @override
  Future<List<VectorSearchResult>> rerank(
    String query,
    List<VectorSearchResult> candidates,
  ) async =>
      candidates;
}
