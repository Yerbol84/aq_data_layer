# Soft Delete Testing Guide

## 🎯 Overview

This guide walks you through testing the complete soft delete implementation in dart_vault.

---

## 📋 Prerequisites

- Docker and Docker Compose installed
- Terminal access
- PostgreSQL client (optional, for database inspection)

---

## 🚀 Step 1: Rebuild the Stack

The server needs to be rebuilt to include the new soft delete functionality.

```bash
# Navigate to the stack directory
cd pkgs/dart_vault_package/example/stack

# Stop any running containers
docker compose down

# Remove old postgres data (optional, for clean start)
rm -rf postgres_data

# Rebuild and start the stack
docker compose up --build
```

**Expected output:**
```
✅ postgres container started
✅ server container built and started
✅ Server listening on port 8765
✅ Database schema deployed (including {collection}_deleted tables)
```

---

## 🧪 Step 2: Run the Soft Delete Test

Open a new terminal (keep the stack running in the first terminal).

```bash
# Navigate to console client
cd pkgs/dart_vault_package/example/stack/console_client

# Run the soft delete test
dart run main_soft_delete_test.dart
```

**Expected output:**
```
🎯 Soft Delete Feature Test

📋 Pre-flight Checks
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔍 Checking server at http://localhost:8765...
   ✅ Server is reachable

🔌 Connecting to data layer...
   ✅ Connected to REMOTE server

🧪 Soft Delete Tests
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

━━━ 1. DirectStorage: Soft Delete (AqStudioProject) ━━━
   Feature: deletedAt field in model
   Behavior: Mark as deleted, keep in DB
   Default: softDelete = true

   📝 Step 1: Creating 3 projects...
      ✅ Created: Soft Delete Project 1 (id: proj-soft-001)
      ✅ Created: Soft Delete Project 2 (id: proj-soft-002)
      ✅ Created: Soft Delete Project 3 (id: proj-soft-003)

   📊 Step 2: Query all projects (before delete)
      Found: 3 projects
         - proj-soft-001: Soft Delete Project 1 (deletedAt: null)
         - proj-soft-002: Soft Delete Project 2 (deletedAt: null)
         - proj-soft-003: Soft Delete Project 3 (deletedAt: null)

   🗑️  Step 3: Soft deleting proj-soft-002...
      ✅ SOFT DELETED: proj-soft-002
         - Record still in DB
         - deletedAt field set to current timestamp
         - Logged to projects_deleted table

   📊 Step 4: Query all projects (after soft delete)
      Found: 2 projects (deleted excluded by default)
         - proj-soft-001: Soft Delete Project 1
         - proj-soft-003: Soft Delete Project 3

   📊 Step 5: Query including deleted...
      Found: 3 projects (including deleted)
         - proj-soft-001: Soft Delete Project 1 ✅ ACTIVE
         - proj-soft-002: Soft Delete Project 2 ❌ DELETED
         - proj-soft-003: Soft Delete Project 3 ✅ ACTIVE

   ♻️  Step 6: Restoring proj-soft-002...
      ✅ RESTORED: proj-soft-002
         - deletedAt field cleared
         - Record active again

   📊 Step 7: Query all projects (after restore)
      Found: 3 projects
         - proj-soft-001: Soft Delete Project 1
         - proj-soft-002: Soft Delete Project 2
         - proj-soft-003: Soft Delete Project 3

   ✅ DirectStorage soft delete test PASSED!

━━━ 2. LoggedStorage: Soft Delete (WorkflowRun) ━━━
   Feature: deletedAt field + audit log
   Behavior: Mark as deleted, keep in DB, log operation
   Audit: ALL operations logged (create, update, delete, restore)

   📝 Step 1: Creating 3 workflow runs...
      ✅ Created: run-soft-001 (status: running)
      ✅ Created: run-soft-002 (status: running)
      ✅ Created: run-soft-003 (status: running)

   📊 Step 2: Query all runs (before delete)
      Found: 3 runs

   🗑️  Step 3: Soft deleting run-soft-002...
      ✅ SOFT DELETED: run-soft-002
         - Record still in workflow_runs table
         - deletedAt field set
         - Logged to workflow_runs_deleted table
         - Audit log entry created (operation: deleted)

   📊 Step 4: Query all runs (after soft delete)
      Found: 2 runs (deleted excluded)

   📊 Step 5: Query including deleted...
      Found: 3 runs (including deleted)
         - run-soft-001: running ✅ ACTIVE
         - run-soft-002: running ❌ DELETED
         - run-soft-003: running ✅ ACTIVE

   📜 Step 6: Check audit log for run-soft-002...
      Found: 2 log entries
         - created by user-test at 2026-04-21T06:30:00.000Z
         - deleted by user-test at 2026-04-21T06:30:01.000Z

   ♻️  Step 7: Restoring run-soft-002...
      ✅ RESTORED: run-soft-002
         - deletedAt field cleared
         - Audit log entry created (operation: restored)

   📊 Step 8: Query all runs (after restore)
      Found: 3 runs

   📜 Step 9: Check audit log after restore...
      Found: 3 log entries
         - created by user-test
         - deleted by user-test
         - restored by user-test

   ✅ LoggedStorage soft delete test PASSED!

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ All soft delete tests completed!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 🔍 Step 3: Verify in Database

Connect to PostgreSQL to inspect the database state:

```bash
# Get postgres container ID
docker ps | grep postgres

