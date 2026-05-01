# Развёртывание dart_vault

---

## Требования

- Docker + Docker Compose
- Dart SDK ≥ 3.0 (для локальной разработки)
- 4GB RAM минимум (Ollama + pgvector)
- 2GB свободного места (модели Ollama)

---

## Быстрый старт (Docker)

```bash
cd example/stack

# 1. Поднять стек
docker-compose up -d

# 2. Установить модель эмбеддингов (один раз)
docker exec stack-ollama-1 ollama pull nomic-embed-text

# 3. Проверить что всё работает
curl http://localhost:8765/vault/v1/health
# → {"status":"healthy","timestamp":"..."}

# 4. Запустить базовый сценарий
docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 \
  -e OLLAMA_ENDPOINT=http://stack-ollama-1:11434 \
  stack-rag_basic
```

---

## Компоненты стека

### postgres (pgvector/pgvector:pg15)

PostgreSQL с расширением pgvector. Хранит:
- Все документы (direct/versioned/logged)
- Метаданные артефактов
- Векторные эмбеддинги (таблицы `*__vectors`)
- Справочники pipeline и store

**Порт:** 5432 (проброшен на хост для прямого доступа)

### ollama (ollama/ollama:latest)

Локальный LLM сервер. Используется для:
- Генерации эмбеддингов (`nomic-embed-text`, 768-dim)
- Реранкинга (`llama3.2:1b` или другая модель)

**Порт:** 11434

**Модели:**
```bash
# Эмбеддинги (обязательно)
docker exec stack-ollama-1 ollama pull nomic-embed-text  # 274MB

# Реранкер (опционально)
docker exec stack-ollama-1 ollama pull llama3.2:1b       # 1.3GB
```

### server (dart_vault сервер)

HTTP RPC сервер. Обрабатывает все запросы клиентов.

**Порт:** 8765

**Переменные окружения:**

```bash
DB_HOST=postgres          # PostgreSQL хост
DB_PORT=5432
DB_NAME=vault_db
DB_USER=vault_user
DB_PASSWORD=vault_pass
SERVER_PORT=8765
ARTIFACT_PATH=/data/artifacts  # Путь для файлов
SECURITY_MODE=mock             # mock | (пусто = без security)
VECTOR_DIM=768                 # Размерность векторов
VECTOR_EMBEDDER_ID=ollama-nomic-embed-text
```

---

## Запуск сценариев

Все сценарии — одноразовые контейнеры. Стартуют, выполняют работу, завершаются.

```bash
# Базовые
docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 \
  stack-artifacts

docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 \
  stack-vector

# С Ollama
docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 \
  -e OLLAMA_ENDPOINT=http://stack-ollama-1:11434 \
  stack-search_core

docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 \
  -e OLLAMA_ENDPOINT=http://stack-ollama-1:11434 \
  stack-search_precision

# Reranker (нужна LLM модель)
docker exec stack-ollama-1 ollama pull llama3.2:1b
docker run --rm --network stack_default \
  -e VAULT_ENDPOINT=http://stack-server-1:8765 \
  -e OLLAMA_ENDPOINT=http://stack-ollama-1:11434 \
  -e OLLAMA_LLM_MODEL=llama3.2:1b \
  stack-search_reranker
```

---

## Просмотр данных

```bash
# Файлы в artifact storage
docker run --rm -v stack_artifacts_data:/data alpine find /data -type f

# Векторные таблицы в PostgreSQL
docker exec stack-postgres-1 psql -U vault_user -d vault_db \
  -c "SELECT tablename FROM pg_tables WHERE tablename LIKE '%vectors%';"

# Содержимое векторной таблицы
docker exec stack-postgres-1 psql -U vault_user -d vault_db \
  -c "SELECT id, payload->>'artifactId', payload->>'text' FROM sp_tenant__vectors LIMIT 5;"

# Логи сервера
docker-compose logs server -f
```

---

## Пересборка после изменений

```bash
# Пересобрать сервер
docker-compose build --no-cache server
docker-compose up -d

# Пересобрать конкретный сценарий
docker-compose build --no-cache search_core

# Пересобрать всё
docker-compose build --no-cache
```

---

## Сброс данных

```bash
# Остановить стек
docker-compose down

# Удалить все данные (включая векторы и файлы)
docker volume rm stack_artifacts_data stack_ollama_data
docker volume rm $(docker volume ls -q | grep stack_)

# Запустить заново
docker-compose up -d
docker exec stack-ollama-1 ollama pull nomic-embed-text
```

---

## Production checklist

- [ ] Заменить `SECURITY_MODE=mock` на реальную реализацию `IVaultSecurityProtocol`
- [ ] Заменить `LocalArtifactStorage` на S3/MinIO для файлов
- [ ] Настроить SSL для PostgreSQL (`SslMode.require`)
- [ ] Вынести пароли в secrets manager (не в docker-compose.yml)
- [ ] Настроить backup для PostgreSQL volume
- [ ] Увеличить `maxConnectionCount` в Pool под нагрузку
- [ ] Настроить мониторинг (healthcheck уже есть на `/vault/v1/health`)
- [ ] Для > 500k векторов рассмотреть QdrantVectorStorage вместо pgvector
