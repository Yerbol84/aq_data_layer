# Soft Delete Implementation Progress

## ✅ Completed - Phase 1: Interface Updates (aq_schema)

### 1. Updated `Storable` Interface
**File:** `aq_schema/lib/data_layer/storable/storable.dart`

Added:
```dart
bool get softDelete => true;  // Default soft delete for all entities
```

Added constants:
```dart
final String deletedAt = 'deleted_at';  // DB key
final String deletedAt = 'deletedAt';   // JSON key
```

### 2. Updated `DirectRepository` Interface
**File:** `aq_schema/lib/data_layer/repositories/direct_repository.dart`

Added methods:
```dart
Future<void> restore(String id);
Future<List<T>> findAllIncludingDeleted({VaultQuery? query});
```

### 3. Updated `LoggedRepository` Interface
**File:** `aq_schema/lib/data_layer/repositories/logged_repository.dart`

Added methods:
```dart
Future<void> restore(String entityId, {required String actorId});
Future<List<T>> findAllIncludingDeleted({VaultQuery? query});
```

---

## ✅ Completed - Phase 2: Core Implementation (dart_vault_package)

### 1. Updated DirectRepositoryImpl ✅
**File:** `dart_vault_package/lib/storage/direct_repository_impl.dart`

Implemented:
- ✅ `delete()` - Checks `entity.softDelete` flag
  - If `true`: Marks `deletedAt`, keeps in DB
  - If `false`: Hard deletes from DB
  - Both cases log to `{collection}_deleted` table
- ✅ `restore()` - Clears `deletedAt` field
- ✅ `findAll()` - Excludes `deletedAt != null` by default
- ✅ `findAllIncludingDeleted()` - Returns all records including deleted
- ✅ `_logDeletion()` - Logs to deleted table
- ✅ `_getTenantId()` - Extracts tenant ID from entity

### 2. Updated LoggedRepositoryImpl ✅
**File:** `dart_vault_package/lib/storage/logged_repository_impl.dart`

Implemented:
- ✅ `delete()` - Checks `entity.softDelete` flag
  - If `true`: Marks `deletedAt`, keeps in DB, creates log entry
  - If `false`: Hard deletes from DB, creates log entry
  - Audit log ALWAYS preserved
  - Logs to `{collection}_deleted` table
- ✅ `restore()` - Clears `deletedAt`, creates log entry
- ✅ `findAll()` - Excludes `deletedAt != null` by default
- ✅ `findAllIncludingDeleted()` - Returns all records including deleted
- ✅ `_logDeletion()` - Logs to deleted table
- ✅ `_getTenantId()` - Extracts tenant ID from entity

**Status:** ✅ No compilation errors, only warnings

---

## ✅ Completed - Phase 3: Database Schema (dart_vault_package)

### Updated PostgresSchemaDeployer ✅
**File:** `dart_vault_package/lib/storage/postgres/postgres_schema_deployer.dart`

Implemented:
- ✅ `_createDeletedTable()` - Creates `{collection}_deleted` table
  - Stores full entity snapshot
  - Tracks `deleted_at`, `deleted_by`, `delete_type` (soft/hard)
  - Indexes on `deleted_at`, `delete_type`, `tenant_id`
  - RLS enabled for tenant isolation
  
- ✅ Updated `_createDirectTable()` - Calls `_createDeletedTable()`
- ✅ Updated `_createLoggedTables()` - Calls `_createDeletedTable()`
- ✅ Updated `_createVersionedTables()` - Calls `_createDeletedTable()`

