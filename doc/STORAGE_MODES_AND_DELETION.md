# Storage Modes and Deletion Patterns

## Overview

dart_vault provides three storage modes, each with different deletion semantics based on business requirements.

## 1. DirectStorage - Hard Delete

**Use case:** Simple entities, settings, metadata, temporary data

**Deletion:** Physical removal from database (HARD DELETE)

**Characteristics:**
- No version history
- No audit trail
- Record is permanently removed from DB
- Optional soft delete if model implements `softDelete` field

**Example:**
```dart
final projects = vault.direct<AqStudioProject>(
  collection: AqStudioProject.kCollection,
  fromMap: AqStudioProject.fromMap,
);

await projects.save(project);
await projects.delete(project.id);  // HARD DELETE - physically removed

final deleted = await projects.findById(project.id);
// deleted == null - record no longer exists
```

**Database state after delete:**
```sql
SELECT * FROM projects WHERE id = 'proj-001';
-- (0 rows) - physically removed
```

**Soft delete option:**
If your model has a `deletedAt` or `isDeleted` field, you can implement soft delete:
```dart
// Instead of delete(), update the flag
final softDeleted = project.copyWith(deletedAt: DateTime.now());
await projects.save(softDeleted);

// Query excludes soft-deleted records
final active = await projects.findAll(
  query: VaultQuery().where('deletedAt', VaultOperator.isNull, null),
);
```

## 2. VersionedStorage - Soft Delete (State Flag)

**Use case:** Blueprints, Instructions, versioned content, collaborative editing

**Deletion:** State flag change (SOFT DELETE) - record remains in DB

**Characteristics:**
- Multiple versions per entity (draft, published, snapshot)
- Branch support (main, feature branches)
- Deletion changes `state` to `deleted`
- NO hard delete - versions are permanent
- Full version tree preserved

**Example:**
```dart
final graphs = vault.versioned<WorkflowGraph>(
  collection: WorkflowGraph.kCollection,
  fromMap: WorkflowGraph.fromMap,
);

// Create entity (draft state)
final node = await graphs.createEntity(graph);
// node.state == 'draft'

// Publish (published state)
final published = await graphs.publishDraft(node.nodeId);
// published.state == 'published'

// Delete version (deleted state)
await graphs.deleteVersion(published.nodeId);
// State changed to 'deleted', but record still in DB
```

**Database state after delete:**
```sql
SELECT entity_id, node_id, state, version FROM workflow_graphs 
WHERE entity_id = 'graph-001';

-- entity_id    | node_id      | state     | version
-- graph-001    | node-draft   | draft     | 0.0.0
-- graph-001    | node-pub     | deleted   | 1.0.0  ← marked as deleted
-- graph-001    | node-snap    | snapshot  | 1.0.0
-- (3 rows) - all versions still in DB
```

**Why soft delete?**
- Preserve version history for compliance
- Enable rollback to previous versions
- Maintain referential integrity across branches
- Support "undelete" operations

**Business logic:**
```dart
// In business logic, NEVER hard delete versioned entities
// ❌ WRONG:
await graphs.deleteEntity(entityId);  // This would remove ALL versions

// ✅ CORRECT:
await graphs.deleteVersion(nodeId);   // Marks specific version as deleted
```

## 3. LoggedStorage - Hard Delete with Audit Trail

**Use case:** Sessions, workflow runs, auditable operations

**Deletion:** Physical removal with permanent audit log

**Characteristics:**
- Every change logged to `{collection}_log` table
- Audit trail includes full diffs
- Hard delete removes from main table
- Audit log persists forever (compliance requirement)

**Example:**
```dart
final runs = vault.logged<WorkflowRun>(
  collection: WorkflowRun.kCollection,
  fromMap: WorkflowRun.fromMap,
);

// Create (logged)
await runs.save(run, actorId: 'user-001');

// Update (logged)
final updated = run.copyWith(status: WorkflowRunStatus.completed);
await runs.save(updated, actorId: 'user-001');

// Delete (logged)
await runs.delete(run.id, actorId: 'system');

// Main record deleted, but audit log persists
final history = await runs.getHistory(run.id);
// history.length == 3 (created, updated, deleted)
```

**Database state after delete:**
```sql
-- Main table: empty
SELECT * FROM workflow_runs WHERE id = 'run-001';
-- (0 rows) - physically removed

-- Audit log: preserved
SELECT id, operation, changed_by FROM workflow_runs_log 
WHERE data->>'entityId' = 'run-001';

-- id                  | operation | changed_by
-- run-001-log-abc123  | created   | user-001
-- run-001-log-def456  | updated   | user-001
-- run-001-log-ghi789  | deleted   | system
-- (3 rows) - full audit trail preserved
```

**Why hard delete with audit?**
- Reduce main table size (performance)
- Comply with data retention policies
- Maintain audit trail for compliance
- Enable forensic analysis

## Comparison Table

| Feature | DirectStorage | VersionedStorage | LoggedStorage |
|---------|--------------|------------------|---------------|
| **Delete type** | Hard | Soft (state flag) | Hard |
| **History** | None | Full version tree | Audit log only |
| **After delete** | Record gone | Record flagged | Record gone, log persists |
| **Undelete** | Impossible | Change state back | Restore from log |
| **Use case** | Simple data | Versioned content | Auditable operations |
| **DB impact** | Smallest | Largest (all versions) | Medium (main + log) |

## Implementation Guidelines

### When to use DirectStorage
- Settings and preferences
- Temporary data (caches, sessions without audit)
- Simple metadata
- Data that doesn't need history

### When to use VersionedStorage
- Blueprints and templates
- Instructions and prompts
- Collaborative documents
- Any content that needs version control
- Data with branches (main, feature, experimental)

### When to use LoggedStorage
- Workflow runs and executions
- User sessions (with audit requirement)
- Financial transactions
- Any operation requiring audit trail
- Compliance-sensitive data

## Migration Considerations

### From DirectStorage to VersionedStorage
If you need to add version control to existing DirectStorage:
1. Create new VersionedStorage collection
2. Migrate existing records as initial versions
3. Update application code to use versioned API
4. Keep old collection for historical data

### From DirectStorage to LoggedStorage
If you need to add audit trail:
1. Create new LoggedStorage collection
2. Migrate existing records
3. Update application code to pass `actorId`
4. Archive old collection

### From LoggedStorage to VersionedStorage
If you need version control instead of just audit:
1. Create VersionedStorage collection
2. Migrate records as published versions
3. Convert log entries to version history
4. Update application code

## Testing

Run the comprehensive test to see all three modes in action:

```bash
cd pkgs/dart_vault_package/example/stack/console_client
dart run main_comprehensive.dart
```

This demonstrates:
- DirectStorage: Create → Update → Hard Delete
- VersionedStorage: Draft → Publish → Snapshot → Soft Delete
- LoggedStorage: Create → Update → Hard Delete (audit persists)

---

**Last Updated:** 2026-04-20  
**Author:** AQ Architecture Team
