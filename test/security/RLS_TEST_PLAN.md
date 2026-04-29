# RLS Security Test Plan - Threat Model & Attack Scenarios

**Дата:** 2026-04-09
**Цель:** Проверить безопасность RLS tenant-изоляции против реальных атак

---

## 🎯 Threat Model (Модель угроз)

### Атакующие (Threat Actors)

1. **Malicious Tenant** - злонамеренный tenant пытается получить доступ к данным других tenants
2. **Compromised Application** - скомпрометированный код приложения с SQL injection
3. **Insider Threat** - администратор БД пытается обойти RLS
4. **Race Condition Exploit** - атака через параллельные запросы
5. **Context Pollution** - попытка изменить tenant context внутри транзакции

### Векторы атак (Attack Vectors)

1. **SQL Injection** - внедрение SQL через параметры
2. **Context Switching** - попытка изменить `app.current_tenant` внутри запроса
3. **Transaction Isolation Bypass** - использование вложенных транзакций
4. **Timing Attacks** - определение существования записей по времени ответа
5. **Batch Operation Exploits** - атака через `putAll` с разными tenantId
6. **Query Parameter Manipulation** - подмена tenantId в query filters
7. **Connection Pool Pollution** - загрязнение connection pool неправильным контекстом

---

## 🔒 Security Test Categories

### Category 1: Basic Isolation Tests (Базовая изоляция)

**Цель:** Проверить, что tenant не видит чужие данные в нормальных условиях

#### Test 1.1: Read Isolation
```
GIVEN: tenant-a имеет записи [a1, a2], tenant-b имеет записи [b1, b2]
WHEN: tenant-a выполняет get(b1)
THEN: возвращает null
AND: не выбрасывает исключение (не раскрывает существование записи)
```

#### Test 1.2: Write Isolation
```
GIVEN: tenant-a пытается создать запись с id существующей записи tenant-b
WHEN: tenant-a выполняет put(b1, new_data)
THEN: создаётся новая запись (tenant-a, b1) с new_data
AND: запись tenant-b не изменяется
```

#### Test 1.3: Delete Isolation
```
GIVEN: tenant-b имеет запись b1
WHEN: tenant-a выполняет delete(b1)
THEN: операция завершается успешно (не выбрасывает ошибку)
AND: запись tenant-b остаётся нетронутой
```

#### Test 1.4: Query Isolation
```
GIVEN: tenant-a имеет 5 записей, tenant-b имеет 10 записей
WHEN: tenant-a выполняет query() без фильтров
THEN: возвращает ровно 5 записей
AND: все записи принадлежат tenant-a
```

#### Test 1.5: Count Isolation
```
GIVEN: tenant-a имеет 3 записи, tenant-b имеет 7 записей
WHEN: tenant-a выполняет count()
THEN: возвращает 3
```

---

### Category 2: SQL Injection Tests (SQL инъекции)

**Цель:** Проверить, что RLS не обходится через SQL injection

#### Test 2.1: Injection via ID parameter
```
GIVEN: tenant-a пытается внедрить SQL через id
WHEN: get(id: "x' OR tenant_id='tenant-b' --")
THEN: возвращает null (инъекция не работает)
AND: не выбрасывает SQL ошибку
```

#### Test 2.2: Injection via Query Filter
```
GIVEN: tenant-a пытается внедрить SQL через filter value
WHEN: query(filter: {field: "name", value: "x' OR '1'='1"})
THEN: возвращает только записи tenant-a (если есть совпадение)
AND: не возвращает записи других tenants
```

#### Test 2.3: Injection via Collection Name
```
GIVEN: tenant-a пытается внедрить SQL через collection name
WHEN: get(collection: "projects; DROP TABLE projects--", id: "x")
THEN: выбрасывает validation error
AND: таблица не удаляется
```

#### Test 2.4: UNION-based Injection
```
GIVEN: tenant-a пытается использовать UNION для чтения других таблиц
WHEN: get(id: "x' UNION SELECT * FROM projects WHERE tenant_id='tenant-b'--")
THEN: возвращает null
AND: не раскрывает данные tenant-b
```

#### Test 2.5: Subquery Injection
```
GIVEN: tenant-a пытается использовать подзапрос
WHEN: query(filter: {field: "name", value: "(SELECT data FROM projects WHERE tenant_id='tenant-b')"})
THEN: не возвращает данные tenant-b
```

---

### Category 3: Context Manipulation Tests (Манипуляция контекстом)

**Цель:** Проверить, что tenant не может изменить свой контекст

#### Test 3.1: Direct Context Override
```
GIVEN: tenant-a пытается изменить контекст через SET
WHEN: выполняет запрос с внедрённым "SET app.current_tenant = 'tenant-b'"
THEN: контекст не изменяется
AND: tenant-a видит только свои данные
```

#### Test 3.2: Context Reset Attack
```
GIVEN: tenant-a пытается сбросить контекст
WHEN: выполняет запрос с "RESET app.current_tenant"
THEN: контекст не сбрасывается
AND: запрос возвращает только данные tenant-a
```

