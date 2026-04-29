/// Shared test fixtures for dart_vault tests.
library test_helpers;

import 'package:aq_schema/aq_schema.dart';
import 'package:dart_vault/dart_vault.dart';

// ── DirectStorable ──────────────────────────────────────────────────────────

class Item implements DirectStorable {
  @override
  final String id;
  final String name;
  final int score;

  const Item({required this.id, required this.name, required this.score});

  @override
  Map<String, dynamic> toMap() => {'id': id, 'name': name, 'score': score};

  @override
  Map<String, dynamic> get indexFields => {'name': name};

  @override
  String get collectionName => 'items';

  @override
  Map<String, dynamic> get jsonSchema => {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'name': {'type': 'string'},
          'score': {'type': 'integer'},
        },
        'required': ['id', 'name'],
      };

  factory Item.fromMap(Map<String, dynamic> m) => Item(
        id: m['id'] as String,
        name: m['name'] as String,
        score: m['score'] as int? ?? 0,
      );

  @override
  bool operator ==(Object o) => o is Item && o.id == id && o.name == name;
  @override
  int get hashCode => Object.hash(id, name);
  @override
  String toString() => 'Item($id:$name:$score)';
}

// ── VersionedStorable ───────────────────────────────────────────────────────

class Doc implements VersionedStorable {
  @override
  final String id;
  @override
  final String tenantId;
  @override
  final String ownerId;
  final String title;
  final String body;

  const Doc({
    required this.id,
    required this.tenantId,
    required this.ownerId,
    required this.title,
    this.body = '',
  });

  @override
  Map<String, dynamic> toMap() => {
        'id': id,
        'tenantId': tenantId,
        'ownerId': ownerId,
        'title': title,
        'body': body,
      };

  @override
  Map<String, dynamic> get indexFields => {'title': title};

  @override
  String get collectionName => 'docs';

  @override
  String get schemaVersion => '1.0.0';

  @override
  List<Object> get migrations => const [];

  @override
  Map<String, dynamic> get jsonSchema => {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'tenantId': {'type': 'string'},
          'ownerId': {'type': 'string'},
          'title': {'type': 'string'},
          'body': {'type': 'string'},
        },
        'required': ['id', 'tenantId', 'ownerId', 'title'],
      };

  @override
  String get defaultSharingPolicy => 'tenant';

  factory Doc.fromMap(Map<String, dynamic> m) => Doc(
        id: m['id'] as String,
        tenantId: m['tenantId'] as String? ?? 'system',
        ownerId: m['ownerId'] as String? ?? '',
        title: m['title'] as String? ?? '',
        body: m['body'] as String? ?? '',
      );

  Doc withTitle(String t) => Doc(
        id: id,
        tenantId: tenantId,
        ownerId: ownerId,
        title: t,
        body: body,
      );
}

// ── LoggedStorable ──────────────────────────────────────────────────────────

class Task implements LoggedStorable {
  @override
  final String id;
  final String title;
  final String status; // open | inProgress | done
  final String assigneeId;

  const Task({
    required this.id,
    required this.title,
    required this.status,
    required this.assigneeId,
  });

  @override
  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'status': status,
        'assigneeId': assigneeId,
      };

  @override
  Map<String, dynamic> get indexFields => {'status': status};

  @override
  Set<String> get trackedFields => {'status', 'assigneeId'};

  @override
  String get collectionName => 'tasks';

  @override
  Map<String, dynamic> get jsonSchema => {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'title': {'type': 'string'},
          'status': {'type': 'string'},
          'assigneeId': {'type': 'string'},
        },
        'required': ['id', 'title', 'status'],
      };

  factory Task.fromMap(Map<String, dynamic> m) => Task(
        id: m['id'] as String,
        title: m['title'] as String? ?? '',
        status: m['status'] as String? ?? 'open',
        assigneeId: m['assigneeId'] as String? ?? '',
      );

  Task withStatus(String s) =>
      Task(id: id, title: title, status: s, assigneeId: assigneeId);
  Task withAssignee(String a) =>
      Task(id: id, title: title, status: status, assigneeId: a);
}

// ── ArtifactEntry ───────────────────────────────────────────────────────────

class FileEntry implements ArtifactEntry {
  @override
  final String id;
  @override
  final String storageKey;
  @override
  final String fileName;
  @override
  final String contentType;
  @override
  final int sizeBytes;
  @override
  final String checksum;
  @override
  final Map<String, String> meta;
  @override
  final DateTime createdAt;

  const FileEntry({
    required this.id,
    required this.storageKey,
    required this.fileName,
    required this.contentType,
    required this.sizeBytes,
    required this.checksum,
    this.meta = const {},
    required this.createdAt,
  });

  @override
  Map<String, dynamic> toMap() => {
        'id': id,
        'storageKey': storageKey,
        'fileName': fileName,
        'contentType': contentType,
        'sizeBytes': sizeBytes,
        'checksum': checksum,
        'meta': meta,
        'createdAt': createdAt.toIso8601String(),
      };

  @override
  Map<String, dynamic> get indexFields => {'fileName': fileName};

  @override
  String get collectionName => 'file_entries';

  @override
  Map<String, dynamic> get jsonSchema => {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'storageKey': {'type': 'string'},
          'fileName': {'type': 'string'},
          'contentType': {'type': 'string'},
          'sizeBytes': {'type': 'integer'},
          'checksum': {'type': 'string'},
          'meta': {'type': 'object'},
          'createdAt': {'type': 'string', 'format': 'date-time'},
        },
        'required': ['id', 'fileName'],
      };

  factory FileEntry.fromMap(Map<String, dynamic> m) => FileEntry(
        id: m['id'] as String,
        storageKey: m['storageKey'] as String? ?? '',
        fileName: m['fileName'] as String? ?? '',
        contentType: m['contentType'] as String? ?? 'application/octet-stream',
        sizeBytes: m['sizeBytes'] as int? ?? 0,
        checksum: m['checksum'] as String? ?? '',
        meta: ((m['meta'] as Map?) ?? {}).map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ),
        createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ??
            DateTime.now(),
      );
}
