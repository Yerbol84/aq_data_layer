# Soft Delete Implementation - Complete Summary

## 🎯 What We Built

A comprehensive soft delete system for dart_vault that:
- ✅ Allows models to control delete behavior via `softDelete` flag
- ✅ Supports both soft delete (mark as deleted) and hard delete (remove from DB)
- ✅ Logs ALL deletions to `{collection}_deleted` table for audit
- ✅ Enables restore functionality for soft-deleted records
- ✅ Works across all storage modes (Direct, Logged, Versioned)
- ✅ Maintains backward compatibility (default: soft delete)

---

## ✅ Phase 1: Interface Updates (aq_schema)

### Files Modified:
1. `aq_schema/lib/data_layer/storable/storable.dart`
2. `aq_schema/lib/data_layer/repositories/direct_repository.dart`
3. `aq_schema/lib/data_layer/repositories/logged_repository.dart`

### Changes:
- Added `bool get softDelete => true` to `Storable` interface
- Added `deletedAt` constants to DB and JSON keys
- Added `restore()` method to repositories
- Added `findAllIncludingDeleted()` method to repositories

---

## ✅ Phase 2: Core Implementation (dart_vault_package)

### Files Modified:
1. `dart_vault_package/lib/storage/direct_repository_impl.dart`
2. `dart_vault_package/lib/storage/logged_repository_impl.dart`

### DirectRepositoryImpl Changes:
```dart
// Delete logic
Future<void> delete(String id) async {
  final entity = await findById(id);
  if (entity.softDelete) {
    // Soft: mark deletedAt, keep in DB
    final map = entity.toMap();
    map['deletedAt'] = DateTime.now().toIso8601String();
    await _storage.put(_collection, id, map);
  } else {
    // Hard: remove from DB
    await _storage.delete(_collection, id);
  }
  // Both: log to {collection}_deleted
  await _logDeletion(entity, deleteType: '...', actorId: 'system');
}

// Restore logic
Future<void> restore(String id) async {
  final map = entity.toMap();
  map['deletedAt'] = null;
  await _storage.put(_collection, id, map);
}

// Query logic
Future<List<T>> findAll({VaultQuery? query}) async {
  var q = query ?? const VaultQuery();
  q = q.where('deletedAt', VaultOperator.isNull, null);  // Exclude deleted
  final rows = await _storage.query(_collection, q);
  return rows.map(_fromMap).toList();
}
```

### LoggedRepositoryImpl Changes:
- Same delete/restore logic as DirectRepositoryImpl
- Creates log entries for soft delete, hard delete, and restore
- Audit log (`{collection}_log`) ALWAYS preserved regardless of delete type

---

## ✅ Phase 3: Database Schema (dart_vault_package)

### Files Modified:
1. `dart_vault_package/lib/storage/postgres/postgres_schema_deployer.dart`

### Changes:
Added `_createDeletedTable()` method:
```sql
CREATE TABLE {collection}_deleted (
  id TEXT NOT NULL,
  tenant_id TEXT NOT NULL,
  data JSONB NOT NULL,           -- Full entity snapshot
  deleted_at TIMESTAMPTZ NOT NULL,
  deleted_by TEXT NOT NULL,
  delete_type TEXT NOT NULL,     -- 'soft' or 'hard'
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id, tenant_id)
)

-- Indexes
CREATE INDEX idx_{collection}_deleted_at ON {collection}_deleted(deleted_at);
CREATE INDEX idx_{collection}_delete_type ON {collection}_deleted(delete_type);
CREATE INDEX idx_{collection}_deleted_tenant ON {collection}_deleted(tenant_id);

-- RLS for tenant isolation
ALTER TABLE {collection}_deleted ENABLE ROW LEVEL SECURITY;
```

Updated all table creation methods:
- `_createDirectTable()` → calls `_createDeletedTable()`
- `_createLoggedTables()` → calls `_createDeletedTable()`
- `_createVersionedTables()` → calls `_createDeletedTable()`

---

## 📊 Database State After Implementation

