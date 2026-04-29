# Examples

This directory contains runnable example projects demonstrating dart_vault usage patterns.

## Structure

```
example/
├── 01_serverless_desktop/     # Single app, InMemory storage, no HTTP
│   ├── pubspec.yaml
│   └── main.dart
├── 02_client_server/          # Client-server architecture
│   ├── server/                # Data Service server
│   │   ├── pubspec.yaml
│   │   └── main.dart
│   └── client/                # Thin client
│       ├── pubspec.yaml
│       └── main.dart
└── postgres_example.dart      # PostgreSQL integration (legacy)
```

## Running Examples

### Example 1: Serverless Desktop

```bash
cd example/01_serverless_desktop
dart pub get
dart run
```

**Features:**
- Single Dart application
- InMemory storage (no database)
- No HTTP server needed
- Direct and Versioned repositories
- Multi-tenancy demonstration

### Example 2: Client-Server

**Terminal 1 - Start Server:**
```bash
cd example/02_client_server/server
dart pub get
dart run
```

**Terminal 2 - Run Client:**
```bash
cd example/02_client_server/client
dart pub get
dart run
```

**Features:**
- Server with VaultRegistry
- Client with IDataLayer.initialize()
- Demonstrates thin client pattern
- Uses aq_schema domains

## What Each Example Shows

### 01_serverless_desktop
- ✅ Vault with InMemory storage
- ✅ Direct Repository (AqStudioProject)
- ✅ Versioned Repository (WorkflowGraph)
- ✅ CRUD operations
- ✅ Version lifecycle
- ✅ Multi-tenancy

### 02_client_server/server
- ✅ VaultRegistry setup
- ✅ Domain registration from aq_schema
- ✅ Schema deployment
- ✅ Handshake and RPC dispatch

### 02_client_server/client
- ✅ IDataLayer.initialize()
- ✅ Thin client pattern
- ✅ Zero storage knowledge
- ✅ Buffer management
