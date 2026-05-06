# Analysis: Сценарии для всех типов хранения в трёх режимах

## Что есть

### Типы хранения (5)
| Тип | Интерфейс | Пример домена |
|-----|-----------|---------------|
| Direct | `DirectRepository<T>` | `AqStudioProject` |
| Versioned | `VersionedRepository<T>` | `TypedWorkflowGraph` |
| Logged | `LoggedRepository<T>` | `WorkflowRun` |
| Artifact | `IArtifactRepository<T>` | `StoredArtifact` |
| Vector/Knowledge | `IVectorRepository` / `IKnowledgeRepository<T>` | векторные чанки |

### Режимы работы (3)
| Режим | Как | Когда |
|-------|-----|-------|
| **Mock** | `MockDataLayer` + `MockDataBackend` из `aq_schema/data_testing.dart` | unit-тесты, CI без БД |
| **Local DB** | `PostgresVaultStorage` напрямую (без HTTP) | интеграционные тесты, сервер |
| **Remote** | `IDataLayer.initialize(endpoint)` через HTTP RPC | production, клиент |

### Что уже есть
- `example/stack/console_client/` — примеры только для Remote режима
- `example/01_serverless_desktop/` — Local DB режим (PostgreSQL напрямую)
- `example/02_client_server/` — Remote режим (клиент + сервер)
- Нет примеров для Mock режима
- Нет единой структуры "один сценарий — три режима"

## Проблема
Нет систематических примеров покрывающих все комбинации.
Разработчик не может быстро понять как переключиться между режимами.

## Ограничения
- Работаем только в `aq_data_layer`
- `aq_schema` только чтение
- Примеры должны компилироваться (`dart analyze`)
