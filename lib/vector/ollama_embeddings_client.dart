import 'dart:convert';
import 'package:aq_schema/aq_schema.dart';
import 'package:http/http.dart' as http;

/// [IEmbeddingsClient] backed by Ollama HTTP API.
///
/// Requires Ollama running and model pulled:
///   docker exec ollama ollama pull nomic-embed-text
///
/// Default endpoint in Docker stack: http://ollama:11434
final class OllamaEmbeddingsClient implements IEmbeddingsClient {
  final String endpoint;
  final String model;

  @override
  final String id;
  @override
  final String version = '1';
  @override
  final int dimensions;
  @override
  final String defaultMetric = 'cosine';

  OllamaEmbeddingsClient({
    this.endpoint = 'http://ollama:11434',
    this.model = 'nomic-embed-text',
    this.dimensions = 768,
  }) : id = 'ollama-$model';

  @override
  Future<List<double>> embed(String text) async {
    final response = await http.post(
      Uri.parse('$endpoint/api/embeddings'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'model': model, 'prompt': text}),
    );
    if (response.statusCode != 200) {
      throw StateError('Ollama error ${response.statusCode}: ${response.body}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['embedding'] as List).cast<double>();
  }

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) =>
      Future.wait(texts.map(embed));
}
