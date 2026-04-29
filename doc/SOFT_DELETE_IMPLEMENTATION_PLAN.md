# Soft Delete Implementation Plan

## Current State Analysis

### How Delete Works Now

#### 1. DirectStorage (DirectRepositoryImpl)
```dart
Future<void> delete(String id) async {
  await _storage.delete(_collection, id);  // HARD DELETE - physically removes
}
```
- **Always hard delete** - record physically removed from DB
- No logging
- No soft delete option

#### 2. LoggedStorage (LoggedRepositoryImpl)
```dart
Future<void> delete(String entityId, {required String actorId}) async {
  final existing = await _storage.get(_collection, entityId);
  await _storage.delete(_collection, entityId);  // HARD DELETE
  
  // Create log entry
  final entry = LogEntry(
    operation: LogOperation.deleted,
    diff: _computeDiff(existing, null),
    ...
  );
  await _storage.put(_logCollection, entry.entryId, entry.toMap());
}
```
- **Hard delete** from main table
- **Audit log persists** in `{collection}_log` table
- Logs the delete operation with full diff

#### 3. VersionedStorage (VersionedRepositoryImpl)
```dart
Future<void> deleteVersion(String nodeId) async {
  // SOFT DELETE - changes state to 'deleted'
  // Record stays in DB
}

Future<void> deleteEntity(String entityId) async {
  // Deletes ALL versions of entity
  // Used rarely, mostly for cleanup
}
```
- **Soft delete** via state flag
- Record remains in DB with `state = 'deleted'`
- Can be queried/restored

### Server-Side (VaultRegistry)

```dart
// DirectStorage
case 'delete':
  await repo.delete(args['id'] as String);
  return null;

// LoggedStorage  
case 'delete':
  await repo.delete(args['id'] as String, actorId: args['actorId']);
  return null;

// VersionedStorage
case 'deleteVersion':
  await repo.deleteVersion(args['nodeId'] as String);  // Soft
  return null;

case 'delete':
  await repo.deleteEntity(args['id'] as String);  // Hard (all versions)
  return null;
```

## Problem Statement

**Current issues:**
1. DirectStorage has NO soft delete option - always hard deletes
2. LoggedStorage has NO soft delete option - always hard deletes (but logs it)
3. No unified way to control delete behavior across storage modes
4. Models cannot declare their delete preference

**What we want:**
- Add `softDelete` field to `Storable` interface (default: `true`)
- If `softDelete = true`: mark as deleted, log to deleted table, keep in DB
- If `softDelete = false`: hard delete from DB, log to deleted table
- Works for ALL storage modes (Direct, Logged, Versioned)

## Proposed Solution

### Step 1: Add `softDelete` to Storable Interface

```dart
// aq_schema/lib/data_layer/storable/storable.dart
abstract interface class Storable {
  String get id;
  String get collectionName;
  Map<String, dynamic> toMap();
  Map<String, dynamic> get indexFields;
  Map<String, dynamic> get jsonSchema;
  
  /// Controls delete behavior:
  /// - `true` (default): Soft delete - mark as deleted, keep in DB
  /// - `false`: Hard delete - physically remove from DB
  /// 
  /// Both modes log the delete operation to `{collection}_deleted` table.
  bool get softDelete => true;  // Default to soft delete
}
```

### Step 2: Create Deleted Log Table

New table: `{collection}_deleted`

Schema:
```sql
CREATE TABLE {collection}_deleted (
  id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL,
  data JSONB NOT NULL,           -- Full entity snapshot before delete
  deleted_at TIMESTAMP NOT NULL,
  deleted_by TEXT NOT NULL,      -- Actor who deleted it
  delete_type TEXT NOT NULL,     -- 'soft' or 'hard'
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);
```

### Step 3: Add `deletedAt` Field to Models (Soft Delete)

For models with `softDelete = true`, add:

```dart
class AqStudioProject implements DirectStorable {
  final String id;
  final String tenantId;
  final String name;
  final DateTime? deletedAt;  // NULL = active, NOT NULL = soft deleted
  
  @override
  bool get softDelete => true;  // Enable soft delete
  
  @override
  Map<String, dynamic> toMap() => {
    'id': id,
    'tenantId': tenantId,
    'name': name,
    'deletedAt': deletedAt?.toIso8601String(),
  };
}
```

### Step 4: Update DirectRepositoryImpl

```dart
@override
Future<void> delete(String id) async {
  final entity = await findById(id);
  if (entity == null) return;
  
  if (entity.softDelete) {
    // SOFT DELETE: Mark as deleted
    final deletedEntity = _markAsDeleted(entity);
    await save(deletedEntity);
    
    // Log to deleted table
    await _logDeletion(entity, deleteType: 'soft', actorId: 'system');
  } else {
    // HARD DELETE: Remove from DB
    await _logDeletion(entity, deleteType: 'hard', actorId: 'system');
    await _storage.delete(_collection, id);
  }
}

dynamic _markAsDeleted(T entity) {
  final map = entity.toMap();
  map['deletedAt'] = DateTime.now().toIso8601String();
  return _fromMap(map);
}

Future<void> _logDeletion(T entity, {required String deleteType, required String actorId}) async {
  final deletedCollection = '${_collection}_deleted';
  await _storage.ensureCollection(deletedCollection);
  
  final log = {
    'id': entity.id,
    'tenant_id': _getTenantId(entity),
    'data': entity.toMap(),
    'deleted_at': DateTime.now().toIso8601String(),
    'deleted_by': actorId,
    'delete_type': deleteType,
  };
  
  await _storage.put(deletedCollection, entity.id, log);
}
```

