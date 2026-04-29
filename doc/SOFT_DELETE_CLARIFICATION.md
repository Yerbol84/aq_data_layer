# Soft Delete Clarification - Entity Level vs Version Level

## Key Concept: `softDelete` Flag Applies to ENTITY, Not Individual Versions

The `softDelete` flag in `Storable` interface controls deletion of **THE ENTIRE ENTITY** (all versions, all history), NOT individual versions or log entries.

---

## 1. DirectStorage - Simple Case ✅

**One object = One record in DB**

```dart
class AqStudioProject implements DirectStorable {
  final String id;                    // Entity ID
  final DateTime? deletedAt;
  
  @override
  bool get softDelete => true;
}
```

**Delete behavior:**
```dart
await projects.delete('proj-001');
```

- `softDelete = true`: Mark `deletedAt = now`, record stays in `projects` table
- `softDelete = false`: Remove from `projects` table completely

**Clear and simple!** ✅

---

## 2. VersionedStorage - ENTITY Level Delete

**One entity = Multiple versions in DB**

```sql
-- workflow_graphs table
entity_id    | node_id      | state      | version | deleted_at
graph-001    | node-draft   | draft      | 0.0.0   | NULL
graph-001    | node-v1      | published  | 1.0.0   | NULL
graph-001    | node-v2      | published  | 2.0.0   | NULL
graph-001    | node-snap    | snapshot   | 1.0.0   | NULL
```

### Two Different Delete Operations:

#### A. Delete Specific Version (ALWAYS SOFT)
```dart
await graphs.deleteVersion('node-v1');  // Delete ONE version
```
**Result:**
```sql
entity_id    | node_id      | state      | version | deleted_at
graph-001    | node-draft   | draft      | 0.0.0   | NULL
graph-001    | node-v1      | deleted    | 1.0.0   | NULL  ← State changed to 'deleted'
graph-001    | node-v2      | published  | 2.0.0   | NULL
graph-001    | node-snap    | snapshot   | 1.0.0   | NULL
```
- Changes `state` to `'deleted'`
- Record stays in DB
- **This is ALWAYS soft delete** (business logic requirement)
- **NOT controlled by `softDelete` flag**

#### B. Delete Entire Entity (Controlled by `softDelete` flag)
```dart
await graphs.deleteEntity('graph-001');  // Delete ALL versions
```

**If `softDelete = true`:**
```sql
entity_id    | node_id      | state      | version | deleted_at
graph-001    | node-draft   | draft      | 0.0.0   | 2026-04-20 09:00:00  ← ALL versions marked
graph-001    | node-v1      | published  | 1.0.0   | 2026-04-20 09:00:00  ← ALL versions marked
graph-001    | node-v2      | published  | 2.0.0   | 2026-04-20 09:00:00  ← ALL versions marked
graph-001    | node-snap    | snapshot   | 1.0.0   | 2026-04-20 09:00:00  ← ALL versions marked
```
- ALL versions get `deletedAt = now`
- ALL versions stay in DB
- Can restore entire entity

**If `softDelete = false`:**
```sql
-- workflow_graphs table
(0 rows)  ← ALL versions physically removed
```
- ALL versions removed from DB
- Logged to `workflow_graphs_deleted` table

**Key Point:** `softDelete` flag controls deletion of **THE ENTIRE ENTITY** (all versions together), not individual versions.

---

## 3. LoggedStorage - ENTITY Level Delete

**One entity = One record + Multiple log entries**

```sql
-- workflow_runs table (main)
id          | status     | created_at
run-001     | completed  | 2026-04-20 08:00:00

-- workflow_runs_log table (audit trail)
entry_id    | entity_id | operation | changed_at
log-001     | run-001   | created   | 2026-04-20 08:00:00
log-002     | run-001   | updated   | 2026-04-20 08:05:00
log-003     | run-001   | updated   | 2026-04-20 08:10:00
```

### Two Different Delete Operations:

#### A. Delete Log Entry (NEVER ALLOWED)
```dart
// ❌ NOT POSSIBLE - Log entries are immutable
// Cannot delete individual log entries
// Audit trail must be permanent
```
- Log entries are **append-only**
- **Cannot be deleted** (compliance requirement)
- **NOT controlled by `softDelete` flag**

#### B. Delete Entire Entity (Controlled by `softDelete` flag)
```dart
await runs.delete('run-001', actorId: 'user-001');  // Delete entity
```