**Table Schema:**
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
```

**Status:** ✅ No compilation errors, only warnings

---

## 🔄 Next Steps - Phase 4: Server Integration & Testing

### Step 1: Update DirectRepositoryImpl
**File:** `dart_vault_package/lib/storage/direct_repository_impl.dart`

Need to implement:
1. Check `entity.softDelete` flag in `delete()` method
2. If `true`: Mark `deletedAt`, keep in DB
3. If `false`: Hard delete from DB
4. Log to `{collection}_deleted` table in both cases
5. Update `findAll()` to exclude `deletedAt != null` by default
6. Implement `findAllIncludingDeleted()`
7. Implement `restore()` method

### Step 2: Update LoggedRepositoryImpl
**File:** `dart_vault_package/lib/storage/logged_repository_impl.dart`

Need to implement:
1. Check `entity.softDelete` flag in `delete()` method
2. If `true`: Mark `deletedAt`, keep in DB, create log entry
3. If `false`: Hard delete from DB, create log entry
4. Audit log ALWAYS preserved regardless of flag
5. Update `findAll()` to exclude `deletedAt != null` by default
6. Implement `findAllIncludingDeleted()`
7. Implement `restore()` method with log entry

### Step 3: Update VersionedRepositoryImpl
**File:** `dart_vault_package/lib/storage/versioned_repository_impl.dart`

Need to implement:
1. Check `entity.softDelete` flag in `deleteEntity()` method
2. If `true`: Mark ALL versions with `deletedAt`
3. If `false`: Hard delete ALL versions from DB
4. `deleteVersion()` remains unchanged (always soft via state flag)

### Step 4: Update PostgresSchemaDeployer
**File:** `dart_vault_package/lib/storage/postgres/postgres_schema_deployer.dart`

Need to add:
1. Create `{collection}_deleted` table for each collection
2. Schema:
```sql
CREATE TABLE {collection}_deleted (
  id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL,
  data JSONB NOT NULL,
  deleted_at TIMESTAMP NOT NULL,
  deleted_by TEXT NOT NULL,
  delete_type TEXT NOT NULL,  -- 'soft' or 'hard'
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);
```

### Step 5: Update VaultRegistry
**File:** `dart_vault_package/lib/deploy/vault_registry.dart`

Need to add RPC operations:
```dart
case 'restore':
  await repo.restore(args['id'] as String);
  return null;

case 'findAllIncludingDeleted':
  final q = _deserializeQuery(args['query']);
  final items = await repo.findAllIncludingDeleted(query: q);
  return items.map((e) => e.toMap()).toList();
```

### Step 6: Update Models
**Files:** Various model files in `aq_schema/lib/data_layer/storable/`

For each model that wants soft delete:
1. Add `final DateTime? deletedAt;` field
2. Update `toMap()` to include `deletedAt`
3. Update `fromMap()` to parse `deletedAt`
4. Override `softDelete` getter if needed (default is `true`)

Example:
```dart
class AqStudioProject implements DirectStorable {
  final String id;
  final String tenantId;
  final String name;
  final DateTime? deletedAt;  // NEW
  
  @override
  bool get softDelete => true;  // Can override to false if needed
  
  @override
  Map<String, dynamic> toMap() => {
    'id': id,
    'tenantId': tenantId,
    'name': name,
    'deletedAt': deletedAt?.toIso8601String(),  // NEW
  };
  
  static AqStudioProject fromMap(Map<String, dynamic> map) {
    return AqStudioProject(
      id: map['id'] as String,
      tenantId: map['tenantId'] as String,
      name: map['name'] as String,
      deletedAt: map['deletedAt'] != null 
        ? DateTime.parse(map['deletedAt'] as String)
        : null,  // NEW
    );
  }
}
```

---

## 📋 Implementation Order

1. ✅ **Phase 1: Interfaces** (DONE)
   - Updated Storable interface
   - Updated DirectRepository interface
   - Updated LoggedRepository interface

2. **Phase 2: Core Implementation** (NEXT)
   - DirectRepositoryImpl
   - LoggedRepositoryImpl
   - VersionedRepositoryImpl

3. **Phase 3: Database Schema**
   - PostgresSchemaDeployer
   - Create `{collection}_deleted` tables

4. **Phase 4: Server Integration**
   - VaultRegistry RPC operations
   - Server-side delete handling

5. **Phase 5: Model Updates**
   - Add `deletedAt` to existing models
   - Test with console client

6. **Phase 6: Testing**
   - Update console_client to test soft delete
   - Verify database state
   - Test restore functionality

---

## 🎯 Current Status

**Completed:** Interface definitions in aq_schema
**Next:** Implement delete logic in DirectRepositoryImpl

Ready to continue with Phase 2?

---

**Date:** 2026-04-20
**Author:** AQ Architecture Team
