import 'package:aq_schema/aq_schema.dart';

/// Repository for binary file storage with metadata management.
///
/// Combines two backends:
/// - [ArtifactStorage] — stores the raw bytes
/// - [VaultStorage]    — stores the [ArtifactEntry] metadata record
///
/// Supported implementations:
/// - Local filesystem   — [LocalArtifactStorage] + [InMemoryVaultStorage]
/// - Supabase Storage   — `SupabaseArtifactStorage` + `SupabaseVaultStorage`
/// - S3/MinIO           — implement [ArtifactStorage] + your choice of [VaultStorage]
///
/// ## Multi-tenancy
///
/// Keys are automatically prefixed with `{tenantId}/` when the parent
/// [ArtifactVault] is initialised with a non-system tenant.
abstract interface class ArtifactRepository<T extends ArtifactEntry> {
  // ── Write ──────────────────────────────────────────────────────────────────

  /// Store [bytes] and save metadata [entry].
  /// If an entry with [entry.id] already exists, it is replaced.
  Future<void> save(T entry, List<int> bytes);

  /// Delete both the binary content and the metadata record.
  Future<void> delete(String id);

  // ── Read ───────────────────────────────────────────────────────────────────

  /// Load the raw bytes for [id].  Returns null if not found.
  Future<List<int>?> loadBytes(String id);

  /// Stream bytes in chunks (useful for large files).
  Stream<List<int>> streamBytes(String id);

  /// Get metadata record only (no binary data transferred).
  Future<T?> findById(String id);

  Future<List<T>> findAll({VaultQuery? query});

  Future<PageResult<T>> findPage(VaultQuery query);

  Future<bool> exists(String id);

  // ── Watch ──────────────────────────────────────────────────────────────────

  Stream<List<T>> watchAll({VaultQuery? query});
}
