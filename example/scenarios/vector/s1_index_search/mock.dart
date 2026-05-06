// Vector / S1: Index + Search — режим Mock
// Запуск: dart run vector/s1_index_search/mock.dart

import 'package:aq_schema/aq_schema.dart';
import 'package:aq_schema/data_testing.dart';

void main() async {
  MockDataLayer.register(MockDataBackend.empty());
  final repo = IDataLayer.instance.vectors(collection: 'docs__vectors');

  await repo.upsertAll([
    VectorEntry(id: 'doc1-c0', vector: [1.0, 0.0, 0.0, 0.0], payload: {'text': 'Dart is fast', 'docId': 'doc1'}),
    VectorEntry(id: 'doc1-c1', vector: [0.9, 0.1, 0.0, 0.0], payload: {'text': 'Dart is typed', 'docId': 'doc1'}),
    VectorEntry(id: 'doc2-c0', vector: [0.0, 0.0, 1.0, 0.0], payload: {'text': 'Python is dynamic', 'docId': 'doc2'}),
  ]);
  print('Indexed: 3 chunks');

  final results = await repo.search([1.0, 0.0, 0.0, 0.0], tenantId: 'tenant-a', limit: 2, scoreThreshold: 0.5);
  assert(results.isNotEmpty);
  for (final r in results) {
    print('  ${r.id}: score=${r.score.toStringAsFixed(3)}, text=${r.payload['text']}');
  }

  print('✅ Vector S1 Index+Search (mock) — OK');
  await IDataLayer.disconnect();
}
