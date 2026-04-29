# ADR-003: Secrets Management Architecture

**Status:** ✅ Accepted
**Date:** 2026-04-09
**Deciders:** Production Hardening Team

---

## Context

The dart_vault_package requires secure management of sensitive credentials:
- Database passwords (PostgreSQL)
- API keys and tokens
- Service authentication credentials
- Encryption keys

Previously, credentials were hardcoded in source files or passed as constructor parameters, creating security risks:
- Credentials visible in version control
- No rotation mechanism
- No audit trail
- Difficult to manage across environments

---

## Decision

We implement a **pluggable secrets management system** with three backends:

### 1. Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Application Code                                       │
│  - Uses SecretsManager interface                       │
│  - No knowledge of backend                              │
└────────────────┬────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────┐
│  SecretsManager (Interface)                             │
│  - getSecret(key) → String                              │
│  - setSecret(key, value, metadata)                      │
│  - rotateSecret(key)                                    │
│  - listSecrets() → List<String>                         │
│  - getMetadata(key) → SecretMetadata                    │
└────────────────┬────────────────────────────────────────┘
                 │
        ┌────────┴────────┬────────────────┐
        ▼                 ▼                ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ InMemory     │  │ Vault        │  │ AWS Secrets  │
│ (Dev/Test)   │  │ (Production) │  │ (Cloud)      │
└──────────────┘  └──────────────┘  └──────────────┘
```

### 2. Implementation Backends

#### InMemorySecretsManager
- **Use Case:** Development, testing, CI/CD
- **Storage:** In-memory Map
- **Persistence:** None (ephemeral)
- **Features:** Fast, simple, no external dependencies

#### VaultSecretsManager
- **Use Case:** Production on-premise
- **Storage:** HashiCorp Vault KV v2
- **Persistence:** Durable, encrypted at rest
- **Features:**
  - Versioning (automatic)
  - Audit logging (Vault native)
  - Access control (Vault policies)
  - High availability

#### AwsSecretsManager
- **Use Case:** Production on AWS
- **Storage:** AWS Secrets Manager
- **Persistence:** Durable, encrypted (KMS)
- **Features:**
  - Multi-region replication
  - IAM integration
  - Automatic rotation (AWS Lambda)
  - CloudWatch monitoring

### 3. Caching Strategy

All backends use `SecretsCache` with 5-minute TTL:
- Reduces backend load
- Improves latency
- Automatic invalidation on updates
- Thread-safe

### 4. Credential Rotation

`CredentialRotationService` provides:
- **Automatic rotation:** Scheduled checks (hourly default)
- **Age-based policy:** 90-day default max age
- **Manual triggers:** `rotateNow(key)`
- **Status monitoring:** `getStatus()` returns rotation state
- **Reporting:** `RotationReport` with success/failure details

---

## Consequences

### Positive

✅ **Security:**
- No hardcoded credentials in source code
- Centralized secret management
- Automatic rotation reduces exposure window
- Audit trail for all secret access

✅ **Flexibility:**
- Pluggable backends (dev/prod/cloud)
- Easy to add new backends (implement interface)
- Environment-specific configuration

✅ **Operations:**
- Automatic rotation reduces manual work
- Status monitoring for compliance
- Migration tools for existing secrets

✅ **Testing:**
- InMemorySecretsManager for unit tests
- No external dependencies in CI/CD
- Fast test execution

### Negative

⚠️ **Complexity:**
- Additional infrastructure (Vault/AWS)
- Initial migration effort
- Learning curve for operators

⚠️ **Dependencies:**
- Vault requires running server
- AWS requires account setup
- Network latency for remote backends

⚠️ **Cost:**
- Vault: infrastructure cost
- AWS Secrets Manager: $0.40/secret/month + API calls

### Mitigation

- **Migration:** Automated migration scripts (`SecretsMigration`)
- **Documentation:** Comprehensive setup guides
- **Fallback:** InMemorySecretsManager for development
- **Monitoring:** Built-in status reporting

---

## Implementation

### Phase 1: Core Infrastructure ✅
- [x] SecretsManager interface
- [x] InMemorySecretsManager
- [x] SecretsCache with TTL
- [x] Exception hierarchy

### Phase 2: Production Backends ✅
- [x] VaultHttpClient
- [x] VaultSecretsManager (KV v2)
- [x] AwsSecretsManager (mock)
- [x] Comprehensive tests (21 tests, 100% passing)

### Phase 3: Rotation & Migration ✅
- [x] CredentialRotationService
- [x] SecretsMigration utilities
- [x] Status monitoring
- [x] Rotation reports

### Phase 4: Documentation ✅
- [x] ADR-003 (this document)
- [x] ADR-004 (rotation strategy)
- [x] Migration guide
- [x] API documentation

---

## Usage Examples

### Development (In-Memory)

```dart
final secrets = InMemorySecretsManager();
await secrets.setSecret('db_password', 'dev_password');

final password = await secrets.getSecret('db_password');
```

### Production (Vault)

```dart
final secrets = VaultSecretsManager(
  vaultUrl: 'https://vault.company.com',
  token: Platform.environment['VAULT_TOKEN']!,
  mountPath: 'secret',
);

final password = await secrets.getSecret('postgres/password');
```

### With Rotation

```dart
final rotation = CredentialRotationService(
  secretsManager: secrets,
  checkInterval: Duration(hours: 1),
  maxAge: Duration(days: 90),
);

rotation.start();

// Manual rotation
await rotation.rotateNow('postgres/password');

// Check status
final statuses = await rotation.getStatus();
for (final status in statuses) {
  print('${status.key}: ${status.needsRotation ? "NEEDS ROTATION" : "OK"}');
}
```

### Migration

```dart
final migration = SecretsMigration(secrets);

// Migrate PostgreSQL credentials
await migration.migratePostgresCredentials(
  host: 'localhost',
  database: 'aq_studio',
  username: 'postgres',
  password: 'old_hardcoded_password',
);

// Verify
final report = await migration.verify();
print(report); // MigrationReport(verified: 4, failed: 0)
```

---

## Alternatives Considered

### 1. Environment Variables Only
- **Pros:** Simple, no infrastructure
- **Cons:** No rotation, no versioning, visible in process list
- **Verdict:** ❌ Insufficient for production

### 2. Encrypted Config Files
- **Pros:** No external service
- **Cons:** Key management problem, no rotation, manual updates
- **Verdict:** ❌ Doesn't solve the core problem

### 3. Cloud Provider Native (AWS/GCP/Azure)
- **Pros:** Integrated with cloud platform
- **Cons:** Vendor lock-in, not portable
- **Verdict:** ⚠️ Supported as one backend option

### 4. HashiCorp Vault Only
- **Pros:** Industry standard, feature-rich
- **Cons:** Infrastructure overhead, learning curve
- **Verdict:** ✅ Supported as primary production backend

---

## References

- [HashiCorp Vault KV v2 Documentation](https://www.vaultproject.io/docs/secrets/kv/kv-v2)
- [AWS Secrets Manager Best Practices](https://docs.aws.amazon.com/secretsmanager/latest/userguide/best-practices.html)
- [OWASP Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html)
- ADR-004: Credential Rotation Strategy

---

## Revision History

| Date       | Version | Changes                          |
|------------|---------|----------------------------------|
| 2026-04-09 | 1.0     | Initial version (Week 2 Day 3)   |
