import 'package:aq_schema/aq_schema.dart';

final class VectorStoreRegistryImpl implements IVectorStoreRegistry {
  final _stores = <String, (VectorStoreDescriptor, VectorStorage)>{};

  @override
  void register(VectorStoreDescriptor descriptor, VectorStorage storage) {
    _stores[descriptor.id] = (descriptor, storage);
  }

  @override
  VectorStorage resolve(String storeId) {
    final entry = _stores[storeId];
    if (entry == null) throw StateError('VectorStore not found: $storeId');
    return entry.$2;
  }

  @override
  VectorStoreDescriptor descriptor(String storeId) {
    final entry = _stores[storeId];
    if (entry == null) throw StateError('VectorStore not found: $storeId');
    return entry.$1;
  }

  @override
  List<VectorStoreDescriptor> get all =>
      _stores.values.map((e) => e.$1).toList();

  @override
  VectorStoreDescriptor? findCompatible(String embedderId, int vectorDim) =>
      all
          .where((d) => d.embedderId == embedderId && d.vectorDim == vectorDim)
          .firstOrNull;
}
