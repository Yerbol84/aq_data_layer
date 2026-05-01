import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aq_schema/aq_schema.dart';

import '../exceptions/vault_exceptions.dart';

/// [VaultStorage] backed by Supabase (PostgREST + Management API).
///
/// Uses only [dart:io] and [dart:convert] — zero external dependencies.
///
/// ## Setup
///
/// Run the init SQL once on your Supabase project:
/// ```sql
/// -- See supabase_init.sql in the doc/ folder
/// ```
///
/// ## Usage
///
/// ```dart
/// final storage = SupabaseVaultStorage(
///   url: 'https://xyzxyz.supabase.co',
///   anonKey: 'your-anon-key',
/// );
/// final vault = Vault(storage: storage, tenantId: userId);
/// ```
///
/// ## How collections map to Supabase tables
///
/// Every collection name maps to a Supabase table of the same name.
/// Tenant prefixing (e.g. `user123__documents`) is handled by [Vault].
/// The table schema is always:
/// ```
/// id        TEXT PRIMARY KEY
/// data      JSONB NOT NULL
/// tenant_id TEXT  (optional, for RLS)
/// ```
final class SupabaseVaultStorage implements VaultStorage, SqlQueryTranslator {
  final String _baseUrl;
  final String _anonKey;

  /// Optional service-role key for DDL operations (createIndex etc.).
  final String? _serviceKey;

  final Duration _timeout;

  // Track which collections we've verified exist to avoid repeat HEAD calls.
  final _knownCollections = <String>{};

  // Change notification — HTTP storage polls are not reactive;
  // we fire local events after writes so in-process watches work.
  final _controllers = <String, StreamController<void>>{};

  SupabaseVaultStorage({
    required String url,
    required String anonKey,
    String? serviceKey,
    Duration timeout = const Duration(seconds: 15),
  })  : _baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url,
        _anonKey = anonKey,
        _serviceKey = serviceKey,
        _timeout = timeout;

  // ── Collections ────────────────────────────────────────────────────────────

  @override
  Future<void> ensureCollection(String collection) async {
    if (_knownCollections.contains(collection)) return;
    // Verify the table exists by doing a HEAD request.
    // If it doesn't exist, throw a descriptive error.
    try {
      final uri = Uri.parse('$_baseUrl/rest/v1/$collection?limit=0');
      final client = HttpClient();
      final req = await client.headUrl(uri).timeout(_timeout);
      _addHeaders(req, useServiceKey: false);
      final res = await req.close().timeout(_timeout);
      await res.drain<void>();
      client.close();
      if (res.statusCode == 404) {
        throw VaultStorageException(
          'Collection "$collection" not found in Supabase. '
          'Run the init SQL to create the table.',
        );
      }
      _knownCollections.add(collection);
    } on VaultStorageException {
      rethrow;
    } catch (e) {
      throw VaultStorageException(
        'Cannot reach Supabase at $_baseUrl',
        cause: e,
      );
    }
  }

  // ── CRUD ───────────────────────────────────────────────────────────────────

  @override
  Future<void> put(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    // UPSERT via PostgREST (POST with Prefer: resolution=merge-duplicates)
    final body = jsonEncode({'id': id, 'data': data});
    await _request(
      'POST',
      '/rest/v1/$collection',
      body: body,
      headers: {'Prefer': 'resolution=merge-duplicates,return=minimal'},
    );
    _notify(collection);
  }

  @override
  Future<Map<String, dynamic>?> get(String collection, String id) async {
    final rows = await _request(
      'GET',
      '/rest/v1/$collection?id=eq.${Uri.encodeQueryComponent(id)}&select=data',
    );
    final list = rows as List?;
    if (list == null || list.isEmpty) return null;
    final row = list.first as Map<String, dynamic>;
    final d = row['data'];
    if (d == null) return null;
    if (d is Map) return Map<String, dynamic>.from(d);
    return jsonDecode(d as String) as Map<String, dynamic>;
  }

  @override
  Future<void> delete(String collection, String id) async {
    await _request(
      'DELETE',
      '/rest/v1/$collection?id=eq.${Uri.encodeQueryComponent(id)}',
    );
    _notify(collection);
  }

  @override
  Future<bool> exists(String collection, String id) async {
    final result = await get(collection, id);
    return result != null;
  }

  @override
  Future<void> putAll(
    String collection,
    Map<String, Map<String, dynamic>> entries,
  ) async {
    if (entries.isEmpty) return;
    final body = jsonEncode(
      entries.entries.map((e) => {'id': e.key, 'data': e.value}).toList(),
    );
    await _request(
      'POST',
      '/rest/v1/$collection',
      body: body,
      headers: {'Prefer': 'resolution=merge-duplicates,return=minimal'},
    );
    _notify(collection);
  }