### Step 5: Update LoggedRepositoryImpl

```dart
@override
Future<void> delete(String entityId, {required String actorId}) async {
  final entity = await findById(entityId);
  if (entity == null) return;
  
  if (entity.softDelete) {
    // SOFT DELETE: Mark as deleted
    final deletedEntity = _markAsDeleted(entity);
    await save(deletedEntity, actorId: actorId);
    
    // Log to deleted table
    await _logDeletion(entity, deleteType: 'soft', actorId: actorId);
  } else {
    // HARD DELETE: Remove from DB
    await _logDeletion(entity, deleteType: 'hard', actorId: actorId);
    
    // Create audit log entry (existing behavior)
    final existing = await _storage.get(_collection, entityId);
    await _storage.delete(_collection, entityId);
    
    final entry = LogEntry(
      operation: LogOperation.deleted,
      diff: _computeDiff(existing, null),
      changedBy: actorId,
      ...
    );
    await _storage.put(_logCollection, entry.entryId, entry.toMap());
  }
}
```

### Step 6: Update Queries to Exclude Soft-Deleted

```dart
@override
Future<List<T>> findAll({VaultQuery? query}) async {
  await _ensureCollection();
  
  // Add filter to exclude soft-deleted records
  var q = query ?? const VaultQuery();
  q = q.where('deletedAt', VaultOperator.isNull, null);
  
  final rows = await _storage.query(_collection, q);
  return rows.map(_fromMap).toList();
}

// Add method to query including deleted
Future<List<T>> findAllIncludingDeleted({VaultQuery? query}) async {
  await _ensureCollection();
  final rows = await _storage.query(_collection, query ?? const VaultQuery());
  return rows.map(_fromMap).toList();
}
```

### Step 7: Add Restore Method

```dart
@override
Future<void> restore(String id) async {
  final entity = await findById(id);
  if (entity == null) return;
  
  final map = entity.toMap();
  map['deletedAt'] = null;
  final restored = _fromMap(map);
  
  await save(restored);
}
```

## Migration Path

### Phase 1: Add Interface Field
1. Add `softDelete` getter to `Storable` interface with default `true`
2. All existing models inherit default behavior (soft delete)
3. No breaking changes

### Phase 2: Update Storage Implementations
1. Update `DirectRepositoryImpl` to check `softDelete` flag
2. Update `LoggedRepositoryImpl` to check `softDelete` flag
3. Create `{collection}_deleted` tables via SchemaDeployer
4. Update queries to exclude `deletedAt != null`

### Phase 3: Update Models
1. Add `deletedAt` field to models that want soft delete
2. Set `softDelete = false` for models that need hard delete
3. Update `toMap()` and `fromMap()` to handle `deletedAt`

### Phase 4: Update Server
1. Update `VaultRegistry` to pass `actorId` to delete operations
2. Add RPC operations: `restore`, `findDeleted`, `permanentDelete`

## Benefits

✅ **Unified delete behavior** across all storage modes
✅ **Model-level control** - each model declares its delete preference
✅ **Audit trail** - all deletes logged to `{collection}_deleted` table
✅ **Restore capability** - soft-deleted records can be restored
✅ **Backward compatible** - default `softDelete = true` preserves data
✅ **Compliance-friendly** - never lose data unless explicitly hard deleted

## Example Usage

### Model with Soft Delete (Default)
```dart
class AqStudioProject implements DirectStorable {
  final DateTime? deletedAt;
  
  @override
  bool get softDelete => true;  // Soft delete enabled
}

// Delete
await projects.delete('proj-001');
// Record stays in DB with deletedAt = now

// Restore
await projects.restore('proj-001');
// Record active again with deletedAt = null
```

### Model with Hard Delete
```dart
class TempCache implements DirectStorable {
  @override
  bool get softDelete => false;  // Hard delete
}

// Delete
await cache.delete('cache-001');
// Record physically removed from DB
// But logged to temp_cache_deleted table
```

## Database State After Implementation

```sql
-- Main table (projects)
SELECT id, name, deleted_at FROM projects;
-- id          | name              | deleted_at
-- proj-001    | Active Project    | NULL
-- proj-002    | Deleted Project   | 2026-04-20 09:00:00  ← Soft deleted
-- proj-003    | Active Project    | NULL

-- Deleted log table (projects_deleted)
SELECT id, delete_type, deleted_by FROM projects_deleted;
-- id          | delete_type | deleted_by
-- proj-002    | soft        | user-001
-- proj-004    | hard        | system      ← Hard deleted (not in main table)
```

---

**Status:** Design phase - ready for implementation
**Author:** AQ Architecture Team
**Date:** 2026-04-20