# Connect to database
docker exec -it <postgres-container-id> psql -U vault_user -d vault_db
```

### Check Main Tables

```sql
-- Projects table (soft deleted records still here with deletedAt set)
SELECT 
  id, 
  data->>'name' as name, 
  data->>'deletedAt' as deleted_at 
FROM projects 
ORDER BY id;

-- Expected:
-- id              | name                    | deleted_at
-- proj-soft-001   | Soft Delete Project 1   | NULL
-- proj-soft-002   | Soft Delete Project 2   | NULL (restored)
-- proj-soft-003   | Soft Delete Project 3   | NULL
```

### Check Deleted Log Tables

```sql
-- Projects deleted log (audit trail of all deletions)
SELECT 
  id, 
  delete_type, 
  deleted_by, 
  deleted_at 
FROM projects_deleted 
ORDER BY deleted_at;

-- Expected:
-- id              | delete_type | deleted_by | deleted_at
-- proj-soft-002   | soft        | system     | 2026-04-21 06:30:01
```

### Check WorkflowRuns

```sql
-- Workflow runs table
SELECT 
  id, 
  data->>'status' as status, 
  data->>'deletedAt' as deleted_at 
FROM workflow_runs 
ORDER BY id;

-- Expected:
-- id              | status   | deleted_at
-- run-soft-001    | running  | NULL
-- run-soft-002    | running  | NULL (restored)
-- run-soft-003    | running  | NULL
```

### Check Audit Logs

```sql
-- Workflow runs deleted log
SELECT 
  id, 
  delete_type, 
  deleted_by, 
  deleted_at 
FROM workflow_runs_deleted 
ORDER BY deleted_at;

-- Expected:
-- id              | delete_type | deleted_by | deleted_at
-- run-soft-002    | soft        | user-test  | 2026-04-21 06:30:01

-- Workflow runs audit log (ALL operations preserved)
SELECT 
  id, 
  data->>'operation' as operation, 
  data->>'changedBy' as actor 
FROM workflow_runs_log 
WHERE data->>'entityId' = 'run-soft-002'
ORDER BY data->>'timestamp';

-- Expected:
-- id       | operation | actor
-- log-001  | created   | user-test
-- log-002  | deleted   | user-test
-- log-003  | restored  | user-test
```

### List All Tables

```sql
-- List all tables (should see {collection}_deleted tables)
\dt

-- Expected tables:
-- projects
-- projects_deleted          ← NEW
-- test_documents
-- test_documents_deleted    ← NEW
-- workflow_runs
-- workflow_runs_deleted     ← NEW
-- workflow_runs_log
```

---

## ✅ Success Criteria

### 1. Soft Delete Works
- ✅ Record marked with `deletedAt` timestamp
- ✅ Record stays in main table
- ✅ Deletion logged to `{collection}_deleted` table
- ✅ Query excludes deleted by default
- ✅ `findAllIncludingDeleted()` returns deleted records

### 2. Restore Works
- ✅ `deletedAt` field cleared
- ✅ Record becomes active again
- ✅ Appears in normal queries

### 3. Audit Trail (LoggedStorage)
- ✅ All operations logged (create, delete, restore)
- ✅ Audit log preserved even after delete
- ✅ Actor ID tracked for each operation

### 4. Database Schema
- ✅ `{collection}_deleted` tables created automatically
- ✅ Tables have correct structure (id, tenant_id, data, deleted_at, deleted_by, delete_type)
- ✅ Indexes created on deleted_at, delete_type, tenant_id
- ✅ RLS enabled for tenant isolation

---

## 🐛 Troubleshooting

### Server won't start
```bash
# Check logs
docker compose logs server

# Common issues:
# - Port 8765 already in use
# - Database connection failed
# - Schema deployment error
```

### Test fails with "Server not reachable"
```bash
# Check if containers are running
docker ps

# Check server health
curl http://localhost:8765/health

# Restart stack
docker compose restart
```

### Database connection issues
```bash
# Check postgres logs
docker compose logs postgres

# Verify postgres is healthy
docker compose ps
```

### Tables not created
```bash
# Check server logs for schema deployment
docker compose logs server | grep "Schema"

# Expected:
# ✅ Schema deployed for collection: projects
# ✅ Created deleted table: projects_deleted
```

---

## 📊 What to Look For

### In Console Output
- ✅ All steps complete without errors
- ✅ Counts match expectations (3 → 2 → 3 after restore)
- ✅ Audit log shows all operations

### In Database
- ✅ Soft deleted records have `deletedAt` timestamp in JSONB data
- ✅ `{collection}_deleted` tables contain deletion audit trail
- ✅ Audit log (`{collection}_log`) preserved for LoggedStorage

### In Server Logs
- ✅ No errors during schema deployment
- ✅ RPC operations execute successfully
- ✅ No SQL errors

---

## 🎉 Next Steps

Once testing is successful:

1. **Update Documentation**
   - Add soft delete examples to API docs
   - Update migration guide

2. **Production Deployment**
   - Deploy updated schema deployer
   - Deploy updated server with RPC operations
   - Update client libraries

3. **Optional Enhancements**
   - Add `deletedAt` to security models (if needed)
   - Add soft delete UI indicators
   - Add bulk restore operations

---

**Status:** Ready for Testing  
**Date:** 2026-04-21  
**Test File:** `example/stack/console_client/main_soft_delete_test.dart`