  // ── Queries ────────────────────────────────────────────────────────────────

  @override
  Future<List<Map<String, dynamic>>> query(
    String collection,
    VaultQuery q,
  ) async {
    final url = _buildQueryUrl(collection, q, forCount: false);
    final rows = await _request('GET', url) as List;
    return _extractDataList(rows);
  }

  @override
  Future<PageResult<Map<String, dynamic>>> queryPage(
    String collection,
    VaultQuery q,
  ) async {
    // Supabase returns total count in the Content-Range header when
    // Prefer: count=exact is set.
    final url = _buildQueryUrl(collection, q, forCount: true);
    final (rows, total) = await _requestWithCount('GET', url);
    final items = _extractDataList(rows);
    return PageResult(
      items: items,
      total: total,
      offset: q.offset ?? 0,
      limit: q.limit ?? items.length,
    );
  }

  @override
  Future<int> count(String collection, VaultQuery q) async {
    final url = _buildQueryUrl(collection, q, forCount: true);
    final (_, total) = await _requestWithCount('GET', url);
    return total;
  }

  // ── Indexes ────────────────────────────────────────────────────────────────

  @override
  Future<void> createIndex(String collection, VaultIndex index) async {
    // PostgREST/Supabase: create a GIN expression index on the JSONB data column.
    // Requires service-role key and Supabase management API or direct SQL.
    // We execute via the SQL endpoint if service key is available.
    if (_serviceKey == null) return; // skip silently if no admin access

    final sql = '''
CREATE INDEX IF NOT EXISTS idx_${collection}_${index.field.replaceAll('.', '_')}
  ON "$collection" USING btree ((data->>'${index.field}'));
''';
    await _executeSql(sql);
  }

  @override
  Future<void> updateIndex(
      String collection, String id, Map<String, dynamic> indexData) async {
    // PostgREST indexes are maintained by Postgres automatically.
  }

  @override
  Future<void> removeFromIndex(String collection, String id) async {
    // Managed by Postgres.
  }

  // ── Transactions ───────────────────────────────────────────────────────────

  @override
  Future<T> transaction<T>(Future<T> Function(VaultStorage tx) action) async {
    // Supabase does not expose multi-statement transactions over REST.
    // For true transactions, use a server-side function (RPC).
    // In-process: we run the action directly (best-effort).
    return action(this);
  }

  // ── Reactivity ─────────────────────────────────────────────────────────────