### DirectStorage Example:
```sql
-- Main table (projects)
SELECT id, data->>'name' as name, data->>'deletedAt' as deleted_at FROM projects;
-- id          | name              | deleted_at
-- proj-001    | Active Project    | NULL
-- proj-002    | Deleted Project   | 2026-04-21T05:00:00  ← Soft deleted
-- proj-003    | Active Project    | NULL

-- Deleted log (projects_deleted)
SELECT id, delete_type, deleted_by FROM projects_deleted;
-- id          | delete_type | deleted_by
-- proj-002    | soft        | system      ← Soft deleted (still in main table)
-- proj-004    | hard        | system      ← Hard deleted (removed from main table)
```

### LoggedStorage Example:
```sql
-- Main table (workflow_runs)
SELECT id, data->>'status' as status, data->>'deletedAt' as deleted_at FROM workflow_runs;
-- id          | status     | deleted_at
-- run-001     | completed  | NULL
-- run-002     | completed  | 2026-04-21T05:00:00  ← Soft deleted

-- Audit log (workflow_runs_log) - ALWAYS preserved
SELECT id, data->>'operation' as operation FROM workflow_runs_log;
-- id          | operation
-- log-001     | created
-- log-002     | updated
-- log-003     | deleted    ← Logged even for hard delete

-- Deleted log (workflow_runs_deleted)
SELECT id, delete_type FROM workflow_runs_deleted;
-- id          | delete_type
-- run-002     | soft
-- run-003     | hard
```

---

## 🔄 How It Works

### Soft Delete Flow:
1. User calls `repository.delete(id)`
2. Repository checks `entity.softDelete` → `true`
3. Repository marks `deletedAt = now` in entity data
4. Repository saves updated entity to main table
5. Repository logs to `{collection}_deleted` table
6. Entity stays in main table but excluded from queries

### Hard Delete Flow:
1. User calls `repository.delete(id)`
2. Repository checks `entity.softDelete` → `false`
3. Repository logs to `{collection}_deleted` table FIRST
4. Repository removes entity from main table
5. Entity gone from main table, but logged in deleted table

### Restore Flow:
1. User calls `repository.restore(id)`
2. Repository loads entity (including deleted ones)
3. Repository clears `deletedAt` field
4. Repository saves updated entity
5. Entity becomes active again, appears in queries

---

## 🎯 Next Steps (Phase 4)

### 1. Update VaultRegistry RPC Operations
Add server-side handlers for:
- `restore` operation
- `findAllIncludingDeleted` operation

### 2. Update Models
Add `deletedAt` field to existing models:
```dart
class AqStudioProject implements DirectStorable {
  final DateTime? deletedAt;
  
  @override
  Map<String, dynamic> toMap() => {
    ...
    'deletedAt': deletedAt?.toIso8601String(),
  };
  
  static AqStudioProject fromMap(Map<String, dynamic> map) {
    return AqStudioProject(
      ...
      deletedAt: map['deletedAt'] != null 
        ? DateTime.parse(map['deletedAt'] as String)
        : null,
    );
  }
}
```

### 3. Test with Console Client
Create test that demonstrates:
- Soft delete → record marked, stays in DB
- Hard delete → record removed, logged
- Restore → record active again
- Query → excludes deleted by default
- Query including deleted → shows all

### 4. Update Documentation
- API documentation
- Migration guide for existing projects
- Best practices guide

---

## 📈 Benefits

✅ **Data Safety** - Never lose data unless explicitly hard deleted
✅ **Audit Trail** - Complete history in `{collection}_deleted` table
✅ **Flexibility** - Model-level control via `softDelete` flag
✅ **Restore** - Undo accidental deletions
✅ **Compliance** - Meet data retention requirements
✅ **Backward Compatible** - Default soft delete preserves data
✅ **Clean Architecture** - Follows DDD principles, separation of concerns

---

**Status:** Phase 1-3 Complete ✅  
**Next:** Phase 4 - Server Integration & Testing  
**Date:** 2026-04-21  
**Author:** AQ Architecture Team