#### Test 3.3: Multiple Context Sets
```
GIVEN: tenant-a пытается установить контекст несколько раз
WHEN: выполняет "SET LOCAL app.current_tenant = 'tenant-a'; SET LOCAL app.current_tenant = 'tenant-b'"
THEN: используется последний контекст (tenant-b)
BUT: RLS политика всё равно применяется корректно
```

#### Test 3.4: Context Pollution via Connection Pool
```
GIVEN: tenant-a выполнил запрос, затем tenant-b использует то же соединение
WHEN: tenant-b выполняет запрос
THEN: tenant-b видит только свои данные
AND: контекст tenant-a не влияет на tenant-b
```

---

### Category 4: Transaction Isolation Tests (Изоляция транзакций)

**Цель:** Проверить, что RLS работает корректно в транзакциях

#### Test 4.1: Nested Transaction Context
```
GIVEN: tenant-a начинает транзакцию
WHEN: внутри транзакции пытается начать вложенную транзакцию с другим контекстом
THEN: вложенная транзакция использует контекст родительской
AND: tenant-a не видит чужие данные
```

#### Test 4.2: Rollback Context Leak
```
GIVEN: tenant-a выполняет операцию в транзакции
WHEN: транзакция откатывается (ROLLBACK)
THEN: контекст не "утекает" в следующую транзакцию
AND: следующий запрос использует свежий контекст
```

#### Test 4.3: Concurrent Transactions
```
GIVEN: tenant-a и tenant-b выполняют запросы параллельно
WHEN: оба читают одну и ту же таблицу одновременно
THEN: каждый видит только свои данные
AND: нет race condition в установке контекста
```

#### Test 4.4: Long Transaction Context Stability
```
GIVEN: tenant-a начинает длинную транзакцию (10+ операций)
WHEN: выполняет множество операций внутри транзакции
THEN: контекст остаётся стабильным на протяжении всей транзакции
AND: все операции видят только данные tenant-a
```

---

### Category 5: Batch Operation Tests (Пакетные операции)

**Цель:** Проверить безопасность batch операций

#### Test 5.1: putAll with Mixed Tenant IDs
```
GIVEN: tenant-a пытается вставить записи с разными tenantId в data
WHEN: putAll([{id: "x", tenantId: "tenant-a"}, {id: "y", tenantId: "tenant-b"}])
THEN: обе записи сохраняются с tenant_id = "tenant-a" (из контекста)
AND: tenantId в data игнорируется
```

#### Test 5.2: Batch Delete Isolation
```
GIVEN: tenant-a имеет [a1, a2], tenant-b имеет [b1, b2]
WHEN: tenant-a выполняет deleteAll([a1, b1])
THEN: удаляется только a1
AND: b1 остаётся нетронутым
```

#### Test 5.3: Batch Query with Overlapping IDs
```
GIVEN: tenant-a и tenant-b имеют записи с одинаковыми id
WHEN: tenant-a выполняет query(ids: [id1, id2, id3])
THEN: возвращаются только записи tenant-a
AND: записи tenant-b с теми же id не возвращаются
```

---

### Category 6: Timing Attack Tests (Атаки по времени)

**Цель:** Проверить, что RLS не раскрывает информацию через время ответа

#### Test 6.1: Existence Timing Attack
```
GIVEN: tenant-b имеет запись b1
WHEN: tenant-a выполняет get(b1) и get(non-existent-id)
THEN: время ответа должно быть примерно одинаковым
AND: нельзя определить существование записи по времени
```

#### Test 6.2: Count Timing Attack
```
GIVEN: tenant-b имеет 1000 записей
WHEN: tenant-a выполняет count()
THEN: время ответа не зависит от количества записей других tenants
```

---

### Category 7: Versioned Repository Tests (Версионирование)

**Цель:** Проверить RLS для versioned storage

#### Test 7.1: Version History Isolation
```
GIVEN: tenant-a имеет entity с 5 версиями, tenant-b имеет entity с тем же entityId
WHEN: tenant-a выполняет listVersions(entityId)
THEN: возвращаются только версии tenant-a
AND: версии tenant-b не видны
```

#### Test 7.2: Branch Isolation
```
GIVEN: tenant-b создал branch "feature-x" для entity
WHEN: tenant-a пытается прочитать этот branch
THEN: возвращает null или пустой список
```

#### Test 7.3: Snapshot Isolation
```
GIVEN: tenant-b создал snapshot версии
WHEN: tenant-a пытается прочитать snapshot по nodeId
THEN: возвращает null
```

---

### Category 8: Logged Repository Tests (Аудит лог)

**Цель:** Проверить RLS для logged storage

#### Test 8.1: History Log Isolation
```
GIVEN: tenant-b имеет 10 записей в audit log
WHEN: tenant-a выполняет getHistory(entityId)
THEN: возвращается только история tenant-a
AND: записи tenant-b не видны
```

