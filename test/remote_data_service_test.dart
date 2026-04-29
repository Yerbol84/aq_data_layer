import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// Интеграционные тесты для Remote Data Service через HTTP RPC.
///
/// Требования:
/// - Data Service должен быть запущен на http://localhost:8765
/// - PostgreSQL должен быть доступен
///
/// Запуск:
/// ```bash
/// docker-compose up -d
/// dart test test/remote_data_service_test.dart
/// ```
void main() {
  const baseUrl = 'http://localhost:8765';
  const tenantId = 'test_tenant';

  late http.Client client;

  setUp(() {
    client = http.Client();
  });

  tearDown(() {
    client.close();
  });

  /// Выполнить RPC запрос к Data Service
  Future<http.Response> rpc({
    required String collection,
    required String operation,
    required Map<String, dynamic> args,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/vault/rpc'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'collection': collection,
        'operation': operation,
        'tenantId': tenantId,
        'args': args,
      }),
    );
    return response;
  }

  /// Извлечь результат из ответа сервера (unwrap {'data': ...})
  dynamic getResult(http.Response response) {
    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body);
    return body['data'];
  }

  group('Direct Storage (projects)', () {
    final testId = 'test_project_${DateTime.now().millisecondsSinceEpoch}';

    test('CREATE - создание проекта', () async {
      final response = await rpc(
        collection: 'projects',
        operation: 'put',
        args: {
          'data': {
            'id': testId,
            'tenantId': tenantId,
            'name': 'Test Project',
            'ownerId': 'user_1',
            'projectType': 'workflow',
            'lastOpened': DateTime.now().toIso8601String(),
          }
        },
      );

      expect(response.statusCode, 200);
    });

    test('READ - чтение проекта', () async {
      final response = await rpc(
        collection: 'projects',
        operation: 'get',
        args: {'id': testId},
      );

      expect(response.statusCode, 200);
      final data = getResult(response);
      expect(data['id'], testId);
      expect(data['name'], 'Test Project');
    });

    test('UPDATE - обновление проекта', () async {
      final response = await rpc(
        collection: 'projects',
        operation: 'put',
        args: {
          'data': {
            'id': testId,
            'tenantId': tenantId,
            'name': 'Updated Project',
            'ownerId': 'user_1',
            'projectType': 'workflow',
            'lastOpened': DateTime.now().toIso8601String(),
          }
        },
      );

      expect(response.statusCode, 200);

      // Проверяем что обновилось
      final getResponse = await rpc(
        collection: 'projects',
        operation: 'get',
        args: {'id': testId},
      );
      final data = getResult(getResponse);
      expect(data['name'], 'Updated Project');
    });

    test('QUERY - поиск проектов', () async {
      final response = await rpc(
        collection: 'projects',
        operation: 'query',
        args: {
          'query': {
            'filters': [
              {
                'field': 'projectType',
                'operator': 'equals',
                'value': 'workflow'
              }
            ]
          }
        },
      );

      expect(response.statusCode, 200);
      final data = getResult(response) as List;
      expect(data.isNotEmpty, true);
    });

    test('DELETE - удаление проекта', () async {
      final response = await rpc(
        collection: 'projects',
        operation: 'delete',
        args: {'id': testId},
      );

      expect(response.statusCode, 200);

      // Проверяем что удалился
      final getResponse = await rpc(
        collection: 'projects',
        operation: 'get',
        args: {'id': testId},
      );
      expect(getResult(getResponse), isNull);
    });
  });

  group('Versioned Storage (workflow_graphs)', () {
    final testId = 'test_workflow_${DateTime.now().millisecondsSinceEpoch}';
    String? nodeId;

    test('CREATE - создание workflow с версионированием', () async {
      final response = await rpc(
        collection: 'workflow_graphs',
        operation: 'put',
        args: {
          'data': {
            'id': testId,
            'name': 'Test Workflow',
            'description': 'Test workflow description',
            'nodes': [],
            'edges': [],
          }
        },
      );

      expect(response.statusCode, 200);
      final node = getResult(response);
      nodeId = node['nodeId'] as String?;
      expect(nodeId, isNotNull);
      expect(node['status'], 'draft');
    });

    test('READ - чтение draft версии через listVersions', () async {
      final response = await rpc(
        collection: 'workflow_graphs',
        operation: 'listVersions',
        args: {'entityId': testId},
      );

      expect(response.statusCode, 200);
      final versions = getResult(response) as List;
      expect(versions.length, 1);
      final draft = versions[0] as Map<String, dynamic>;
      expect(draft['entityId'], testId);
      expect(draft['status'], 'draft');
      expect(draft['nodeId'], nodeId);
    });

    test('UPDATE - обновление draft версии', () async {
      final response = await rpc(
        collection: 'workflow_graphs',
        operation: 'updateDraft',
        args: {
          'nodeId': nodeId,
          'data': {
            'id': testId,
            'name': 'Updated Workflow',
            'description': 'Updated description',
            'nodes': [],
            'edges': [],
          }
        },
      );

      expect(response.statusCode, 200);
    });

    test('HISTORY - список версий', () async {
      final response = await rpc(
        collection: 'workflow_graphs',
        operation: 'listVersions',
        args: {'entityId': testId},
      );

      expect(response.statusCode, 200);
      final versions = getResult(response) as List;
      expect(versions.length, 1);
      expect(versions[0]['status'], 'draft');
    });

    test('PUBLISH - публикация draft в published', () async {
      final response = await rpc(
        collection: 'workflow_graphs',
        operation: 'publishDraft',
        args: {
          'nodeId': nodeId,
          'increment': 'minor',
        },
      );

      expect(response.statusCode, 200);
      final node = getResult(response);
      expect(node['status'], 'published');
      expect(node['version'], isNotNull);
    });

    test('CREATE_BRANCH - создание ветки', () async {
      final response = await rpc(
        collection: 'workflow_graphs',
        operation: 'createBranch',
        args: {
          'parentNodeId': nodeId,
          'branchName': 'feature-1',
          'data': {
            'id': testId,
            'name': 'Feature Branch',
            'description': 'Feature branch description',
            'nodes': [],
            'edges': [],
          }
        },
      );

      expect(response.statusCode, 200);
      final node = getResult(response);
      expect(node['branch'], 'feature-1');
      expect(node['status'], 'draft');
    });

    test('DELETE - удаление всей сущности', () async {
      final response = await rpc(
        collection: 'workflow_graphs',
        operation: 'delete',
        args: {'id': testId},
      );

      expect(response.statusCode, 200);

      // Проверяем что удалилось
      final getResponse = await rpc(
        collection: 'workflow_graphs',
        operation: 'get',
        args: {'id': testId},
      );
      expect(getResult(getResponse), isNull);
    });
  });

  group('Multi-tenancy', () {
    final testId = 'multi_tenant_test_${DateTime.now().millisecondsSinceEpoch}';

    test('Изоляция данных между tenant', () async {
      // Создаем проект для tenant_1
      await rpc(
        collection: 'projects',
        operation: 'put',
        args: {
          'data': {
            'id': testId,
            'tenantId': 'tenant_1',
            'name': 'Tenant 1 Project',
            'ownerId': 'user_1',
            'projectType': 'workflow',
            'lastOpened': DateTime.now().toIso8601String(),
          }
        },
      );

      // Создаем проект с тем же ID для tenant_2
      final response2 = await client.post(
        Uri.parse('$baseUrl/vault/rpc'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'collection': 'projects',
          'operation': 'put',
          'tenantId': 'tenant_2',
          'args': {
            'data': {
              'id': testId,
              'tenantId': 'tenant_2',
              'name': 'Tenant 2 Project',
              'ownerId': 'user_2',
              'projectType': 'instruction',
              'lastOpened': DateTime.now().toIso8601String(),
            }
          },
        }),
      );

      expect(response2.statusCode, 200);

      // Читаем для tenant_1
      final get1 = await rpc(
        collection: 'projects',
        operation: 'get',
        args: {'id': testId},
      );
      final data1 = getResult(get1);
      expect(data1['name'], 'Tenant 1 Project');
      expect(data1['ownerId'], 'user_1');

      // Читаем для tenant_2
      final get2 = await client.post(
        Uri.parse('$baseUrl/vault/rpc'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'collection': 'projects',
          'operation': 'get',
          'tenantId': 'tenant_2',
          'args': {'id': testId},
        }),
      );
      final data2 = getResult(get2);
      expect(data2['name'], 'Tenant 2 Project');
      expect(data2['ownerId'], 'user_2');

      // Cleanup
      await rpc(
          collection: 'projects', operation: 'delete', args: {'id': testId});
      await client.post(
        Uri.parse('$baseUrl/vault/rpc'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'collection': 'projects',
          'operation': 'delete',
          'tenantId': 'tenant_2',
          'args': {'id': testId},
        }),
      );
    });
  });
}