  @override
  Stream<void> watchChanges(String collection) {
    _controllers.putIfAbsent(
      collection,
      () => StreamController<void>.broadcast(),
    );
    return _controllers[collection]!.stream;
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> clear(String collection) async {
    // DELETE all rows
    await _request('DELETE', '/rest/v1/$collection?id=neq.null');
    _notify(collection);
  }

  @override
  Future<void> dispose() async {
    for (final c in _controllers.values) {
      await c.close();
    }
    _controllers.clear();
  }

  // ── SqlQueryTranslator ─────────────────────────────────────────────────────

  @override
  SqlFragment toSql(VaultQuery query) {
    final parts = <String>[];
    final params = <Object?>[];
    for (final f in query.filters) {
      params.add(f.value);
      parts.add("data->>'${f.field}' ${f.operator.sql} \$${params.length}");
    }
    return SqlFragment(
      where: parts.isEmpty ? null : parts.join(' AND '),
      orderBy: query.sort?.field,
      orderDirection: (query.sort?.descending ?? false) ? 'DESC' : 'ASC',
      limit: query.limit,
      offset: query.offset,
      params: params,
    );
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  String _buildQueryUrl(
    String collection,
    VaultQuery q, {
    required bool forCount,
  }) {
    final params = <String>[];

    // Filters → PostgREST column filters on JSONB
    for (final f in q.filters) {
      params.add(_filterToPostgrest(f));
    }

    // Ordering
    if (q.sort != null) {
      final dir = q.sort!.descending ? 'desc' : 'asc';
      params.add('order=data->${q.sort!.field}.$dir');
    }

    // Pagination
    if (q.limit != null) params.add('limit=${q.limit}');
    if (q.offset != null) params.add('offset=${q.offset}');

    // Select data column only
    params.add('select=data');

    if (forCount) params.add('prefer=count=exact');

    final qs = params.isEmpty ? '' : '?${params.join('&')}';
    return '/rest/v1/$collection$qs';
  }

  String _filterToPostgrest(VaultFilter f) {
    // PostgREST filters on JSONB: data->>field=op.value
    final col = Uri.encodeQueryComponent("data->>'${f.field}'");
    switch (f.operator.name) {
      case 'equals':
        return '$col=eq.${Uri.encodeQueryComponent(f.value.toString())}';
      case 'notEquals':
        return '$col=neq.${Uri.encodeQueryComponent(f.value.toString())}';
      case 'contains':
        return '$col=ilike.*${Uri.encodeQueryComponent(f.value.toString())}*';
      case 'greaterThan':
        return '$col=gt.${Uri.encodeQueryComponent(f.value.toString())}';
      case 'greaterOrEqual':
        return '$col=gte.${Uri.encodeQueryComponent(f.value.toString())}';
      case 'lessThan':
        return '$col=lt.${Uri.encodeQueryComponent(f.value.toString())}';
      case 'lessOrEqual':
        return '$col=lte.${Uri.encodeQueryComponent(f.value.toString())}';
      default:
        return '';
    }
  }

  List<Map<String, dynamic>> _extractDataList(List<dynamic> rows) {
    return rows.map((r) {
      final d = (r as Map<String, dynamic>)['data'];
      if (d is Map) return Map<String, dynamic>.from(d);
      return jsonDecode(d as String) as Map<String, dynamic>;
    }).toList();
  }

  Future<dynamic> _request(
    String method,
    String path, {
    String? body,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final client = HttpClient();
    try {
      final req = await _openRequest(client, method, uri);
      _addHeaders(req, useServiceKey: false);
      headers?.forEach((k, v) => req.headers.set(k, v));
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(body);
      }
      final res = await req.close().timeout(_timeout);
      final raw = await res.transform(utf8.decoder).join();
      client.close();

      if (res.statusCode >= 400) {
        throw VaultStorageException(
          'Supabase $method $path → ${res.statusCode}: $raw',
        );
      }

      if (raw.isEmpty) return null;
      return jsonDecode(raw);
    } catch (e) {
      client.close();
      if (e is VaultStorageException) rethrow;
      throw VaultStorageException('Request failed: $method $path', cause: e);
    }
  }

  Future<(List<dynamic>, int)> _requestWithCount(String method, String path) async {
    final uri = Uri.parse('$_baseUrl$path');
    final client = HttpClient();
    try {
      final req = await _openRequest(client, method, uri);
      _addHeaders(req, useServiceKey: false);
      req.headers.set('Prefer', 'count=exact');
      final res = await req.close().timeout(_timeout);
      final raw = await res.transform(utf8.decoder).join();
      client.close();

      // Parse Content-Range: 0-24/100
      int total = 0;
      final cr = res.headers.value('content-range');
      if (cr != null) {
        final parts = cr.split('/');
        total = int.tryParse(parts.last) ?? 0;
      }

      final decoded = raw.isEmpty ? <dynamic>[] : jsonDecode(raw) as List<dynamic>;
      return (decoded, total);
    } catch (e) {
      client.close();
      if (e is VaultStorageException) rethrow;
      throw VaultStorageException('Request failed: $method $path', cause: e);
    }
  }

  Future<HttpClientRequest> _openRequest(
    HttpClient client,
    String method,
    Uri uri,
  ) async {
    switch (method) {
      case 'GET':
        return client.getUrl(uri).timeout(_timeout);
      case 'POST':
        return client.postUrl(uri).timeout(_timeout);
      case 'PATCH':
        return client.patchUrl(uri).timeout(_timeout);
      case 'DELETE':
        return client.deleteUrl(uri).timeout(_timeout);
      case 'HEAD':
        return client.headUrl(uri).timeout(_timeout);
      default:
        return client.openUrl(method, uri).timeout(_timeout);
    }
  }

  void _addHeaders(HttpClientRequest req, {required bool useServiceKey}) {
    final key =
        (useServiceKey && _serviceKey != null) ? _serviceKey : _anonKey;
    req.headers
      ..set('apikey', key)
      ..set('Authorization', 'Bearer $key')
      ..set('Content-Type', 'application/json');
  }

  Future<void> _executeSql(String sql) async {
    await _request(
      'POST',
      '/rest/v1/rpc/vault_exec_sql',
      body: jsonEncode({'sql': sql}),
      headers: {'Authorization': 'Bearer $_serviceKey'},
    );
  }

  void _notify(String collection) {
    _controllers[collection]?.add(null);
  }
}
