import 'dart:convert';
import 'package:aq_schema/aq_schema.dart';
import 'package:http/http.dart' as http;

/// Reranker using Ollama LLM to score query-document relevance.
///
/// For each candidate, asks the model to rate relevance 0-10.
/// Requires a generative model (e.g. llama3.2, mistral), not an embed model.
///
/// Note: This is a cross-encoder style reranker — slower but more accurate
/// than bi-encoder (embedding) based reranking.
final class OllamaReranker implements IReranker {
  final String endpoint;
  final String model;

  @override
  final String id;

  OllamaReranker({
    this.endpoint = 'http://ollama:11434',
    this.model = 'llama3.2:1b',
  }) : id = 'ollama-reranker-$model';

  @override
  Future<List<VectorSearchResult>> rerank(
    String query,
    List<VectorSearchResult> candidates,
  ) async {
    if (candidates.isEmpty) return candidates;

    final scored = <(VectorSearchResult, double)>[];
    for (final c in candidates) {
      final text = c.payload['text'] as String? ?? '';
      final score = await _score(query, text);
      scored.add((c, score));
    }

    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored.map((s) => VectorSearchResult(
      id: s.$1.id,
      score: s.$2,
      payload: s.$1.payload,
    )).toList();
  }

  Future<double> _score(String query, String document) async {
    final prompt = 'Rate the relevance of this document to the query on a scale of 0 to 10. '
        'Reply with ONLY a single number.\n\n'
        'Query: $query\n\n'
        'Document: ${document.substring(0, document.length.clamp(0, 300))}\n\n'
        'Score:';

    try {
      final response = await http.post(
        Uri.parse('$endpoint/api/generate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': model,
          'prompt': prompt,
          'stream': false,
          'options': {'temperature': 0, 'num_predict': 5},
        }),
      );
      if (response.statusCode != 200) return 0.0;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final text = (data['response'] as String? ?? '').trim();
      final num = double.tryParse(text.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0.0;
      return (num / 10.0).clamp(0.0, 1.0);
    } catch (_) {
      return 0.0;
    }
  }
}
