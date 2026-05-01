import 'dart:math';
import 'package:aq_schema/aq_schema.dart';

/// Deterministic mock embeddings client.
/// Same text → same vector. Different texts → different vectors.
/// Uses text hashCode as RNG seed — stable across runs.
final class MockEmbeddingsClient implements IEmbeddingsClient {
  @override
  final String id = 'mock-v1';
  @override
  final String version = '1';
  @override
  final int dimensions;
  @override
  final String defaultMetric = 'cosine';

  MockEmbeddingsClient({this.dimensions = 8});

  @override
  Future<List<double>> embed(String text) async => _embed(text);

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async =>
      texts.map(_embed).toList();

  List<double> _embed(String text) {
    final rng = Random(text.hashCode);
    final v = List.generate(dimensions, (_) => rng.nextDouble() * 2 - 1);
    return _normalize(v);
  }

  List<double> _normalize(List<double> v) {
    final norm = sqrt(v.fold(0.0, (s, x) => s + x * x));
    if (norm == 0) return v;
    return v.map((x) => x / norm).toList();
  }
}
