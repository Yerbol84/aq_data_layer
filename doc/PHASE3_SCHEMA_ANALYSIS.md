# Phase 3 Architecture Analysis - Schema Deployer Changes

## Current Architecture Understanding

### Table Creation Pattern (PostgresSchemaDeployer)

**Direct Mode:**
```sql
CREATE TABLE {collection} (
  id TEXT NOT NULL,
  tenant_id TEXT NOT NULL,
  data JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id, tenant_id)
)
```

**Logged Mode:**
```sql
-- Main table (same as Direct)
CREATE TABLE {collection} (...)

-- Log table (audit trail)
CREATE TABLE {collection}_log (
  id TEXT NOT NULL,
  tenant_id TEXT NOT NULL,
  data JSONB NOT NULL,  -- Contains LogEntry as JSONB
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id, tenant_id)
)
```

**Versioned Mode:**
```sql
CREATE TABLE {collection}_versions (
  node_id TEXT PRIMARY KEY,
  entity_id TEXT NOT NULL,
  parent_node_id TEXT,
  tenant_id TEXT NOT NULL,
  version TEXT,
  status TEXT NOT NULL,
  branch TEXT NOT NULL DEFAULT 'main',
  ...
  data JSONB NOT NULL
)

CREATE TABLE {collection}_current (
  entity_id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL,
  current_node_id TEXT NOT NULL,
  ...
)
```

## Design Decision: Where to Store Deleted Records?

### Option 1: Add `deleted_at` Column to Existing Tables ❌
```sql
ALTER TABLE {collection} ADD COLUMN deleted_at TIMESTAMPTZ;
```

**Problems:**
- Breaks existing table structure
- Requires migration for all existing tables
- Mixes active and deleted records in same table
- Complicates queries (always need WHERE deleted_at IS NULL)

### Option 2: Create Separate `{collection}_deleted` Table ✅ CHOSEN
```sql
CREATE TABLE {collection}_deleted (
  id TEXT NOT NULL,
  tenant_id TEXT NOT NULL,
  data JSONB NOT NULL,           -- Full entity snapshot
  deleted_at TIMESTAMPTZ NOT NULL,
  deleted_by TEXT NOT NULL,
  delete_type TEXT NOT NULL,     -- 'soft' or 'hard'
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (id, tenant_id)
)
```

**Benefits:**
- ✅ Clean separation: active vs deleted records
- ✅ No migration needed for existing tables
- ✅ Deleted table is append-only (audit trail)
- ✅ Can query deleted records separately
- ✅ Can restore from deleted table
- ✅ Follows same pattern as `{collection}_log`

## Implementation Strategy

### Step 1: Add Helper Method to Create Deleted Table

Add new method `_createDeletedTable()` that:
1. Creates `{collection}_deleted` table
2. Enables RLS for tenant isolation
3. Creates index on `deleted_at` for time-based queries
4. Creates index on `delete_type` for filtering soft/hard deletes

### Step 2: Call from Existing Table Creation Methods

Update:
- `_createDirectTable()` → also create `{collection}_deleted`
- `_createLoggedTables()` → also create `{collection}_deleted`
- `_createVersionedTables()` → also create `{collection}_deleted`

### Step 3: Ensure Idempotency

Use `CREATE TABLE IF NOT EXISTS` to ensure:
- Safe to run multiple times
- Won't break existing deployments
- Backward compatible

## DDD & Clean Architecture Principles

### ✅ Separation of Concerns
- **Domain Layer (aq_schema):** Defines `Storable.softDelete` interface
- **Infrastructure Layer (dart_vault):** Implements storage mechanism
- **Application Layer:** Uses repositories without knowing about tables

### ✅ Dependency Inversion
- Repositories depend on `Storable` interface (abstraction)
- PostgresSchemaDeployer depends on `DomainRegistration` (abstraction)
- No direct coupling to concrete implementations

### ✅ Single Responsibility
- `PostgresSchemaDeployer`: Creates tables based on domain registrations
- `DirectRepositoryImpl`: Handles CRUD + soft delete logic
- `LoggedRepositoryImpl`: Handles CRUD + audit log + soft delete logic

### ✅ Open/Closed Principle
- Adding `softDelete` extends behavior without modifying existing code
- New `{collection}_deleted` table doesn't break existing tables
- Backward compatible: default `softDelete = true` preserves data

## Implementation Code

```dart
/// Create deleted table for any storage mode.
/// This table stores snapshots of deleted entities for audit and restore.
Future<void> _createDeletedTable(String collection) async {
  await _pool.run((Session connection) async {
    final keys = Storable.keys.dbKeys;
    final deletedTable = '${collection}_deleted';

    // Deleted table: stores full entity snapshot + deletion metadata
    await connection.execute('''
      CREATE TABLE IF NOT EXISTS $deletedTable (
        ${keys.id} TEXT NOT NULL,
        ${keys.tenantId} TEXT NOT NULL,
        ${keys.data} JSONB NOT NULL,
        ${keys.deletedAt} TIMESTAMPTZ NOT NULL,
        deleted_by TEXT NOT NULL,
        delete_type TEXT NOT NULL,
        ${keys.createdAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        ${keys.updatedAt} TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (${keys.id}, ${keys.tenantId})
      )
    ''');

    // Index on deleted_at for time-based queries
    await connection.execute('''
      CREATE INDEX IF NOT EXISTS idx_${collection}_deleted_at
      ON $deletedTable(${keys.deletedAt})
    ''');

    // Index on delete_type for filtering soft/hard deletes
    await connection.execute('''
      CREATE INDEX IF NOT EXISTS idx_${collection}_delete_type
      ON $deletedTable(delete_type)
    ''');

    // Index on tenant_id for fast filtering
    await connection.execute('''
      CREATE INDEX IF NOT EXISTS idx_${collection}_deleted_tenant
      ON $deletedTable(${keys.tenantId})
    ''');

    // Enable RLS for tenant isolation
    await _enableRls(deletedTable);
  });
}
```

## Changes to Existing Methods

### _createDirectTable
```dart
Future<void> _createDirectTable(DomainRegistration domain) async {
  await _pool.run((Session connection) async {
    // ... existing code ...
  });
  
  // NEW: Create deleted table
  await _createDeletedTable(domain.collection);
}
```

### _createLoggedTables
```dart
Future<void> _createLoggedTables(DomainRegistration domain) async {
  await _pool.run((Session connection) async {
    // ... existing code for main table ...
    // ... existing code for log table ...
  });
  
  // NEW: Create deleted table
  await _createDeletedTable(domain.collection);
}
```

### _createVersionedTables
```dart
Future<void> _createVersionedTables(DomainRegistration domain) async {
  await _pool.run((Session connection) async {
    // ... existing code for versions table ...
    // ... existing code for current table ...
  });
  
  // NEW: Create deleted table
  await _createDeletedTable(domain.collection);
}
```

## Testing Strategy

1. ✅ Run schema deployer with existing domains
2. ✅ Verify `{collection}_deleted` tables created
3. ✅ Verify RLS policies applied
4. ✅ Verify indexes created
5. ✅ Test soft delete → record in deleted table
6. ✅ Test hard delete → record in deleted table
7. ✅ Test restore → record removed from deleted table

## Backward Compatibility

✅ **Existing deployments:** New tables created on next deployment
✅ **Existing data:** Not affected (no ALTER TABLE)
✅ **Existing queries:** Not affected (deleted table is separate)
✅ **Rollback:** Can drop `{collection}_deleted` tables if needed

---

**Status:** Ready for implementation
**Risk Level:** LOW (additive changes only, no breaking changes)
**Date:** 2026-04-21