#### Test 8.2: Rollback Isolation
```
GIVEN: tenant-b имеет entity с историей изменений
WHEN: tenant-a пытается откатить entity tenant-b к предыдущей версии
THEN: операция не выполняется (entity не найден)
AND: данные tenant-b не изменяются
```

---

### Category 9: Edge Cases (Граничные случаи)

**Цель:** Проверить поведение в нестандартных ситуациях

#### Test 9.1: Empty Tenant ID
```
GIVEN: запрос приходит с пустым tenantId
WHEN: выполняется любая операция
THEN: выбрасывается validation error
AND: операция не выполняется
```

#### Test 9.2: Null Tenant ID
```
GIVEN: запрос приходит с tenantId = null
WHEN: выполняется любая операция
THEN: выбрасывается validation error
```

#### Test 9.3: Special Characters in Tenant ID
```
GIVEN: tenantId содержит специальные символы: "tenant'; DROP TABLE--"
WHEN: выполняется операция
THEN: tenantId экранируется корректно
AND: SQL injection не происходит
```

#### Test 9.4: Very Long Tenant ID
```
GIVEN: tenantId длиной 10000 символов
WHEN: выполняется операция
THEN: либо выбрасывается validation error, либо работает корректно
AND: не происходит buffer overflow
```

#### Test 9.5: Unicode Tenant ID
```
GIVEN: tenantId содержит Unicode символы: "租户-א-🔒"
WHEN: выполняется операция
THEN: работает корректно
AND: изоляция сохраняется
```

#### Test 9.6: Case Sensitivity
```
GIVEN: tenant-a создал запись
WHEN: запрос приходит с tenantId = "Tenant-A" (другой регистр)
THEN: запись не найдена (tenantId case-sensitive)
```

---

### Category 10: Performance & DoS Tests (Производительность и DoS)

**Цель:** Проверить, что RLS не создаёт уязвимости производительности

#### Test 10.1: Large Dataset Query
```
GIVEN: tenant-a имеет 100,000 записей
WHEN: выполняет query() без limit
THEN: запрос завершается за разумное время (<5 сек)
AND: не происходит OOM
```

#### Test 10.2: Concurrent Load Test
```
GIVEN: 100 tenants выполняют запросы параллельно
WHEN: каждый выполняет 1000 операций
THEN: все запросы завершаются успешно
AND: нет deadlocks или context pollution
```

#### Test 10.3: Connection Pool Exhaustion
```
GIVEN: connection pool имеет 10 соединений
WHEN: 50 tenants пытаются выполнить запросы одновременно
THEN: запросы ставятся в очередь корректно
AND: контекст не смешивается между запросами
```

---

## 🎯 Test Implementation Strategy

### Phase 1: Unit Tests (Dart)
- Тесты для `PostgresVaultStorage._setTenantContext()`
- Тесты для `_buildQuerySql()` - проверка отсутствия явных WHERE tenant_id
- Моки для проверки вызовов `SET LOCAL`

### Phase 2: Integration Tests (PostgreSQL)
- Прямые SQL тесты в PostgreSQL
- Проверка RLS политик через `EXPLAIN`
- Тесты с реальными данными

### Phase 3: API Tests (HTTP)
- End-to-end тесты через `/vault/rpc`
- Проверка всех операций (get, put, delete, query)
- Тесты для всех типов storage (direct, versioned, logged)

### Phase 4: Load Tests (Artillery/k6)
- Concurrent requests от разных tenants
- Stress testing connection pool
- Memory leak detection

### Phase 5: Security Audit
- Penetration testing
- SQL injection fuzzing
- Timing attack analysis

---

## 📊 Success Criteria

### Must Pass (100% критичные)
- ✅ Все Category 1 тесты (Basic Isolation)
- ✅ Все Category 2 тесты (SQL Injection)
- ✅ Все Category 3 тесты (Context Manipulation)
- ✅ Test 9.1, 9.2 (Empty/Null tenant ID)

### Should Pass (высокий приоритет)
- ✅ Все Category 4 тесты (Transaction Isolation)
- ✅ Все Category 5 тесты (Batch Operations)
- ✅ Category 7, 8 тесты (Versioned/Logged)

### Nice to Have (средний приоритет)
- ✅ Category 6 тесты (Timing Attacks)
- ✅ Category 9 edge cases
- ✅ Category 10 performance tests

---

## 🔧 Test Tools

### Dart Testing
```yaml
dependencies:
  test: ^1.24.0
  mockito: ^5.4.0
  postgres: ^3.0.0
```

### SQL Testing
- `psql` для прямых SQL тестов
- `EXPLAIN ANALYZE` для проверки планов запросов
- `pg_stat_statements` для анализа производительности

### Load Testing
- k6 для HTTP load testing
- pgbench для PostgreSQL load testing

### Security Testing
- sqlmap для SQL injection testing
- custom scripts для timing attacks

---

**Автор:** Claude (Sonnet 4)
**Дата:** 2026-04-09
**Статус:** Test Plan Ready
