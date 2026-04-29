# Docker Stack Example

Complete production-ready stack with PostgreSQL, Data Service server, and two clients demonstrating all storage modes.

## Architecture

```
┌─────────────────┐
│  PostgreSQL DB  │
└────────┬────────┘
         │
    ┌────▼─────┐
    │  Server  │ :8765
    └────┬─────┘
         │
    ┌────┴────────────┐
    │                 │
┌───▼────┐    ┌──────▼──────┐
│Console │    │   Flutter   │
│Client  │    │   Client    │
└────────┘    └─────────────┘
```

## Components

### 1. PostgreSQL Database
- Port: 5432
- Database: vault_db
- User: vault_user
- Password: vault_pass

### 2. Server (Data Service)
- Port: 8765
- VaultRegistry with PostgreSQL storage
- HTTP API with shelf
- Registered domains:
  - AqStudioProject (Direct)
  - WorkflowRun (Logged)
  - TestDocumentV1 (Direct with migrations)

### 3. Console Client (Dart)
- Pure Dart console application
- Tests all storage modes via IDataLayer
- Demonstrates CRUD operations and audit logs

### 4. Flutter Client
- Full UI with 3 tabs (Projects, Runs, Documents)
- Real-time CRUD operations
- Audit log viewer for logged storage
- Status management for workflow runs

## Running the Stack

### Option 1: Docker Compose (Recommended)

**Important:** Run from `pkgs/` directory (parent of both dart_vault_package and aq_schema):

```bash
cd /path/to/your/project/pkgs
docker-compose -f dart_vault_package/example/stack/docker-compose.yml up --build
```

This starts:
- PostgreSQL on localhost:5432
- Server on localhost:8765

Then run clients separately:

**Console Client:**
```bash
cd dart_vault_package/example/stack/console_client
dart pub get
dart run
```

**Flutter Client:**
```bash
cd dart_vault_package/example/stack/flutter_client
flutter pub get
flutter run -d linux  # or -d android, -d ios
```

### Option 2: Manual Setup

**Terminal 1 - PostgreSQL:**
```bash
docker run -d \
  -e POSTGRES_DB=vault_db \
  -e POSTGRES_USER=vault_user \
  -e POSTGRES_PASSWORD=vault_pass \
  -p 5432:5432 \
  postgres:15-alpine
```

**Terminal 2 - Server:**
```bash
cd server
dart pub get
dart run
```

**Terminal 3 - Console Client:**
```bash
cd console_client
dart pub get
dart run
```

**Terminal 4 - Flutter Client:**
```bash
cd flutter_client
flutter pub get
flutter run
```

## Storage Modes Demonstrated

### Direct Storage (AqStudioProject)
- Simple CRUD operations
- No versioning
- Fast and lightweight
- **Tab:** Projects (both clients)

### Logged Storage (WorkflowRun)
- Full audit trail
- Every change logged
- Status transitions tracked
- **Tab:** Runs (both clients)

### Direct with Migrations (TestDocument)
- Schema evolution support
- Migration functions
- Version management
- **Tab:** Documents (both clients)

## Testing the Stack

### 1. Create a Project (Direct Storage)
```bash
# Console client does this automatically
# Or use Flutter client: Projects tab → Create button
```

### 2. Create a Workflow Run (Logged Storage)
```bash
# Console client creates and updates status
# Or use Flutter client: Runs tab → Create button → Change status
```

### 3. View Audit Log
```bash
# Console client prints audit log
# Or use Flutter client: Runs tab → Tap on run → View audit log
```

### 4. Test Documents (Migrations)
```bash
# Console client creates test document
# Or use Flutter client: Documents tab → Create button
```

## Client Protocol Usage

Both clients use **IDataLayer protocol** from aq_schema:

```dart
// Initialize once
await IDataLayer.initialize(
  endpoint: 'http://localhost:8765',
  useBuffer: true,
);

// Access repositories
final projects = IDataLayer.instance.direct<AqStudioProject>(...);
final runs = IDataLayer.instance.logged<WorkflowRun>(...);
final docs = IDataLayer.instance.direct<TestDocumentV1>(...);
```

**Key Benefits:**
- Zero storage knowledge in clients
- Single point of initialization
- Single point of access
- Type-safe repository pattern
- Multi-tenancy built-in

## Environment Variables

Server accepts:
- `DB_HOST` - PostgreSQL host (default: localhost)
- `DB_PORT` - PostgreSQL port (default: 5432)
- `DB_NAME` - Database name (default: vault_db)
- `DB_USER` - Database user (default: vault_user)
- `DB_PASSWORD` - Database password (default: vault_pass)
- `SERVER_PORT` - Server port (default: 8765)

## Health Check

```bash
curl http://localhost:8765/health
```

Response:
```json
{
  "status": "healthy",
  "timestamp": "2026-04-19T04:07:16.432Z"
}
```

## Production Notes

1. **Security:** This example has no authentication for simplicity. Add auth middleware in production.
2. **CORS:** Server allows all origins (`*`). Restrict in production.
3. **Database:** Use connection pooling and proper credentials in production.
4. **Monitoring:** Add logging, metrics, and health checks.
5. **Scaling:** Use load balancer for multiple server instances.

## Troubleshooting

**Server won't start:**
- Check PostgreSQL is running: `docker ps`
- Check port 8765 is free: `lsof -i :8765`

**Client connection failed:**
- Verify server is running: `curl http://localhost:8765/health`
- Check endpoint URL in client code

**Database errors:**
- Check PostgreSQL logs: `docker logs <container_id>`
- Verify credentials match

## File Structure

```
stack/
├── docker-compose.yml          # Orchestration
├── server/
│   ├── Dockerfile
│   ├── pubspec.yaml
│   └── main.dart              # VaultRegistry + HTTP API
├── console_client/
│   ├── pubspec.yaml
│   └── main.dart              # CLI testing all modes
└── flutter_client/
    ├── pubspec.yaml
    └── lib/main.dart          # UI with 3 tabs
```
