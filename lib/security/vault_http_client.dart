import 'dart:convert';
import 'dart:io';

/// HTTP client for HashiCorp Vault API
class VaultHttpClient {
  final String baseUrl;
  final String token;
  final Duration timeout;

  VaultHttpClient({
    required this.baseUrl,
    required this.token,
    this.timeout = const Duration(seconds: 30),
  });

  /// GET request to Vault API
  Future<Map<String, dynamic>> get(String path) async {
    final uri = Uri.parse('$baseUrl$path');
    final client = HttpClient();

    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set('X-Vault-Token', token);
      request.headers.set('Content-Type', 'application/json');

      final response = await request.close().timeout(timeout);
      final body = await _readResponse(response);

      if (response.statusCode != 200) {
        throw VaultHttpException(
          statusCode: response.statusCode,
          message: 'GET request failed',
          path: path,
          body: body,
        );
      }

      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  /// POST request to Vault API
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> data,
  ) async {
    final uri = Uri.parse('$baseUrl$path');
    final client = HttpClient();

    try {
      final request = await client.postUrl(uri).timeout(timeout);
      request.headers.set('X-Vault-Token', token);
      request.headers.set('Content-Type', 'application/json');

      final jsonData = jsonEncode(data);
      request.write(jsonData);

      final response = await request.close().timeout(timeout);
      final body = await _readResponse(response);

      if (response.statusCode != 200 && response.statusCode != 204) {
        throw VaultHttpException(
          statusCode: response.statusCode,
          message: 'POST request failed',
          path: path,
          body: body,
        );
      }

      if (body.isEmpty) return {};
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  /// DELETE request to Vault API
  Future<void> delete(String path) async {
    final uri = Uri.parse('$baseUrl$path');
    final client = HttpClient();

    try {
      final request = await client.deleteUrl(uri).timeout(timeout);
      request.headers.set('X-Vault-Token', token);
      request.headers.set('Content-Type', 'application/json');

      final response = await request.close().timeout(timeout);
      final body = await _readResponse(response);

      if (response.statusCode != 204 && response.statusCode != 200) {
        throw VaultHttpException(
          statusCode: response.statusCode,
          message: 'DELETE request failed',
          path: path,
          body: body,
        );
      }
    } finally {
      client.close();
    }
  }

  /// Read response body
  Future<String> _readResponse(HttpClientResponse response) async {
    final contents = StringBuffer();
    await for (var data in response.transform(utf8.decoder)) {
      contents.write(data);
    }
    return contents.toString();
  }
}

/// Exception thrown when Vault HTTP request fails
class VaultHttpException implements Exception {
  final int statusCode;
  final String message;
  final String path;
  final String? body;

  const VaultHttpException({
    required this.statusCode,
    required this.message,
    required this.path,
    this.body,
  });

  @override
  String toString() => 'VaultHttpException: $message '
      '(status: $statusCode, path: $path, body: $body)';
}