**If `softDelete = true`:**
```sql
-- workflow_runs table (main)
id          | status     | deleted_at
run-001     | completed  | 2026-04-20 09:00:00  ← Marked as deleted

-- workflow_runs_log table (audit trail)
entry_id    | entity_id | operation | changed_at
log-001     | run-001   | created   | 2026-04-20 08:00:00
log-002     | run-001   | updated   | 2026-04-20 08:05:00
log-003     | run-001   | updated   | 2026-04-20 08:10:00
log-004     | run-001   | deleted   | 2026-04-20 09:00:00  ← New log entry
```
- Main record marked with `deletedAt = now`
- Main record stays in `workflow_runs` table
- ALL log entries stay in `workflow_runs_log` table
- New log entry added: `operation = deleted`

**If `softDelete = false`:**
```sql
-- workflow_runs table (main)
(0 rows)  ← Record physically removed

-- workflow_runs_log table (audit trail)
entry_id    | entity_id | operation | changed_at
log-001     | run-001   | created   | 2026-04-20 08:00:00
log-002     | run-001   | updated   | 2026-04-20 08:05:00
log-003     | run-001   | updated   | 2026-04-20 08:10:00
log-004     | run-001   | deleted   | 2026-04-20 09:00:00  ← New log entry
```
- Main record removed from `workflow_runs` table
- ALL log entries **STAY** in `workflow_runs_log` table (permanent audit trail)
- New log entry added: `operation = deleted`

**Key Point:** `softDelete` flag controls deletion of **THE MAIN ENTITY RECORD**, not the audit log. Audit log is ALWAYS preserved.

---

## Summary Table

| Storage Mode | What Gets Deleted | `softDelete = true` | `softDelete = false` | Individual Items |
|--------------|-------------------|---------------------|----------------------|------------------|
| **DirectStorage** | One record | Mark `deletedAt`, keep in DB | Remove from DB | N/A (only one record) |
| **VersionedStorage** | ALL versions of entity | Mark ALL versions `deletedAt` | Remove ALL versions | `deleteVersion()` always soft (state flag) |
| **LoggedStorage** | Main entity record | Mark `deletedAt`, keep in DB | Remove from DB | Log entries NEVER deleted |

---

## Business Logic Rules

### ✅ Controlled by `softDelete` Flag:
- **DirectStorage:** Delete the record
- **VersionedStorage:** Delete ALL versions of entity (`deleteEntity()`)
- **LoggedStorage:** Delete main entity record

### ❌ NOT Controlled by `softDelete` Flag:
- **VersionedStorage:** Delete specific version (`deleteVersion()`) - ALWAYS soft (state flag)
- **LoggedStorage:** Delete log entries - NEVER allowed (immutable audit trail)

---

## Code Example

```dart
// VersionedStorage
class WorkflowGraph implements VersionedStorable {
  @override
  bool get softDelete => true;  // Controls deleteEntity(), not deleteVersion()
}

// Delete specific version (ALWAYS soft, regardless of flag)
await graphs.deleteVersion('node-v1');
// Result: state changed to 'deleted', record stays in DB

// Delete entire entity (controlled by softDelete flag)
await graphs.deleteEntity('graph-001');
// If softDelete = true: ALL versions marked deletedAt, stay in DB
// If softDelete = false: ALL versions removed from DB

// LoggedStorage
class WorkflowRun implements LoggedStorable {
  @override
  bool get softDelete => true;  // Controls main record, not log entries
}

// Delete entity (controlled by softDelete flag)
await runs.delete('run-001', actorId: 'user-001');
// If softDelete = true: Main record marked deletedAt, stays in DB
// If softDelete = false: Main record removed from DB
// In BOTH cases: ALL log entries stay in workflow_runs_log (permanent)
```

---

## What I Understand ✅

1. **`softDelete` flag = ENTITY level control**, not version/log level
2. **VersionedStorage:**
   - `deleteVersion()` = ALWAYS soft (state flag), NOT controlled by `softDelete`
   - `deleteEntity()` = Controlled by `softDelete`, affects ALL versions
3. **LoggedStorage:**
   - `delete()` = Controlled by `softDelete`, affects main record only
   - Log entries = ALWAYS preserved (immutable), NOT controlled by `softDelete`
4. **DirectStorage:**
   - `delete()` = Controlled by `softDelete`, simple case

**Is this correct?** 🎯
